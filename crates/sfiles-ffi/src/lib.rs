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
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

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
// Runtime
// ---------------------------------------------------------------------------

fn runtime() -> &'static Runtime {
    static RT: OnceLock<Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("sfiles-core")
            .enable_all()
            .build()
            .expect("failed to start Super Files runtime")
    })
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
    transfers: Mutex<HashMap<String, Arc<TransferHandle>>>,
    counter: AtomicU64,
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
        let root_id = vfs.local_root().to_string();
        Ok(Arc::new(Self {
            vfs,
            root_id,
            index,
            transfers: Mutex::new(HashMap::new()),
            counter: AtomicU64::new(1),
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
        Ok(entries.into_iter().map(Entry::from).collect())
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

    // -------------------------------------------------------------- transfers

    /// Start a background copy. Returns a transfer id for polling/cancelling.
    pub fn start_copy(
        &self,
        sources: Vec<String>,
        dest_dir: String,
        conflict: ConflictPolicy,
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
            ..Default::default()
        };
        runtime().spawn(async move {
            sfiles_engine::run(vfs, sources, dest_dir, opts, handle).await;
        });
        Ok(id)
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

    /// Drop a finished transfer from the registry (UI dismissed it).
    pub fn forget_transfer(&self, id: String) {
        self.transfers.lock().unwrap().remove(&id);
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
            count += entries.len() as u32;
            for entry in entries {
                if entry.is_dir() {
                    stack.push(entry.id);
                }
            }
        }
        Ok(count)
    }

    /// Indexed search. Errors when no index path was configured.
    pub fn search(&self, query: String, limit: u32) -> Result<Vec<Entry>, SfError> {
        let index = self.require_index()?;
        let entries = index.search(&query, limit)?;
        Ok(entries.into_iter().map(Entry::from).collect())
    }

    pub fn index_count(&self) -> u64 {
        self.index
            .as_ref()
            .and_then(|index| index.count().ok())
            .unwrap_or(0)
    }

    pub fn clear_index(&self) -> Result<(), SfError> {
        let index = self.require_index()?;
        Ok(index.clear()?)
    }
}

impl SuperFiles {
    fn block_on<F: Future>(&self, future: F) -> F::Output {
        runtime().block_on(future)
    }

    fn require_index(&self) -> Result<Arc<Index>, SfError> {
        self.index.clone().ok_or_else(|| SfError::Unsupported {
            detail: "index is not configured; reopen with an index path".into(),
        })
    }
}
