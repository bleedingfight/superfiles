//! UniFFI surface.
//!
//! Design rules:
//!
//! * All exported methods are **synchronous**. Swift/Kotlin call them from a
//!   background executor and hop back to the UI thread. This avoids tying the
//!   core to a specific async-runtime integration on each platform (and avoids
//!   the "no tokio runtime on the JNI thread" trap).
//! * Long running work (copies) is started with `start_copy` and observed by
//!   polling snapshots. Cancellation is an explicit call.
//! * Bytes never cross the boundary: use `export_to_fd` / `import_from_fd` with
//!   a platform owned file descriptor.
//! * The wire types (`Entry`, `Capabilities`, ...) live *here*, not in the core
//!   crates. The core stays plain Rust, so it can be reused by a CLI, a desktop
//!   shell or a WASM build without dragging UniFFI along.

uniffi::setup_scaffolding!();

use std::collections::HashMap;
use std::future::Future;
use std::hash::{Hash, Hasher};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::thread::JoinHandle;

use sfiles_engine::{ConflictPolicy as EngineConflict, CopyOptions, TransferHandle};
use sfiles_index::Index;
use tokio::runtime::Runtime;
use vfs_core::{CancelToken, Vfs, VfsError};

// ---------------------------------------------------------------------------
// Wire types
// ---------------------------------------------------------------------------

/// Kind of filesystem object.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum EntryKind {
    File,
    Directory,
    Symlink,
    Special,
}

impl From<vfs_core::EntryKind> for EntryKind {
    fn from(kind: vfs_core::EntryKind) -> Self {
        match kind {
            vfs_core::EntryKind::File => EntryKind::File,
            vfs_core::EntryKind::Directory => EntryKind::Directory,
            vfs_core::EntryKind::Symlink => EntryKind::Symlink,
            vfs_core::EntryKind::Special => EntryKind::Special,
        }
    }
}

/// A single filesystem entry as seen by the UI.
#[derive(Debug, Clone, uniffi::Record)]
pub struct Entry {
    pub id: String,
    pub parent: Option<String>,
    pub name: String,
    pub kind: EntryKind,
    pub size: u64,
    pub modified_ms: Option<i64>,
    pub mime: Option<String>,
    pub hidden: bool,
    pub readonly: bool,
}

impl From<vfs_core::Entry> for Entry {
    fn from(entry: vfs_core::Entry) -> Self {
        Self {
            id: entry.id,
            parent: entry.parent,
            name: entry.name,
            kind: entry.kind.into(),
            size: entry.size,
            modified_ms: entry.modified_ms,
            mime: entry.mime,
            hidden: entry.hidden,
            readonly: entry.readonly,
        }
    }
}

/// What the current backend can do. Drives UI button state.
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct Capabilities {
    pub can_list: bool,
    pub can_read: bool,
    pub can_write: bool,
    pub can_create: bool,
    pub can_rename: bool,
    pub can_delete: bool,
    pub can_seek: bool,
    pub can_random_write: bool,
    pub can_watch: bool,
    pub native_thumbnails: bool,
}

impl From<vfs_core::Capabilities> for Capabilities {
    fn from(caps: vfs_core::Capabilities) -> Self {
        Self {
            can_list: caps.can_list,
            can_read: caps.can_read,
            can_write: caps.can_write,
            can_create: caps.can_create,
            can_rename: caps.can_rename,
            can_delete: caps.can_delete,
            can_seek: caps.can_seek,
            can_random_write: caps.can_random_write,
            can_watch: caps.can_watch,
            native_thumbnails: caps.native_thumbnails,
        }
    }
}

/// Conflict handling policy for copies.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ConflictPolicy {
    Overwrite,
    Skip,
    Rename,
}

/// Archive method for `compressZip`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ZipMethod {
    /// 仅打包不压缩（最快，体积不变）。
    Store,
    /// Deflate 压缩（默认）。
    Deflate,
}

/// Progress callback for `compressZip`: reports `(done, total)` source bytes.
#[uniffi::export(with_foreign)]
pub trait ZipProgressListener: Send + Sync {
    fn on_progress(&self, done: u64, total: u64);
}

/// One recently opened file, resolved from the index + vfs.
#[derive(Debug, Clone, uniffi::Record)]
pub struct RecentOpen {
    pub entry: Entry,
    pub opened_ms: u64,
}

/// One favorited entry, resolved from the index + vfs.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FavoriteEntry {
    pub entry: Entry,
    pub added_ms: u64,
}

/// A directory listing served from the local cache (M1 离线浏览)：
/// 实时 `list` 失败（断网/服务不可达）时由 UI 回退展示，并附过期标记。
#[derive(Debug, Clone, uniffi::Record)]
pub struct CachedListing {
    pub entries: Vec<Entry>,
    /// 上次成功列举时间（epoch ms；None = 该目录从未缓存）。
    pub listed_at_ms: Option<i64>,
}

/// 一次进行中「就近分享」的信息（ADR 0005）。
#[derive(Debug, Clone, uniffi::Record)]
pub struct ShareInfo {
    /// 二维码/链接内容：`http://<lan-ip>:port/<token>/`。
    pub url: String,
    pub port: u16,
    pub file_count: u32,
}

/// Progress callback for `indexDirWithProgress`：
/// `fraction ∈ [0,1]` 单调递增（按「已处理目录 / 已处理+待处理」估算）。
#[uniffi::export(with_foreign)]
pub trait IndexProgressListener: Send + Sync {
    fn on_progress(&self, directories: u64, entries: u64, fraction: f32);
    fn on_finished(&self, total: u64);
}

impl From<ConflictPolicy> for EngineConflict {
    fn from(policy: ConflictPolicy) -> Self {
        match policy {
            ConflictPolicy::Overwrite => EngineConflict::Overwrite,
            ConflictPolicy::Skip => EngineConflict::Skip,
            ConflictPolicy::Rename => EngineConflict::Rename,
        }
    }
}

/// Lifecycle of a transfer task.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TransferState {
    Queued,
    Running,
    Completed,
    Failed,
    Cancelled,
}

impl From<sfiles_engine::TransferState> for TransferState {
    fn from(state: sfiles_engine::TransferState) -> Self {
        match state {
            sfiles_engine::TransferState::Queued => TransferState::Queued,
            sfiles_engine::TransferState::Running => TransferState::Running,
            sfiles_engine::TransferState::Completed => TransferState::Completed,
            sfiles_engine::TransferState::Failed => TransferState::Failed,
            sfiles_engine::TransferState::Cancelled => TransferState::Cancelled,
        }
    }
}

/// Immutable progress snapshot, polled by the UI.
#[derive(Debug, Clone, uniffi::Record)]
pub struct TransferSnapshot {
    pub id: String,
    pub state: TransferState,
    pub bytes_done: u64,
    pub bytes_total: u64,
    pub files_done: u64,
    pub files_total: u64,
    pub current: Option<String>,
    pub error: Option<String>,
}

/// One mounted remote connection, as listed by the connection UI.
#[derive(Debug, Clone, uniffi::Record)]
pub struct MountInfo {
    pub scheme: String,
    pub label: String,
    pub root_id: String,
}

/// A transfer a previous run didn't finish (crash / killed app), restored
/// from the index on the next launch. Feed `id` to `resumeTransfer` to
/// continue it, or `forgetTransfer` to drop it.
#[derive(Debug, Clone, uniffi::Record)]
pub struct PendingTransfer {
    pub id: String,
    pub sources: Vec<String>,
    pub dest_dir: String,
    pub is_move: bool,
    pub files_total: u64,
    pub files_done: u64,
    pub bytes_total: u64,
    pub bytes_done: u64,
}

impl From<sfiles_index::StoredTransfer> for PendingTransfer {
    fn from(stored: sfiles_index::StoredTransfer) -> Self {
        Self {
            id: stored.id,
            sources: stored.sources,
            dest_dir: stored.dest_dir,
            is_move: stored.is_move,
            files_total: stored.files_total,
            files_done: stored.files_done,
            bytes_total: stored.bytes_total,
            bytes_done: stored.bytes_done,
        }
    }
}

impl From<sfiles_engine::TransferSnapshot> for TransferSnapshot {
    fn from(snapshot: sfiles_engine::TransferSnapshot) -> Self {
        Self {
            id: snapshot.id,
            state: snapshot.state.into(),
            bytes_done: snapshot.bytes_done,
            bytes_total: snapshot.bytes_total,
            files_done: snapshot.files_done,
            files_total: snapshot.files_total,
            current: snapshot.current,
            error: snapshot.error,
        }
    }
}

/// Error type shared by every method.
#[derive(Debug, Clone, thiserror::Error, uniffi::Error)]
pub enum SfError {
    #[error("{detail}")]
    NotFound { detail: String },
    #[error("{detail}")]
    PermissionDenied { detail: String },
    #[error("{detail}")]
    AlreadyExists { detail: String },
    #[error("{detail}")]
    Unsupported { detail: String },
    #[error("{detail}")]
    Network { detail: String },
    #[error("{detail}")]
    InvalidName { detail: String },
    #[error("{detail}")]
    Io { detail: String },
    #[error("{detail}")]
    Cancelled { detail: String },
}

impl From<VfsError> for SfError {
    fn from(err: VfsError) -> Self {
        match err {
            VfsError::NotFound(detail) => SfError::NotFound { detail },
            VfsError::PermissionDenied(detail) => SfError::PermissionDenied { detail },
            VfsError::AlreadyExists(detail) => SfError::AlreadyExists { detail },
            VfsError::Unsupported(detail) => SfError::Unsupported { detail },
            VfsError::Network(detail) => SfError::Network { detail },
            VfsError::InvalidName(detail) => SfError::InvalidName { detail },
            VfsError::Io(detail) => SfError::Io { detail },
            VfsError::Cancelled => SfError::Cancelled {
                detail: "operation cancelled".into(),
            },
        }
    }
}

// ---------------------------------------------------------------------------
// LocalSend（局域网直传：HTTPS + 组播发现）
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, uniffi::Record)]
pub struct LocalSendOptions {
    pub alias: String,
    pub device_model: String,
    pub port: u16,
    /// Persistent certificate/key directory (usually app filesDir).
    pub store_dir: String,
    /// VFS id of the receive directory.
    pub dest_dir: String,
    pub pin: Option<String>,
    pub enable_discovery: bool,
    /// Security: auto-stop after this many seconds without transfer activity
    /// (0 = never).
    pub idle_timeout_secs: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct LocalSendInfo {
    pub alias: String,
    pub port: u16,
    pub fingerprint: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct LocalSendPeer {
    pub alias: String,
    pub ip: String,
    pub port: u16,
    pub fingerprint: String,
    pub device_type: String,
    pub last_seen_ms: u64,
}

#[derive(uniffi::Object)]
pub struct LocalSendHandle {
    service: sfiles_localsend::LocalSendService,
}

fn localsend_error(err: sfiles_localsend::Error) -> SfError {
    // Include the full source chain: rustls reports the useful part (e.g.
    // "received fatal alert: handshake_failure") on the inner io error.
    let mut detail = format!("localsend: {err}");
    let mut source = std::error::Error::source(&err);
    while let Some(inner) = source {
        detail.push_str(" <- ");
        detail.push_str(&inner.to_string());
        source = inner.source();
    }
    SfError::Io { detail }
}

fn parse_fingerprint(value: &str) -> Option<[u8; 32]> {
    if value.len() != 64 {
        return None;
    }
    let mut out = [0u8; 32];
    for (i, chunk) in value.as_bytes().chunks(2).enumerate() {
        let hi = (chunk[0] as char).to_digit(16)?;
        let lo = (chunk[1] as char).to_digit(16)?;
        out[i] = (hi * 16 + lo) as u8;
    }
    Some(out)
}

fn peer_to_ffi(peer: sfiles_localsend::DiscoveredPeer) -> LocalSendPeer {
    LocalSendPeer {
        alias: peer.alias,
        ip: peer.ip.to_string(),
        port: peer.port,
        fingerprint: peer.fingerprint,
        device_type: peer.device_type,
        last_seen_ms: peer.last_seen_ms,
    }
}

#[uniffi::export]
impl LocalSendHandle {
    pub fn is_running(&self) -> bool {
        self.service.is_running()
    }

    pub fn info(&self) -> LocalSendInfo {
        let info = self.service.info();
        LocalSendInfo {
            alias: info.alias,
            port: info.port,
            fingerprint: info.fingerprint,
        }
    }

    /// Recent protocol errors (interop diagnostics, newest last).
    pub fn errors(&self) -> Vec<String> {
        runtime().block_on(self.service.errors())
    }

    /// Force an immediate multicast announcement (UI "refresh").
    pub fn announce(&self) {
        runtime().block_on(self.service.announce());
    }

    pub fn peers(&self) -> Vec<LocalSendPeer> {
        runtime()
            .block_on(self.service.peers())
            .into_iter()
            .map(peer_to_ffi)
            .collect()
    }

    /// Manual IP fallback. `fingerprint` is the expected SHA-256 of the peer
    /// certificate; omit it only for first-time discovery.
    pub fn register_at(
        &self,
        ip: String,
        port: u16,
        fingerprint: Option<String>,
    ) -> Result<LocalSendPeer, SfError> {
        let ip: std::net::IpAddr = ip
            .parse()
            .map_err(|_| SfError::InvalidName { detail: "invalid IP address".into() })?;
        let expected = fingerprint.as_deref().and_then(parse_fingerprint);
        let info = runtime()
            .block_on(self.service.register_at(ip, port, expected))
            .map_err(localsend_error)?;
        Ok(LocalSendPeer {
            alias: info.alias,
            ip: ip.to_string(),
            port: if info.port == 0 { port } else { info.port },
            fingerprint: info.fingerprint,
            device_type: info.device_type.unwrap_or_else(|| "desktop".into()),
            last_seen_ms: now_ms(),
        })
    }

    pub fn send(&self, peer: LocalSendPeer, ids: Vec<String>) -> Result<(), SfError> {
        let peer = sfiles_localsend::DiscoveredPeer {
            alias: peer.alias,
            ip: peer
                .ip
                .parse()
                .map_err(|_| SfError::InvalidName { detail: "invalid IP address".into() })?,
            port: peer.port,
            fingerprint: peer.fingerprint,
            device_type: peer.device_type,
            last_seen_ms: peer.last_seen_ms,
        };
        runtime()
            .block_on(self.service.send(&peer, ids))
            .map_err(localsend_error)
    }

    pub fn stop(&self) {
        runtime().block_on(self.service.stop());
    }
}

// ---------------------------------------------------------------------------
// Runtime
// ---------------------------------------------------------------------------

fn runtime() -> &'static Runtime {
    static RT: OnceLock<Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        // 传输任务与所有 FFI 调用共享这个 runtime。2 个 worker 时后台复制会把
        // worker 占满（尤其在 fsync / 大批量 IO 上），前台列举随之变慢甚至卡顿；
        // 实测复制期间 list p50：2 worker 30ms → 4 worker 16ms。按核心数给 4~8。
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(
                std::thread::available_parallelism()
                    .map(|n| n.get().clamp(4, 8))
                    .unwrap_or(4),
            )
            .thread_name("sfiles-core")
            .enable_all()
            .build()
            .expect("failed to start Super Files runtime")
    })
}

/// Epoch milliseconds（列表缓存/收藏/最近打开的时间戳统一口径）。
fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

// ---------------------------------------------------------------------------
// Listing-cache writer (off the `list()` critical path)
// ---------------------------------------------------------------------------

/// Background writer that mirrors successful `list()` results into the index.
///
/// `list()` used to upsert + prune + timestamp synchronously before
/// returning. Even after the rowid fix (O(1) FTS deletes) that is ~10ms per
/// 1k entries and it shares the index mutex with a running background scan,
/// so entering a directory could stall behind a scan. Now the UI gets the
/// directory immediately and this worker applies the listing in the
/// background, coalescing repeated listings of the same directory and
/// skipping directories whose entries did not change at all.
struct IndexWriter {
    inner: Arc<WriterInner>,
    handle: Mutex<Option<JoinHandle<()>>>,
}

struct WriterInner {
    state: Mutex<WriterState>,
    cv: Condvar,
}

struct WriterState {
    /// dir id -> (entries, listed_at_ms). Re-listing the same directory
    /// replaces the queued job: only the newest listing is meaningful.
    pending: HashMap<String, (Vec<vfs_core::Entry>, i64)>,
    busy: bool,
    stop: bool,
}

impl IndexWriter {
    fn spawn(index: Arc<Index>) -> Self {
        let inner = Arc::new(WriterInner {
            state: Mutex::new(WriterState {
                pending: HashMap::new(),
                busy: false,
                stop: false,
            }),
            cv: Condvar::new(),
        });
        let worker_inner = inner.clone();
        let handle = std::thread::Builder::new()
            .name("sf-index-writer".into())
            .spawn(move || index_writer_loop(worker_inner, index))
            .expect("spawn index writer thread");
        Self {
            inner,
            handle: Mutex::new(Some(handle)),
        }
    }

    fn enqueue(&self, dir: String, entries: Vec<vfs_core::Entry>, listed_at: i64) {
        let mut state = lock_state(&self.inner.state);
        state.pending.insert(dir, (entries, listed_at));
        self.inner.cv.notify_all();
    }

    /// Block until the queue is empty. Used by callers that must observe the
    /// index immediately (search, offline-cache fallback, tests).
    fn flush(&self) {
        let mut state = lock_state(&self.inner.state);
        while !state.pending.is_empty() || state.busy {
            state = self
                .inner
                .cv
                .wait(state)
                .unwrap_or_else(|e| e.into_inner());
        }
    }

    /// Drain and stop. Called from `Drop`; joins so a test that drops the
    /// facade still sees a consistent index.
    fn shutdown(&self) {
        {
            let mut state = lock_state(&self.inner.state);
            state.stop = true;
            self.inner.cv.notify_all();
        }
        if let Ok(mut slot) = self.handle.lock() {
            if let Some(handle) = slot.take() {
                let _ = handle.join();
            }
        }
    }
}

fn lock_state(mutex: &Mutex<WriterState>) -> std::sync::MutexGuard<'_, WriterState> {
    mutex.lock().unwrap_or_else(|e| e.into_inner())
}

fn index_writer_loop(inner: Arc<WriterInner>, index: Arc<Index>) {
    let mut last_hash: HashMap<String, u64> = HashMap::new();
    loop {
        let batch = {
            let mut state = lock_state(&inner.state);
            while state.pending.is_empty() && !state.stop {
                state = inner.cv.wait(state).unwrap_or_else(|e| e.into_inner());
            }
            if state.pending.is_empty() && state.stop {
                return;
            }
            state.busy = true;
            std::mem::take(&mut state.pending)
        };
        for (dir, (entries, listed_at)) in batch {
            let hash = hash_entries(&entries);
            if last_hash.get(&dir) != Some(&hash) {
                if index.upsert_all(&entries).is_ok() {
                    let keep: Vec<String> = entries.iter().map(|e| e.id.clone()).collect();
                    let _ = index.prune_children(&dir, &keep);
                    last_hash.insert(dir.clone(), hash);
                }
            }
            let _ = index.record_listing(&dir, listed_at);
        }
        let mut state = lock_state(&inner.state);
        state.busy = false;
        inner.cv.notify_all();
    }
}

/// Cheap content fingerprint: a listing is skipped when nothing in it moved
/// (re-entering an unchanged directory costs nothing).
fn hash_entries(entries: &[vfs_core::Entry]) -> u64 {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    for entry in entries {
        entry.id.hash(&mut hasher);
        entry.name.hash(&mut hasher);
        matches!(entry.kind, vfs_core::EntryKind::Directory).hash(&mut hasher);
        entry.size.hash(&mut hasher);
        entry.modified_ms.hash(&mut hasher);
        entry.hidden.hash(&mut hasher);
        entry.readonly.hash(&mut hasher);
    }
    hasher.finish()
}

// ---------------------------------------------------------------------------
// Facade
// ---------------------------------------------------------------------------

/// The single object the app talks to.
#[derive(uniffi::Object)]
pub struct SuperFiles {
    vfs: Arc<Vfs>,
    root_id: String,
    index: Option<Arc<Index>>,
    index_writer: Option<IndexWriter>,
    transfers: Mutex<HashMap<String, Arc<TransferHandle>>>,
    counter: AtomicU64,
    mounts: Mutex<HashMap<String, MountInfo>>,
    streamer: Mutex<Option<Arc<sfiles_stream::StreamServer>>>,
    share: Mutex<Option<sfiles_stream::ShareServer>>,
    localsend: Mutex<Option<Arc<LocalSendHandle>>>,
}

#[uniffi::export]
impl SuperFiles {
    /// Open app storage rooted at `local_root`.
    ///
    /// * iOS: pass the container's Documents directory.
    /// * Android: pass `context.filesDir` for M0 (no storage permission needed).
    #[uniffi::constructor]
    pub fn open(local_root: String, index_path: Option<String>) -> Result<Arc<Self>, SfError> {
        let vfs = Arc::new(Vfs::with_local_root(&local_root)?);
        let index = match index_path {
            Some(path) => Some(Arc::new(Index::open(path)?)),
            None => None,
        };
        let index_writer = index.as_ref().map(|i| IndexWriter::spawn(i.clone()));
        let root_id = vfs.local_root().to_string();
        Ok(Arc::new(Self {
            vfs,
            root_id,
            index,
            index_writer,
            transfers: Mutex::new(HashMap::new()),
            counter: AtomicU64::new(1),
            mounts: Mutex::new(HashMap::new()),
            streamer: Mutex::new(None),
            share: Mutex::new(None),
            localsend: Mutex::new(None),
        }))
    }

    pub fn version(&self) -> String {
        env!("CARGO_PKG_VERSION").to_string()
    }

    /// Id of the default local root (what the browser opens first).
    pub fn root_id(&self) -> String {
        self.root_id.clone()
    }

    /// Display path for header/breadcrumbs.
    pub fn display_path(&self, id: String) -> String {
        Vfs::display_path(&id)
    }

    pub fn capabilities(&self, id: String) -> Result<Capabilities, SfError> {
        Ok(self.vfs.capabilities(&id)?.into())
    }

    pub fn stat(&self, id: String) -> Result<Entry, SfError> {
        Ok(self.block_on(self.vfs.stat(&id))?.into())
    }

    pub fn list(&self, id: String) -> Result<Vec<Entry>, SfError> {
        let entries = self.block_on(self.vfs.list(&id))?;
        // 列表结果写索引（M1）：交给后台写线程，前台只付 readdir+stat 的钱。
        // 队列按目录合并（重复列举只保留最新一次），内容未变的目录整单跳过。
        if let Some(writer) = &self.index_writer {
            writer.enqueue(id.clone(), entries.clone(), now_ms() as i64);
        }
        Ok(entries.into_iter().map(Entry::from).collect())
    }

    /// 离线缓存列举（M1 离线浏览）：返回索引中 `id` 的直接子项与上次更新
    /// 时间。`entries` 为空且 `listedAtMs` 为 None 表示无缓存可用；UI 在
    /// 实时 `list` 失败时调用，并把结果标注为「过期缓存」。
    pub fn list_cached(&self, id: String) -> CachedListing {
        // 读后写一致：先把队列里的列举落盘，再读缓存（离线回退/测试依赖）
        if let Some(writer) = &self.index_writer {
            writer.flush();
        }
        let Some(index) = &self.index else {
            return CachedListing {
                entries: Vec::new(),
                listed_at_ms: None,
            };
        };
        CachedListing {
            entries: index
                .children_of(&id)
                .unwrap_or_default()
                .into_iter()
                .map(Entry::from)
                .collect(),
            listed_at_ms: index.listed_at(&id).ok().flatten(),
        }
    }

    pub fn create_dir(&self, parent: String, name: String) -> Result<Entry, SfError> {
        Ok(self.block_on(self.vfs.create_dir(&parent, &name))?.into())
    }

    pub fn create_file(&self, parent: String, name: String) -> Result<Entry, SfError> {
        Ok(self.block_on(self.vfs.create_file(&parent, &name))?.into())
    }

    pub fn remove(&self, id: String, recursive: bool) -> Result<(), SfError> {
        Ok(self.block_on(self.vfs.remove(&id, recursive))?)
    }

    pub fn rename(&self, id: String, new_name: String) -> Result<Entry, SfError> {
        Ok(self.block_on(self.vfs.rename(&id, &new_name))?.into())
    }

    /// Random access read for previews. Keep `len` small (a few hundred KiB).
    pub fn read_bytes(&self, id: String, offset: u64, len: u32) -> Result<Vec<u8>, SfError> {
        Ok(self.block_on(self.vfs.read_range(&id, offset, len as usize))?)
    }

    pub fn write_bytes(&self, id: String, offset: u64, data: Vec<u8>) -> Result<(), SfError> {
        Ok(self.block_on(self.vfs.write_range(&id, offset, &data))?)
    }

    /// Stream a backend file into a caller owned fd (iOS `FileHandle`,
    /// Android `ParcelFileDescriptor`). Returns bytes written.
    pub fn export_to_fd(&self, id: String, fd: i32, offset: u64) -> Result<u64, SfError> {
        let cancel = CancelToken::new();
        Ok(self.block_on(self.vfs.read_to_fd(&id, fd, offset, &cancel))?)
    }

    /// Stream a caller owned fd into the target file. Returns bytes written.
    pub fn import_from_fd(&self, id: String, fd: i32, offset: u64) -> Result<u64, SfError> {
        let cancel = CancelToken::new();
        Ok(self.block_on(self.vfs.write_from_fd(&id, fd, offset, &cancel))?)
    }

    pub fn join(&self, parent: String, name: String) -> String {
        Vfs::join(&parent, &name)
    }

    // ---------------------------------------------------------------- mounts

    /// Mount a WebDAV collection; returns its root id (`webdav://host/`).
    /// Empty user+password means anonymous access.
    pub fn mount_webdav(
        &self,
        label: String,
        base_url: String,
        username: String,
        password: String,
    ) -> Result<String, SfError> {
        let auth = if username.is_empty() && password.is_empty() {
            vfs_core::backends::WebdavAuth::None
        } else {
            vfs_core::backends::WebdavAuth::Basic { username, password }
        };
        let backend = vfs_core::backends::WebdavBackend::new(&base_url, auth)?;
        let root = backend.root_id();
        self.in_runtime(|| self.vfs.mount_at(&root, Arc::new(backend)));
        self.mounts.lock().unwrap().insert(
            root.clone(),
            MountInfo {
                scheme: "webdav".into(),
                label,
                root_id: root.clone(),
            },
        );
        Ok(root)
    }

    /// 枚举 SMB 服务器上可访问的共享名（UI「列出共享」用；需要可达 + 凭据有效）。
    pub fn smb_list_shares(
        &self,
        host: String,
        port: u32,
        username: String,
        password: String,
    ) -> Result<Vec<String>, SfError> {
        let auth = if username.is_empty() && password.is_empty() {
            vfs_core::backends::SmbAuth::guest()
        } else {
            vfs_core::backends::SmbAuth::new(username, password)
        };
        let port = if port == 0 { None } else { Some(port as u16) };
        Ok(self.block_on(vfs_core::backends::smb::list_shares(&host, port, auth))?)
    }

    /// Mount an SMB share (`\\host\share`); returns its root id.
    pub fn mount_smb(
        &self,
        label: String,
        host: String,
        share: String,
        username: String,
        password: String,
        port: u32,
    ) -> Result<String, SfError> {
        let auth = if username.is_empty() && password.is_empty() {
            vfs_core::backends::SmbAuth::guest()
        } else {
            vfs_core::backends::SmbAuth::new(username, password)
        };
        let port = if port == 0 { None } else { Some(port as u16) };
        let backend = self.block_on(vfs_core::backends::SmbBackend::connect(
            &host, &share, port, auth,
        ))?;
        let root = backend.root_id();
        self.in_runtime(|| self.vfs.mount_at(&root, Arc::new(backend)));
        self.mounts.lock().unwrap().insert(
            root.clone(),
            MountInfo {
                scheme: "smb".into(),
                label,
                root_id: root.clone(),
            },
        );
        Ok(root)
    }

    /// Mount an SFTP host (password auth for now; key auth lands with the UI).
    pub fn mount_sftp(
        &self,
        label: String,
        host: String,
        port: u32,
        username: String,
        password: String,
    ) -> Result<String, SfError> {
        let port = u16::try_from(port).map_err(|_| SfError::InvalidName {
            detail: format!("port out of range: {port}"),
        })?;
        let auth = vfs_core::backends::SftpAuth::password(username, password);
        let backend = self.block_on(vfs_core::backends::SftpBackend::connect(&host, port, auth))?;
        let root = backend.root_id();
        self.in_runtime(|| self.vfs.mount_at(&root, Arc::new(backend)));
        self.mounts.lock().unwrap().insert(
            root.clone(),
            MountInfo {
                scheme: "sftp".into(),
                label,
                root_id: root.clone(),
            },
        );
        Ok(root)
    }

    /// Every mounted connection (local root excluded).
    pub fn mounts(&self) -> Vec<MountInfo> {
        self.mounts.lock().unwrap().values().cloned().collect()
    }

    /// Drop a mounted connection. Returns false when `root_id` wasn't mounted.
    pub fn unmount(&self, root_id: String) -> bool {
        self.mounts.lock().unwrap().remove(&root_id);
        // backend 的 Drop（smb 连接析构等）必须在 tokio 上下文内发生
        self.in_runtime(|| self.vfs.unmount(&root_id))
    }

    // ---------------------------------------------------------------- streams

    /// Loopback HTTP(+Range) URL for any backend file with `can_seek`.
    /// Hand it to AVPlayer / ExoPlayer directly. The server starts lazily and
    /// dies with the core.
    pub fn stream_url(&self, id: String) -> Result<String, SfError> {
        let server = self.stream_server()?;
        Ok(server.url_for(&id))
    }

    // ---------------------------------------------------------------- shares

    /// 就近分享（ADR 0005）：把选中的文件经局域网 HTTP 暴露为「链接 + 二维码」
    /// 可下载的临时站点；浏览器免安装直接收，App 走 `manifest.json` 批量收取。
    ///
    /// 仅限文件——目录请 `compressZip` 成包再分享。清单在启动时固定
    /// （名称/大小/mime），内容仍实时读后端。再次调用会停掉上一次分享。
    pub fn start_share(&self, ids: Vec<String>) -> Result<ShareInfo, SfError> {
        if ids.is_empty() {
            return Err(SfError::InvalidName {
                detail: "no entries to share".into(),
            });
        }
        let mut entries = Vec::with_capacity(ids.len());
        for id in &ids {
            let entry = self.block_on(self.vfs.stat(id))?;
            if entry.is_dir() {
                return Err(SfError::Unsupported {
                    detail: format!("「{}」是文件夹：请先在「⋯」里压缩成 zip 再分享", entry.name),
                });
            }
            entries.push(entry);
        }
        let server = self
            .block_on(sfiles_stream::ShareServer::start(self.vfs.clone(), entries))
            .map_err(|err| SfError::Io {
                detail: format!("share server: {err}"),
            })?;
        let info = ShareInfo {
            url: server.base_url(),
            port: server.port(),
            file_count: server.file_count() as u32,
        };
        if let Some(old) = self.share.lock().unwrap().replace(server) {
            self.block_on(old.shutdown());
        }
        Ok(info)
    }

    // ------------------------------------------------------------ localsend

    /// Start the LocalSend-compatible HTTPS receiver + multicast discovery.
    /// Stops any previous instance first.
    pub fn start_local_send(
        &self,
        options: LocalSendOptions,
    ) -> Result<Arc<LocalSendHandle>, SfError> {
        if let Some(old) = self.localsend.lock().unwrap().take() {
            self.block_on(old.service.stop());
        }
        let cfg = sfiles_localsend::LocalSendConfig {
            alias: options.alias,
            device_model: options.device_model,
            device_type: sfiles_localsend::DeviceType::Mobile,
            port: options.port,
            store_dir: std::path::PathBuf::from(options.store_dir),
            dest_dir: options.dest_dir,
            pin: options.pin,
            enable_discovery: options.enable_discovery,
            idle_timeout_secs: options.idle_timeout_secs,
        };
        let service = self
            .block_on(sfiles_localsend::LocalSendService::start(self.vfs.clone(), cfg))
            .map_err(localsend_error)?;
        let handle = Arc::new(LocalSendHandle { service });
        *self.localsend.lock().unwrap() = Some(handle.clone());
        Ok(handle)
    }

    pub fn local_send_handle(&self) -> Option<Arc<LocalSendHandle>> {
        self.localsend.lock().unwrap().clone()
    }

    pub fn stop_local_send(&self) {
        if let Some(handle) = self.localsend.lock().unwrap().take() {
            self.block_on(handle.service.stop());
        }
    }

    /// 关闭当前分享；返回是否有进行中的分享被关闭。
    pub fn stop_share(&self) -> bool {
        let Some(server) = self.share.lock().unwrap().take() else {
            return false;
        };
        self.block_on(server.shutdown());
        true
    }

    // -------------------------------------------------------------- transfers

    /// Start a background copy. Returns a transfer id for polling/cancelling.
    ///
    /// When the core was opened with an index, the copy is journaled: a
    /// process kill mid-way leaves a `pendingTransfers()` entry that
    /// `resumeTransfer(id)` can continue instead of starting over.
    pub fn start_copy(
        &self,
        sources: Vec<String>,
        dest_dir: String,
        conflict: ConflictPolicy,
    ) -> Result<String, SfError> {
        self.start_transfer(sources, dest_dir, conflict, false)
    }

    /// 移动：复制成功后由引擎删除源（并把 `is_move` 写进 transfers 表，
    /// 进程被杀后恢复的任务仍然会完成删除）。
    pub fn start_move(
        &self,
        sources: Vec<String>,
        dest_dir: String,
        conflict: ConflictPolicy,
    ) -> Result<String, SfError> {
        self.start_transfer(sources, dest_dir, conflict, true)
    }

    fn start_transfer(
        &self,
        sources: Vec<String>,
        dest_dir: String,
        conflict: ConflictPolicy,
        is_move: bool,
    ) -> Result<String, SfError> {
        if sources.is_empty() {
            return Err(SfError::InvalidName {
                detail: "no sources given".into(),
            });
        }
        let id = format!(
            "t{}-{}",
            self.counter.fetch_add(1, Ordering::SeqCst),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_millis())
                .unwrap_or(0)
        );
        let handle = Arc::new(TransferHandle::new(id.clone(), CancelToken::new()));
        self.transfers
            .lock()
            .unwrap()
            .insert(id.clone(), handle.clone());

        let vfs = self.vfs.clone();
        let opts = CopyOptions {
            conflict: conflict.into(),
            delete_sources: is_move,
            ..Default::default()
        };
        let index = self.index.clone();
        runtime().spawn(async move {
            match index {
                Some(index) => {
                    sfiles_engine::run_resumable(vfs, sources, dest_dir, opts, handle, index, None)
                        .await
                }
                None => sfiles_engine::run(vfs, sources, dest_dir, opts, handle).await,
            }
        });
        Ok(id)
    }

    /// 记录一次「打开」（首页「最近打开」数据源；需要索引）。
    pub fn record_open(&self, id: String) -> Result<(), SfError> {
        let index = self.require_index()?.clone();
        index.record_open(&id, now_ms())?;
        Ok(())
    }

    /// 收藏（快捷访问标记）：纯标记不改扫描行为。
    pub fn add_favorite(&self, id: String) -> Result<(), SfError> {
        let index = self.require_index()?.clone();
        index.add_favorite(&id, now_ms())?;
        Ok(())
    }

    pub fn remove_favorite(&self, id: String) -> Result<(), SfError> {
        let index = self.require_index()?.clone();
        index.remove_favorite(&id)?;
        Ok(())
    }

    /// 收藏列表（按收藏时间倒序；已删除的路径自动跳过）。
    pub fn favorites(&self, limit: u32) -> Result<Vec<FavoriteEntry>, SfError> {
        let index = self.require_index()?.clone();
        let rows = index.favorite_ids(limit.min(200))?;
        let mut out = Vec::with_capacity(rows.len());
        for (id, added_ms) in rows {
            if let Ok(entry) = self.block_on(self.vfs.stat(&id)) {
                out.push(FavoriteEntry {
                    entry: entry.into(),
                    added_ms,
                });
            }
        }
        Ok(out)
    }

    /// 最近打开列表（按打开时间倒序；已删除的路径自动跳过）。
    pub fn recent_files(&self, limit: u32) -> Result<Vec<RecentOpen>, SfError> {
        let index = self.require_index()?.clone();
        let rows = index.recent_opens(limit.min(50))?;
        let mut out = Vec::with_capacity(rows.len());
        for (id, opened_ms) in rows {
            if let Ok(entry) = self.block_on(self.vfs.stat(&id)) {
                out.push(RecentOpen {
                    entry: entry.into(),
                    opened_ms,
                });
            }
        }
        Ok(out)
    }

    /// Zip `sources` (files or directories, walked recursively) into
    /// `<dest_dir>/<name>` (`.zip` appended when missing; existing files are
    /// auto-renamed away with a `-N` suffix). Streams through a bounded
    /// channel so memory stays flat for big archives; `listener` receives
    /// `(done, total)` source-byte progress. Blocking call — invoke it off
    /// the UI thread.
    pub fn compress_zip(
        &self,
        sources: Vec<String>,
        dest_dir: String,
        name: String,
        method: ZipMethod,
        listener: std::sync::Arc<dyn ZipProgressListener>,
    ) -> Result<Entry, SfError> {
        let method = match method {
            ZipMethod::Store => sfiles_engine::ZipMethod::Store,
            ZipMethod::Deflate => sfiles_engine::ZipMethod::Deflate,
        };
        let progress = move |done: u64, total: u64| listener.on_progress(done, total);
        let entry = self.block_on(sfiles_engine::compress_zip(
            self.vfs.clone(),
            sources,
            dest_dir,
            name,
            method,
            runtime().handle().clone(),
            progress,
        ))?;
        Ok(entry.into())
    }

    /// Transfers a previous run didn't finish (crash / killed app), restored
    /// from the index. Ids already tracked by this process are excluded —
    /// those are live and show up in `transfers()` instead. Errors when no
    /// index was configured.
    pub fn pending_transfers(&self) -> Result<Vec<PendingTransfer>, SfError> {
        let index = self.require_index()?.clone();
        let live: Vec<String> = self.transfers.lock().unwrap().keys().cloned().collect();
        let rows = index.load_unfinished_transfers()?;
        Ok(rows
            .into_iter()
            .filter(|row| !live.contains(&row.id))
            .map(PendingTransfer::from)
            .collect())
    }

    /// Continue a transfer persisted by a previous run (see
    /// `pendingTransfers`). Sources and destination come from the stored
    /// record; the id is kept, so polling/cancelling work exactly like with
    /// a fresh `startCopy`.
    ///
    /// Resuming always uses the `Overwrite` conflict policy — for the file
    /// being copied mid-way that is precisely "continue at the recorded
    /// offset". The original policy isn't persisted, so anything else would
    /// be a guess; callers wanting a fresh copy should `forgetTransfer` and
    /// `startCopy` instead.
    pub fn resume_transfer(&self, id: String) -> Result<(), SfError> {
        let index = self.require_index()?.clone();
        let stored = index
            .load_unfinished_transfers()?
            .into_iter()
            .find(|row| row.id == id)
            .ok_or_else(|| SfError::NotFound {
                detail: format!("no resumable transfer {id}"),
            })?;
        let handle = Arc::new(TransferHandle::new(id.clone(), CancelToken::new()));
        {
            let mut registry = self.transfers.lock().unwrap();
            if registry.contains_key(&id) {
                return Err(SfError::AlreadyExists {
                    detail: format!("transfer {id} is already tracked"),
                });
            }
            registry.insert(id, handle.clone());
        }

        let vfs = self.vfs.clone();
        runtime().spawn(async move {
            sfiles_engine::run_resumable(
                vfs,
                stored.sources.clone(),
                stored.dest_dir.clone(),
                CopyOptions {
                    conflict: EngineConflict::Overwrite,
                    delete_sources: stored.is_move,
                    ..Default::default()
                },
                handle,
                index,
                Some(stored),
            )
            .await;
        });
        Ok(())
    }

    pub fn transfer_snapshot(&self, id: String) -> Option<TransferSnapshot> {
        self.transfers
            .lock()
            .unwrap()
            .get(&id)
            .map(|handle| handle.snapshot().into())
    }

    pub fn transfers(&self) -> Vec<TransferSnapshot> {
        self.transfers
            .lock()
            .unwrap()
            .values()
            .map(|handle| handle.snapshot().into())
            .collect()
    }

    pub fn cancel_transfer(&self, id: String) {
        if let Some(handle) = self.transfers.lock().unwrap().get(&id) {
            handle.cancel();
        }
    }

    /// Drop a finished transfer from the registry (UI dismissed it). Also
    /// deletes its persisted resume record, if any — this is how a pending
    /// transfer the user declined to resume goes away.
    pub fn forget_transfer(&self, id: String) {
        self.transfers.lock().unwrap().remove(&id);
        if let Some(index) = &self.index {
            let _ = index.forget_transfer(&id);
        }
    }

    // ---------------------------------------------------------------- index

    /// Walk a directory tree and write it into the metadata index.
    /// Returns the number of entries indexed.
    pub fn index_dir(&self, id: String) -> Result<u32, SfError> {
        let index = self.require_index()?.clone();
        let mut stack = vec![id];
        let mut count = 0u32;
        while let Some(dir) = stack.pop() {
            let entries = self.block_on(self.vfs.list(&dir))?;
            index.upsert_all(&entries)?;
            let _ = index.record_listing(&dir, now_ms() as i64);
            count += entries.len() as u32;
            for entry in entries {
                if entry.is_dir() {
                    stack.push(entry.id);
                }
            }
        }
        Ok(count)
    }

    /// Like [`index_dir`](Self::index_dir) but (a) reports progress on
    /// `listener`, (b) skips unreadable directories, and (c) is **incremental**:
    /// child directories whose mtime is unchanged since the last scan are not
    /// descended into (their whole subtree is already indexed), and freshly
    /// listed directories get reconciled (vanished entries are pruned from
    /// the index). Blocking call — run it off the UI thread; callbacks arrive
    /// on the calling thread.
    pub fn index_dir_with_progress(
        &self,
        id: String,
        listener: std::sync::Arc<dyn IndexProgressListener>,
    ) -> Result<u64, SfError> {
        let index = self.require_index()?.clone();

        // 入口目录 mtime 预检：没变化 = 整棵子树无增删 → 直接跳过（零 IO 开销）
        let root_mtime = self.block_on(self.vfs.stat(&id))?.modified_ms.unwrap_or(0);
        if index.dir_state_mtime(&id)?.is_some_and(|m| m == root_mtime) {
            listener.on_finished(0);
            return Ok(0);
        }

        let mut stack: Vec<(String, i64)> = vec![(id, root_mtime)];
        let mut processed: u64 = 0;
        let mut count: u64 = 0;
        let mut best: f32 = 0.0;
        while let Some((dir, dir_mtime)) = stack.pop() {
            let entries = match self.block_on(self.vfs.list(&dir)) {
                Ok(entries) => entries,
                Err(_) => continue, // 权限受限目录直接跳过，不中断整次扫描
            };
            index.upsert_all(&entries)?;
            // 删除对账：本目录下已消失的子项（含子树 + FTS 行）清出索引
            let keep: Vec<String> = entries.iter().map(|e| e.id.clone()).collect();
            index.prune_children(&dir, &keep)?;
            index.save_dir_state(&dir, dir_mtime)?;
            let _ = index.record_listing(&dir, now_ms() as i64);
            count += entries.len() as u64;
            for entry in entries {
                if !entry.is_dir() {
                    continue;
                }
                // 增量核心：子目录 mtime 未变 → 子树已在索引中，跳过深入
                let child_mtime = entry.modified_ms.unwrap_or(0);
                if index
                    .dir_state_mtime(&entry.id)?
                    .is_some_and(|m| m == child_mtime)
                {
                    continue;
                }
                stack.push((entry.id, child_mtime));
            }
            processed += 1;
            let pending = stack.len() as u64;
            let fraction = (processed as f32 / (processed + pending).max(1) as f32).min(0.99);
            best = best.max(fraction);
            listener.on_progress(processed, count, best);
        }
        listener.on_finished(count);
        Ok(count)
    }

    /// Indexed search. Errors when no index path was configured.
    pub fn search(&self, query: String, limit: u32) -> Result<Vec<Entry>, SfError> {
        // 刚进过的目录可能还在写队列里：搜索前 flush，保证刚看到的文件可被搜到
        if let Some(writer) = &self.index_writer {
            writer.flush();
        }
        let index = self.require_index()?;
        let entries = index.search(&query, limit)?;
        Ok(entries.into_iter().map(Entry::from).collect())
    }

    pub fn index_count(&self) -> u64 {
        if let Some(writer) = &self.index_writer {
            writer.flush();
        }
        self.index
            .as_ref()
            .and_then(|index| index.count().ok())
            .unwrap_or(0)
    }

    pub fn clear_index(&self) -> Result<(), SfError> {
        if let Some(writer) = &self.index_writer {
            writer.flush();
        }
        let index = self.require_index()?;
        Ok(index.clear()?)
    }
}

impl Drop for SuperFiles {
    /// 真正的资源释放转移到 tokio runtime 上下文里执行：
    /// 1. smb/webdav backend 的 Drop 需要 runtime（析构里 tokio::spawn，离开
    ///    runtime 即 panic；panic 跨 FFI/UniFFI Cleaner 线程 = 整个 App SIGABRT，
    ///    2026-11 真机 tombstone 实证）；
    /// 2. GC 线程（ART Cleaner/InnocuousThread）没有 runtime 上下文，直接释放
    ///    vfs/stream/share 就是踩这条线；
    /// 3. 残余任何 panic 被隔离在 runtime 任务内，绝不蔓延到 GC 线程。
    fn drop(&mut self) {
        // 停写线程并排空队列，避免丢最后一批列举缓存
        if let Some(writer) = &self.index_writer {
            let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| writer.shutdown()));
        }
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let vfs = self.vfs.clone();
            let index = self.index.clone();
            let streamer = self.streamer.lock().map(|mut s| s.take()).unwrap_or(None);
            let share = self.share.lock().map(|mut s| s.take()).unwrap_or(None);
            let transfers: Vec<Arc<TransferHandle>> =
                self.transfers.lock().map(|mut t| t.drain().map(|(_, v)| v).collect()).unwrap_or_default();
            runtime().spawn(async move {
                // 这些 Arc 的最后一次释放可能落在此任务内：有 runtime，安全。
                drop(transfers);
                drop(streamer);
                drop(share);
                drop(index);
                drop(vfs);
            });
        }));
    }
}

impl SuperFiles {
    fn block_on<F: Future>(&self, future: F) -> F::Output {
        runtime().block_on(future)
    }

    /// 在 tokio 上下文中执行同步代码：网络 backend（smb/webdav）的 Drop 可能
    /// 调用 tokio::spawn/spawn_blocking，必须在 runtime 上下文里释放，否则
    /// panic（双重 panic 会直接 SIGABRT 整个 App）。
    fn in_runtime<T>(&self, f: impl FnOnce() -> T) -> T {
        runtime().block_on(async move { f() })
    }

    fn require_index(&self) -> Result<Arc<Index>, SfError> {
        self.index.clone().ok_or_else(|| SfError::Unsupported {
            detail: "index is not configured; reopen with an index path".into(),
        })
    }

    fn stream_server(&self) -> Result<Arc<sfiles_stream::StreamServer>, SfError> {
        let mut slot = self.streamer.lock().unwrap();
        if slot.is_none() {
            let server = runtime()
                .block_on(sfiles_stream::StreamServer::start(self.vfs.clone()))
                .map_err(|err| SfError::Io {
                    detail: format!("stream server: {err}"),
                })?;
            *slot = Some(Arc::new(server));
        }
        Ok(slot.as_ref().unwrap().clone())
    }
}
