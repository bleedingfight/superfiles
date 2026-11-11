use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use sfiles_index::{FileOffset, Index, StoredTransfer, TransferTaskState};
use vfs_core::{Entry, Result, Vfs, VfsError};

use crate::handle::{TransferHandle, TransferState};

/// What to do when the destination already exists.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConflictPolicy {
    Overwrite,
    Skip,
    Rename,
}

#[derive(Debug, Clone)]
pub struct CopyOptions {
    pub chunk_size: usize,
    pub conflict: ConflictPolicy,
    pub recursive: bool,
    /// 移动语义：全部复制成功后删除源。持久化在 transfers 表里，进程被杀后
    /// 恢复的任务仍然会在完成时删源（旧实现把 move 只放在 Kotlin 内存里，
    /// 重启后「移动」会退化成「复制」）。
    pub delete_sources: bool,
}

/// 复制块大小：1 MiB。
///
/// 256 KiB（`DEFAULT_CHUNK_SIZE`）在本地盘上毫发无损，但网络后端每块都含
/// 一次句柄/请求编排开销——1 MiB 把轮次降到 1/4，SMB→本地实测吞吐翻倍
/// （配合 backend 的句柄复用，50MB/s 级带宽可以吃满）。
/// 内存代价：读写各 1 块 ≈ 2 MiB，可忽略。
const COPY_CHUNK_SIZE: usize = 1024 * 1024;

impl Default for CopyOptions {
    fn default() -> Self {
        Self {
            chunk_size: COPY_CHUNK_SIZE,
            conflict: ConflictPolicy::Skip,
            recursive: true,
            delete_sources: false,
        }
    }
}

/// Persist the offset map at every file boundary and every N chunks inside
/// large files: one fsync per 16 chunks (4 MiB at the default chunk size) is
/// cheap, and the worst-case replay after a crash is bounded by the same.
const FLUSH_EVERY_CHUNKS: u16 = 16;

/// Run-scoped checkpoint tracker for resumable copies.
///
/// With no index attached it is a no-op shell — the default [`run`] path
/// keeps its zero-overhead behavior. With an index attached, every written
/// chunk updates an in-memory `source_id -> offset` map that is flushed to
/// the `transfers` table at file boundaries and every [`FLUSH_EVERY_CHUNKS`]
/// chunks, so killing the process leaves a resumable row behind.
pub struct CopyRuntimeState {
    index: Option<Arc<Index>>,
    offsets: Mutex<OffsetMap>,
}

#[derive(Default)]
struct OffsetMap {
    by_source: HashMap<String, FileOffset>,
    chunks_since_flush: u16,
}

impl CopyRuntimeState {
    /// No persistence; used by [`run`].
    pub(crate) fn volatile() -> Self {
        Self {
            index: None,
            offsets: Mutex::new(OffsetMap::default()),
        }
    }

    /// Persists checkpoints to `index`; used by [`run_resumable`].
    pub(crate) fn persisted(index: Arc<Index>) -> Self {
        Self {
            index: Some(index),
            offsets: Mutex::new(OffsetMap::default()),
        }
    }

    /// Load checkpoints recovered from a previous run.
    fn load_offsets(&self, offsets: Vec<FileOffset>) {
        self.offsets.lock().unwrap().by_source = offsets
            .into_iter()
            .map(|record| (record.source_id.clone(), record))
            .collect();
    }

    /// The file was completed by a previous run (record covers its full
    /// current size).
    fn is_finished(&self, source_id: &str, size: u64) -> bool {
        let map = self.offsets.lock().unwrap();
        matches!(map.by_source.get(source_id), Some(record)
            if record.size == size && record.offset >= size)
    }

    /// Byte offset to continue this file at, or 0 when there is no usable
    /// checkpoint (unknown file, or the source size changed in between —
    /// `size` pins the length at record time to detect that).
    fn resume_start(&self, source_id: &str, size: u64) -> u64 {
        let map = self.offsets.lock().unwrap();
        match map.by_source.get(source_id) {
            Some(record) if record.size == size && record.offset < size => record.offset,
            _ => 0,
        }
    }

    /// Record one written chunk; returns true when it is time to flush.
    fn record_chunk(&self, source_id: &str, size: u64, offset: u64) -> bool {
        if self.index.is_none() {
            return false;
        }
        let mut map = self.offsets.lock().unwrap();
        map.by_source.insert(
            source_id.to_string(),
            FileOffset {
                source_id: source_id.to_string(),
                size,
                offset,
            },
        );
        map.chunks_since_flush += 1;
        if map.chunks_since_flush >= FLUSH_EVERY_CHUNKS {
            map.chunks_since_flush = 0;
            return true;
        }
        false
    }

    /// Flush progress counters and the offset map. Bookkeeping failures are
    /// deliberately swallowed: copying data matters more than its journal.
    async fn persist_progress(&self, handle: &TransferHandle) {
        let Some(index) = &self.index else {
            return;
        };
        let snapshot = handle.snapshot();
        let offsets = {
            let mut map = self.offsets.lock().unwrap();
            map.chunks_since_flush = 0;
            map.by_source.values().cloned().collect::<Vec<_>>()
        };
        // 计数从 offset 表推导，保证 bytes_done 与断点永远一致（快照与
        // offsets 分两次读取时，进程被杀可能落在两者之间，resume 后进度会虚高）
        let bytes_done: u64 = offsets.iter().map(|offset| offset.offset).sum();
        let id = handle.id().to_string();
        let index = index.clone();
        // SQLite 落盘 + fsync 是同步阻塞调用，绝不能占着 tokio worker：
        // worker 被 fsync 堵住时 IO driver 也停止 poll，前台列举/播放会一起卡住
        // （实测 2 worker 下传输期间 list p50 1.9ms → 30ms）。
        let _ = tokio::task::spawn_blocking(move || {
            let _ = index.update_transfer_progress(
                &id,
                snapshot.files_done,
                bytes_done,
                &offsets,
            );
        })
        .await;
    }

    /// Write (or refresh) the whole job row after the scan totals are known.
    fn save_job(&self, sources: &[String], dest_dir: &str, handle: &TransferHandle, is_move: bool) {
        let Some(index) = &self.index else {
            return;
        };
        let snapshot = handle.snapshot();
        let mut stored = StoredTransfer::new_running(
            handle.id(),
            sources.to_vec(),
            dest_dir,
            snapshot.files_total,
            snapshot.bytes_total,
        );
        // On a resumed run the counters were re-seeded, keep them intact.
        stored.is_move = is_move;
        stored.files_done = snapshot.files_done;
        stored.bytes_done = snapshot.bytes_done;
        stored.file_offsets = self
            .offsets
            .lock()
            .unwrap()
            .by_source
            .values()
            .cloned()
            .collect();
        let _ = index.save_transfer(&stored);
    }

    /// Terminal state write; a crashed process never reaches this, which is
    /// exactly what makes the row resumable on the next launch.
    fn finish_job(&self, handle: &TransferHandle, state: TransferTaskState, error: Option<&str>) {
        let Some(index) = &self.index else {
            return;
        };
        let _ = index.finish_transfer(handle.id(), state, error);
    }
}

/// Entry point used by the FFI layer. Never returns an error: failures are
/// recorded on the handle so the UI can surface them without exception plumbing.
pub async fn run(
    vfs: Arc<Vfs>,
    sources: Vec<String>,
    dest_dir: String,
    opts: CopyOptions,
    handle: Arc<TransferHandle>,
) {
    debug_assert_eq!(handle.snapshot().state, TransferState::Queued);
    handle.set_running();

    let rt = CopyRuntimeState::volatile();
    match run_inner(&vfs, &sources, &dest_dir, &opts, &handle, &rt, false).await {
        Ok(()) => handle.finish_ok(),
        Err(VfsError::Cancelled) => handle.finish_cancelled(),
        Err(err) => handle.finish_err(err.to_string()),
    }
}

/// Resumable variant of [`run`]: persists checkpoints to `index` so a
/// process kill leaves the transfer resumable, and — when `resume_from`
/// carries a matching unfinished record — continues from the recorded
/// per-file offsets instead of starting over.
///
/// A stored record is only honored when it describes this exact job (same
/// sources and destination, still unfinished); a mismatched record is
/// ignored and the copy starts fresh, overwriting the stale row. Offset
/// continuation applies to the `Overwrite` conflict policy: the destination
/// of a partially copied file exists by then, and `Overwrite` keeps
/// semantics as "continue writing at the recorded offset". Under `Skip` /
/// `Rename` the conflict is simply re-evaluated like on the first run.
///
/// `handle` should reuse `resume_from`'s id so the same row is updated.
pub async fn run_resumable(
    vfs: Arc<Vfs>,
    sources: Vec<String>,
    dest_dir: String,
    opts: CopyOptions,
    handle: Arc<TransferHandle>,
    index: Arc<Index>,
    resume_from: Option<StoredTransfer>,
) {
    debug_assert_eq!(handle.snapshot().state, TransferState::Queued);
    handle.set_running();

    let rt = CopyRuntimeState::persisted(index);
    let resume = resume_from.filter(|stored| {
        stored.sources == sources
            && stored.dest_dir == dest_dir
            && matches!(
                stored.state,
                TransferTaskState::Queued | TransferTaskState::Running
            )
    });
    if let Some(stored) = &resume {
        rt.load_offsets(stored.file_offsets.clone());
        handle.seed_progress(stored.files_done, stored.bytes_done);
        // The previous run's scan totals are still authoritative; no rescan.
        handle.set_totals(stored.files_total, stored.bytes_total);
    }

    match run_inner(
        &vfs,
        &sources,
        &dest_dir,
        &opts,
        &handle,
        &rt,
        resume.is_some(),
    )
    .await
    {
        Ok(()) => {
            rt.finish_job(&handle, TransferTaskState::Completed, None);
            handle.finish_ok();
        }
        Err(VfsError::Cancelled) => {
            rt.persist_progress(&handle).await;
            rt.finish_job(&handle, TransferTaskState::Cancelled, None);
            handle.finish_cancelled();
        }
        Err(err) => {
            let message = err.to_string();
            rt.persist_progress(&handle).await;
            rt.finish_job(&handle, TransferTaskState::Failed, Some(&message));
            handle.finish_err(message);
        }
    }
}

async fn run_inner(
    vfs: &Vfs,
    sources: &[String],
    dest_dir: &str,
    opts: &CopyOptions,
    handle: &TransferHandle,
    rt: &CopyRuntimeState,
    resumed: bool,
) -> Result<()> {
    // Pre-scan so the UI can show a real progress bar instead of a spinner.
    // A resumed run already restored its totals from the stored record.
    if !resumed {
        let mut files_total = 0u64;
        let mut bytes_total = 0u64;
        for source in sources {
            let (files, bytes) = scan(vfs, source, opts.recursive, 0, handle).await?;
            files_total += files;
            bytes_total += bytes;
        }
        handle.set_totals(files_total, bytes_total);
    }
    rt.save_job(sources, dest_dir, handle, opts.delete_sources);

    for source in sources {
        copy_tree(vfs, source, dest_dir, opts, handle, rt).await?;
    }
    // 移动：全部复制成功后才删源；删除失败只影响清理，不回滚已复制的数据。
    if opts.delete_sources {
        for source in sources {
            if let Ok(entry) = vfs.stat(source).await {
                let _ = vfs.remove(source, entry.is_dir()).await;
            }
        }
    }
    Ok(())
}

/// Count files and bytes under `id`. Symlinks are counted as single files and
/// never traversed, which also protects against cycles.
async fn scan(
    vfs: &Vfs,
    id: &str,
    recursive: bool,
    depth: usize,
    handle: &TransferHandle,
) -> Result<(u64, u64)> {
    if handle.is_cancelled() {
        return Err(VfsError::Cancelled);
    }
    if depth > 64 {
        return Err(VfsError::Io(
            "directory tree too deep (possible loop)".into(),
        ));
    }
    let entry = vfs.stat(id).await?;
    if !entry.is_dir() || !recursive {
        return Ok((1, entry.size));
    }
    let mut files = 0u64;
    let mut bytes = 0u64;
    for child in vfs.list(id).await? {
        let (f, b) = Box::pin(scan(vfs, &child.id, recursive, depth + 1, handle)).await?;
        files += f;
        bytes += b;
    }
    Ok((files, bytes))
}

async fn copy_tree(
    vfs: &Vfs,
    source: &str,
    dest_dir: &str,
    opts: &CopyOptions,
    handle: &TransferHandle,
    rt: &CopyRuntimeState,
) -> Result<()> {
    // (source id, destination parent id)
    let mut stack: Vec<(String, String)> = vec![(source.to_string(), dest_dir.to_string())];

    while let Some((current, dest_parent)) = stack.pop() {
        if handle.is_cancelled() {
            return Err(VfsError::Cancelled);
        }
        let entry = vfs.stat(&current).await?;
        handle.set_current(Some(entry.name.clone()));

        let Some(target) = resolve_conflict(vfs, &dest_parent, &entry.name, opts.conflict).await?
        else {
            // Skip policy and the destination exists.
            continue;
        };

        if entry.is_dir() {
            if !opts.recursive {
                continue;
            }
            match vfs.create_dir(&dest_parent, &entry.name).await {
                Ok(_) | Err(VfsError::AlreadyExists(_)) => {}
                Err(err) => return Err(err),
            }
            let children = vfs.list(&current).await?;
            for child in children.into_iter().rev() {
                stack.push((child.id, target.clone()));
            }
        } else {
            // A previous run finished this file: skip it without recounting
            // (its bytes/files are already re-seeded into the counters) —
            // unless the destination vanished in the meantime, which calls
            // for a clean full copy.
            if rt.is_finished(&entry.id, entry.size)
                && matches!(vfs.stat(&target).await, Ok(dest) if dest.size >= entry.size)
            {
                continue;
            }
            // `Overwrite` re-evaluated against a destination our previous
            // run created means "continue at the checkpoint", not "restart".
            let start = match opts.conflict {
                ConflictPolicy::Overwrite => rt.resume_start(&entry.id, entry.size),
                // Skip/Rename behave exactly like on the first run: the
                // leftover partial file is skipped or copied under a fresh
                // name (the old partial is orphaned by design).
                ConflictPolicy::Skip | ConflictPolicy::Rename => 0,
            };
            let start = if start > 0 {
                match vfs.stat(&target).await {
                    // Only continue a destination that holds at least the
                    // checkpointed bytes; otherwise the checkpoint is stale
                    // (destination replaced/truncated) and we start over.
                    Ok(dest) if dest.size >= start => start,
                    _ => 0,
                }
            } else {
                0
            };
            copy_file(vfs, &entry, &target, opts.chunk_size, start, handle, rt).await?;
            handle.complete_file();
            rt.persist_progress(handle).await;
        }
    }
    Ok(())
}

async fn copy_file(
    vfs: &Vfs,
    entry: &Entry,
    target: &str,
    chunk_size: usize,
    start: u64,
    handle: &TransferHandle,
    rt: &CopyRuntimeState,
) -> Result<()> {
    if entry.size == 0 {
        vfs.write_range(target, 0, &[]).await?;
        vfs.truncate(target, 0).await?;
        rt.record_chunk(&entry.id, 0, 0);
        return Ok(());
    }

    // When resuming (`start > 0`), the already-written prefix was counted by
    // the previous run and re-seeded into the counters, so only newly
    // written bytes are added here.
    //
    // 双路并发读：每轮同时向源端发两块请求（SMB2 同句柄并发读合法；后端
    // 读路径已做到锁外读，互不阻塞），写回仍按顺序。网络源瓶颈是每块一个
    // RTT，两路并发把轮次延迟摊薄 ≈2×；读回长度由 read_range 保证等于
    // min(want, 剩余)，因此第二块的偏移可以预先算出。
    // 取消/断点语义与串行版本一致（每轮结束落 checkpoint）。
    let want = chunk_size.max(1);
    let mut offset = start;

    while offset < entry.size {
        if handle.is_cancelled() {
            return Err(VfsError::Cancelled);
        }
        let remaining = entry.size - offset;
        let mut written = 0u64;
        if remaining > want as u64 {
            let second = offset + want as u64;
            let (first, next) = tokio::join!(
                vfs.read_range(&entry.id, offset, want),
                vfs.read_range(&entry.id, second, want),
            );
            let first = first?;
            let next = next?;
            if first.is_empty() {
                break;
            }
            vfs.write_range(target, offset, &first).await?;
            written += first.len() as u64;
            // The prefetched block was read at `second`, so it must be written
            // at `second` — not at `offset + first.len()`. Those differ when a
            // backend returns a short *mid-file* read (WebDAV proxies do this;
            // the contract only promises short reads at the tail). Writing it
            // at the wrong offset silently shifts the rest of the file.
            if first.len() == want && !next.is_empty() {
                vfs.write_range(target, second, &next).await?;
                written = want as u64 + next.len() as u64;
            }
        } else {
            let chunk = vfs.read_range(&entry.id, offset, want).await?;
            if chunk.is_empty() {
                break;
            }
            vfs.write_range(target, offset, &chunk).await?;
            written = chunk.len() as u64;
        }
        offset += written;
        handle.add_bytes(written);
        if rt.record_chunk(&entry.id, entry.size, offset) {
            rt.persist_progress(handle).await;
        }
    }
    // Shrink leftovers when overwriting a larger file with a smaller one.
    vfs.truncate(target, offset).await?;
    // Final checkpoint marks the file done for a future resume.
    rt.record_chunk(&entry.id, entry.size, offset);
    Ok(())
}

/// Decide the final destination id.
///
/// Returns `None` when the destination exists and the policy is `Skip`.
async fn resolve_conflict(
    vfs: &Vfs,
    dest_dir: &str,
    name: &str,
    policy: ConflictPolicy,
) -> Result<Option<String>> {
    let target = Vfs::join(dest_dir, name);
    if vfs.stat(&target).await.is_err() {
        return Ok(Some(target));
    }
    match policy {
        ConflictPolicy::Overwrite => Ok(Some(target)),
        ConflictPolicy::Skip => Ok(None),
        ConflictPolicy::Rename => {
            for index in 1..10_000u32 {
                let candidate = renamed(name, index);
                let candidate_id = Vfs::join(dest_dir, &candidate);
                if vfs.stat(&candidate_id).await.is_err() {
                    return Ok(Some(candidate_id));
                }
            }
            Err(VfsError::AlreadyExists(name.to_string()))
        }
    }
}

/// `movie.mkv` -> `movie (1).mkv`, `archive` -> `archive (1)`.
fn renamed(name: &str, index: u32) -> String {
    match name.rsplit_once('.') {
        Some((stem, ext)) if !stem.is_empty() && !ext.is_empty() => {
            format!("{stem} ({index}).{ext}")
        }
        _ => format!("{name} ({index})"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use vfs_core::CancelToken;

    fn temp_root(tag: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "sfiles-engine-{tag}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

    #[test]
    fn rename_patterns() {
        assert_eq!(renamed("movie.mkv", 1), "movie (1).mkv");
        assert_eq!(renamed("archive", 2), "archive (2)");
        assert_eq!(renamed(".hidden", 1), ".hidden (1)");
        assert_eq!(renamed("a.tar.gz", 1), "a.tar (1).gz");
    }

    #[tokio::test]
    async fn copies_tree_and_reports_progress() {
        let root = temp_root("copy");
        let vfs = Arc::new(Vfs::with_local_root(&root).unwrap());
        let root_id = vfs.local_root().to_string();

        let src = vfs.create_dir(&root_id, "src").await.unwrap();
        let nested = vfs.create_dir(&src.id, "nested").await.unwrap();
        vfs.write_range(&Vfs::join(&src.id, "a.txt"), 0, b"hello")
            .await
            .unwrap();
        vfs.write_range(&Vfs::join(&nested.id, "b.bin"), 0, &[0u8; 1024])
            .await
            .unwrap();

        let dst = vfs.create_dir(&root_id, "dst").await.unwrap();
        let handle = Arc::new(TransferHandle::new("t1", CancelToken::new()));

        run(
            vfs.clone(),
            vec![src.id.clone()],
            dst.id.clone(),
            CopyOptions::default(),
            handle.clone(),
        )
        .await;

        let snap = handle.snapshot();
        assert_eq!(snap.state, TransferState::Completed, "{snap:?}");
        assert_eq!(snap.files_total, 2);
        assert_eq!(snap.bytes_total, 5 + 1024);
        assert_eq!(snap.bytes_done, 5 + 1024);

        let copied = vfs.list(&Vfs::join(&dst.id, "src")).await.unwrap();
        assert_eq!(copied.len(), 2);

        std::fs::remove_dir_all(&root).ok();
    }

    /// Abort a running copy like a process kill would: the task is dropped
    /// mid-flight, so no terminal state is ever written to the `transfers`
    /// table and the row stays `running` — exactly what a restart sees.
    async fn crash_while_copying(
        vfs: Arc<Vfs>,
        sources: Vec<String>,
        dest: String,
        opts: CopyOptions,
        index: Arc<Index>,
        id: &str,
        crash_after_bytes: u64,
    ) -> StoredTransfer {
        let handle = Arc::new(TransferHandle::new(id, CancelToken::new()));
        let task = {
            let vfs = vfs.clone();
            let handle = handle.clone();
            let opts = opts.clone();
            let index = index.clone();
            tokio::spawn(async move {
                run_resumable(vfs, sources, dest, opts, handle, index, None).await
            })
        };
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(60);
        while handle.snapshot().bytes_done < crash_after_bytes {
            assert!(
                std::time::Instant::now() < deadline,
                "first run stalled: {:?}",
                handle.snapshot()
            );
            tokio::time::sleep(std::time::Duration::from_millis(1)).await;
        }
        task.abort();
        let err = task.await.expect_err("aborted task must not join cleanly");
        assert!(err.is_cancelled());

        let mut rows = index.load_unfinished_transfers().unwrap();
        assert_eq!(rows.len(), 1, "the crashed run must stay resumable");
        let stored = rows.remove(0);
        assert_eq!(stored.id, id);
        assert_eq!(stored.state, TransferTaskState::Running);
        stored
    }

    #[tokio::test]
    async fn resume_after_crash_continues_from_offsets() {
        let root = temp_root("resume");
        let vfs = Arc::new(Vfs::with_local_root(&root).unwrap());
        let root_id = vfs.local_root().to_string();
        let index = Arc::new(Index::open(root.join("index.sqlite")).unwrap());

        // 64 KiB chunks: the big file spans many flush boundaries yet the
        // whole test moves only tens of MiB. The big file is deliberately
        // not chunk-aligned and its byte pattern detects any misalignment.
        let chunk = 64 * 1024;
        let small_data = b"hello resume";
        let big_size = 1024 * chunk + 123;
        let big_data: Vec<u8> = (0..big_size).map(|i| (i % 251) as u8).collect();

        let small = Vfs::join(&root_id, "a-small.bin");
        vfs.write_range(&small, 0, small_data).await.unwrap();
        let big = Vfs::join(&root_id, "b-big.bin");
        vfs.write_range(&big, 0, &big_data).await.unwrap();

        let dst = vfs.create_dir(&root_id, "dst").await.unwrap();
        let opts = CopyOptions {
            chunk_size: chunk,
            conflict: ConflictPolicy::Overwrite,
            recursive: true,
            ..Default::default()
        };
        let sources = vec![small.clone(), big.clone()];

        // First "process": crash once the small file is fully copied plus at
        // least one mid-file flush of the big one is guaranteed persisted
        // (small counts 1 chunk, so 20 chunks in means the 16-chunk flush
        // long happened; the ~1000 remaining chunks make the abort window
        // races practically impossible).
        let stored = crash_while_copying(
            vfs.clone(),
            sources.clone(),
            dst.id.clone(),
            opts.clone(),
            index.clone(),
            "t-resume",
            small_data.len() as u64 + 20 * chunk as u64,
        )
        .await;

        assert_eq!(stored.files_total, 2);
        assert_eq!(
            stored.bytes_total,
            small_data.len() as u64 + big_size as u64
        );
        assert_eq!(stored.files_done, 1);
        let big_offset = stored
            .file_offsets
            .iter()
            .find(|offset| offset.source_id == big)
            .map(|offset| offset.offset)
            .expect("big file must have a checkpoint");
        assert_eq!(big_offset % chunk as u64, 0);
        assert!((1..big_size as u64).contains(&big_offset));
        assert_eq!(stored.bytes_done, small_data.len() as u64 + big_offset);

        // Prove the resume below does not rewrite the prefix: plant a marker
        // inside the already-copied region of the destination file.
        let dest_big = Vfs::join(&dst.id, "b-big.bin");
        let marker = [0xABu8; 16];
        assert!(big_offset > 24, "checkpoint must be past the marker");
        vfs.write_range(&dest_big, 8, &marker).await.unwrap();

        // Second "process": fresh handle (same transfer id) resumes.
        let handle2 = Arc::new(TransferHandle::new("t-resume", CancelToken::new()));
        run_resumable(
            vfs.clone(),
            sources,
            dst.id.clone(),
            opts,
            handle2.clone(),
            index.clone(),
            Some(stored),
        )
        .await;

        let snapshot = handle2.snapshot();
        assert_eq!(snapshot.state, TransferState::Completed, "{snapshot:?}");
        assert_eq!(snapshot.files_done, 2);
        assert_eq!(
            snapshot.bytes_done,
            small_data.len() as u64 + big_size as u64
        );

        let written = vfs.read_range(&dest_big, 0, big_data.len()).await.unwrap();
        // Marker survived => bytes below the checkpoint were NOT rewritten.
        assert_eq!(&written[8..24], &marker, "prefix was rewritten");
        assert_eq!(&written[..8], &big_data[..8]);
        assert_eq!(&written[24..], &big_data[24..]);
        // The fully-finished small file was skipped, not mangled.
        assert_eq!(
            vfs.read_range(&Vfs::join(&dst.id, "a-small.bin"), 0, small_data.len())
                .await
                .unwrap(),
            small_data
        );

        // Terminal state written; nothing left to resume.
        assert!(index.load_unfinished_transfers().unwrap().is_empty());

        std::fs::remove_dir_all(&root).ok();
    }

    #[tokio::test]
    async fn move_deletes_sources_after_copy() {
        let root = temp_root("move");
        let vfs = Arc::new(Vfs::with_local_root(&root).unwrap());
        let root_id = vfs.local_root().to_string();
        let src = vfs.create_dir(&root_id, "src").await.unwrap();
        let file = vfs.create_file(&src.id, "a.txt").await.unwrap();
        vfs.write_range(&file.id, 0, b"move me").await.unwrap();
        let dst = vfs.create_dir(&root_id, "dst").await.unwrap();

        let handle = Arc::new(TransferHandle::new("t-move", CancelToken::new()));
        run(
            vfs.clone(),
            vec![src.id.clone()],
            dst.id.clone(),
            CopyOptions {
                conflict: ConflictPolicy::Overwrite,
                delete_sources: true,
                ..Default::default()
            },
            handle.clone(),
        )
        .await;

        assert_eq!(handle.snapshot().state, TransferState::Completed);
        assert!(vfs.stat(&src.id).await.is_err(), "source must be deleted");
        let copied = Vfs::join(&dst.id, "src");
        assert_eq!(
            vfs.read_range(&Vfs::join(&copied, "a.txt"), 0, 7)
                .await
                .unwrap(),
            b"move me"
        );
        std::fs::remove_dir_all(&root).ok();
    }

    #[tokio::test]
    async fn resumed_move_still_deletes_sources() {
        let root = temp_root("move-resume");
        let vfs = Arc::new(Vfs::with_local_root(&root).unwrap());
        let root_id = vfs.local_root().to_string();
        let index = Arc::new(Index::open(root.join("index.sqlite")).unwrap());
        let chunk = 64 * 1024;
        let data: Vec<u8> = vec![9u8; 64 * chunk];
        let src = Vfs::join(&root_id, "movie.mkv");
        vfs.write_range(&src, 0, &data).await.unwrap();
        let dst = vfs.create_dir(&root_id, "dst").await.unwrap();
        let opts = CopyOptions {
            chunk_size: chunk,
            conflict: ConflictPolicy::Overwrite,
            recursive: true,
            delete_sources: true,
        };

        let stored = crash_while_copying(
            vfs.clone(),
            vec![src.clone()],
            dst.id.clone(),
            opts.clone(),
            index.clone(),
            "t-move-resume",
            (2 * chunk) as u64,
        )
        .await;
        assert!(stored.is_move, "move flag must be persisted");
        assert!(vfs.stat(&src).await.is_ok(), "crash must not delete the source");

        let handle = Arc::new(TransferHandle::new("t-move-resume", CancelToken::new()));
        run_resumable(
            vfs.clone(),
            vec![src.clone()],
            dst.id.clone(),
            opts,
            handle.clone(),
            index,
            Some(stored),
        )
        .await;

        assert_eq!(handle.snapshot().state, TransferState::Completed);
        assert!(
            vfs.stat(&src).await.is_err(),
            "resumed move must delet the source"
        );
        assert_eq!(
            vfs.read_range(&Vfs::join(&dst.id, "movie.mkv"), 0, data.len())
                .await
                .unwrap(),
            data
        );
        std::fs::remove_dir_all(&root).ok();
    }

    #[tokio::test]
    async fn resumed_run_fails_cleanly_when_source_vanished() {
        let root = temp_root("resume-gone");
        let vfs = Arc::new(Vfs::with_local_root(&root).unwrap());
        let root_id = vfs.local_root().to_string();
        let index = Arc::new(Index::open(root.join("index.sqlite")).unwrap());

        let chunk = 64 * 1024;
        let data: Vec<u8> = vec![7u8; 1024 * chunk];
        let src = Vfs::join(&root_id, "movie.mkv");
        vfs.write_range(&src, 0, &data).await.unwrap();
        let dst = vfs.create_dir(&root_id, "dst").await.unwrap();
        let opts = CopyOptions {
            chunk_size: chunk,
            conflict: ConflictPolicy::Overwrite,
            recursive: true,
            ..Default::default()
        };

        let stored = crash_while_copying(
            vfs.clone(),
            vec![src.clone()],
            dst.id.clone(),
            opts.clone(),
            index.clone(),
            "t-gone",
            20 * chunk as u64,
        )
        .await;

        // The source disappears before the app restarts.
        vfs.remove(&src, false).await.unwrap();

        let handle = Arc::new(TransferHandle::new("t-gone", CancelToken::new()));
        run_resumable(
            vfs.clone(),
            vec![src],
            dst.id.clone(),
            opts,
            handle.clone(),
            index.clone(),
            Some(stored),
        )
        .await;

        let snapshot = handle.snapshot();
        assert_eq!(snapshot.state, TransferState::Failed, "{snapshot:?}");
        let error = snapshot.error.expect("failure must carry a message");
        assert!(error.contains("not found"), "unexpected error: {error}");
        // The failure is terminal, not something every restart would retry.
        assert!(index.load_unfinished_transfers().unwrap().is_empty());

        std::fs::remove_dir_all(&root).ok();
    }

    #[tokio::test]
    async fn mismatched_record_is_ignored_and_copy_starts_fresh() {
        let root = temp_root("resume-stale");
        let vfs = Arc::new(Vfs::with_local_root(&root).unwrap());
        let root_id = vfs.local_root().to_string();
        let index = Arc::new(Index::open(root.join("index.sqlite")).unwrap());

        let src = Vfs::join(&root_id, "photo.jpg");
        vfs.write_range(&src, 0, b"eight!").await.unwrap();
        let dst_a = vfs.create_dir(&root_id, "a").await.unwrap();
        let dst_b = vfs.create_dir(&root_id, "b").await.unwrap();

        // A stale record describes a different destination: it must not seed
        // progress or offsets into this copy.
        let mut stale = StoredTransfer::new_running("t-stale", vec![src.clone()], &dst_a.id, 1, 6);
        stale.bytes_done = 6;
        stale.files_done = 1;
        index.save_transfer(&stale).unwrap();

        let handle = Arc::new(TransferHandle::new("t-stale", CancelToken::new()));
        run_resumable(
            vfs.clone(),
            vec![src.clone()],
            dst_b.id.clone(),
            CopyOptions {
                conflict: ConflictPolicy::Overwrite,
                ..Default::default()
            },
            handle.clone(),
            index.clone(),
            Some(stale),
        )
        .await;

        let snapshot = handle.snapshot();
        assert_eq!(snapshot.state, TransferState::Completed, "{snapshot:?}");
        assert_eq!(snapshot.files_done, 1);
        assert_eq!(snapshot.bytes_done, 6, "no seeded progress expected");
        assert_eq!(
            vfs.read_range(&Vfs::join(&dst_b.id, "photo.jpg"), 0, 6)
                .await
                .unwrap(),
            b"eight!"
        );
        assert!(index.load_unfinished_transfers().unwrap().is_empty());

        std::fs::remove_dir_all(&root).ok();
    }

    #[tokio::test]
    async fn rename_policy_avoids_overwrite() {
        let root = temp_root("conflict");
        let vfs = Arc::new(Vfs::with_local_root(&root).unwrap());
        let root_id = vfs.local_root().to_string();

        let src = vfs.create_dir(&root_id, "src").await.unwrap();
        vfs.write_range(&Vfs::join(&src.id, "a.txt"), 0, b"new")
            .await
            .unwrap();
        vfs.write_range(&Vfs::join(&root_id, "a.txt"), 0, b"old")
            .await
            .unwrap();

        let handle = Arc::new(TransferHandle::new("t2", CancelToken::new()));
        run(
            vfs.clone(),
            vec![Vfs::join(&src.id, "a.txt")],
            root_id.clone(),
            CopyOptions {
                conflict: ConflictPolicy::Rename,
                ..Default::default()
            },
            handle.clone(),
        )
        .await;

        assert_eq!(handle.snapshot().state, TransferState::Completed);
        assert_eq!(
            vfs.read_range(&Vfs::join(&root_id, "a (1).txt"), 0, 3)
                .await
                .unwrap(),
            b"new"
        );

        std::fs::remove_dir_all(&root).ok();
    }
}
