use std::sync::Arc;

use vfs_core::{Entry, Result, Vfs, VfsError, DEFAULT_CHUNK_SIZE};

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
}

impl Default for CopyOptions {
    fn default() -> Self {
        Self {
            chunk_size: DEFAULT_CHUNK_SIZE,
            conflict: ConflictPolicy::Skip,
            recursive: true,
        }
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

    match run_inner(&vfs, &sources, &dest_dir, &opts, &handle).await {
        Ok(()) => handle.finish_ok(),
        Err(VfsError::Cancelled) => handle.finish_cancelled(),
        Err(err) => handle.finish_err(err.to_string()),
    }
}

async fn run_inner(
    vfs: &Vfs,
    sources: &[String],
    dest_dir: &str,
    opts: &CopyOptions,
    handle: &TransferHandle,
) -> Result<()> {
    // Pre-scan so the UI can show a real progress bar instead of a spinner.
    let mut files_total = 0u64;
    let mut bytes_total = 0u64;
    for source in sources {
        let (files, bytes) = scan(vfs, source, opts.recursive, 0, handle).await?;
        files_total += files;
        bytes_total += bytes;
    }
    handle.set_totals(files_total, bytes_total);

    for source in sources {
        copy_tree(vfs, source, dest_dir, opts, handle).await?;
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
            copy_file(vfs, &entry, &target, opts.chunk_size, handle).await?;
            handle.complete_file();
        }
    }
    Ok(())
}

async fn copy_file(
    vfs: &Vfs,
    entry: &Entry,
    target: &str,
    chunk_size: usize,
    handle: &TransferHandle,
) -> Result<()> {
    if entry.size == 0 {
        vfs.write_range(target, 0, &[]).await?;
        vfs.truncate(target, 0).await?;
        return Ok(());
    }

    let mut offset = 0u64;
    while offset < entry.size {
        if handle.is_cancelled() {
            return Err(VfsError::Cancelled);
        }
        let chunk = vfs.read_range(&entry.id, offset, chunk_size.max(1)).await?;
        if chunk.is_empty() {
            break;
        }
        vfs.write_range(target, offset, &chunk).await?;
        offset += chunk.len() as u64;
        handle.add_bytes(chunk.len() as u64);
    }
    // Shrink leftovers when overwriting a larger file with a smaller one.
    vfs.truncate(target, offset).await?;
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
