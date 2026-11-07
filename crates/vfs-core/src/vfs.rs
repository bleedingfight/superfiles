use std::collections::HashMap;
use std::sync::{Arc, RwLock};

use crate::backend::Backend;
use crate::backends::LocalBackend;
use crate::capabilities::Capabilities;
use crate::entry::Entry;
use crate::error::{Result, VfsError};
use crate::uri::{self, split_id, LOCAL_SCHEME};

/// Mount table + facade over all backends.
///
/// UI code never sees a backend: it passes an entry id and the `Vfs` dispatches
/// on the URI scheme. Adding SMB later means mounting one more backend, not
/// touching Swift or Kotlin.
pub struct Vfs {
    backends: RwLock<HashMap<String, Arc<dyn Backend>>>,
    local_root: String,
}

impl Default for Vfs {
    fn default() -> Self {
        Self::new()
    }
}

impl Vfs {
    pub fn new() -> Self {
        Self {
            backends: RwLock::new(HashMap::new()),
            local_root: String::new(),
        }
    }

    /// Create a VFS with a single jailed local backend.
    pub fn with_local_root(root: impl AsRef<std::path::Path>) -> Result<Self> {
        let backend = LocalBackend::new(root)?;
        let root_id = backend.root_id();
        let vfs = Self::new();
        vfs.mount(Arc::new(backend));
        let mut this = vfs;
        this.local_root = root_id;
        Ok(this)
    }

    pub fn mount(&self, backend: Arc<dyn Backend>) {
        let scheme = backend.scheme().to_string();
        self.backends.write().unwrap().insert(scheme, backend);
    }

    pub fn local_root(&self) -> &str {
        &self.local_root
    }

    pub fn mounted_schemes(&self) -> Vec<String> {
        let mut schemes: Vec<String> = self.backends.read().unwrap().keys().cloned().collect();
        schemes.sort();
        schemes
    }

    /// Resolve the backend responsible for an id (used by the FFI layer for
    /// descriptor bridging, where the backend object itself is needed).
    pub fn backend_for(&self, id: &str) -> Result<Arc<dyn Backend>> {
        let (scheme, _) = split_id(id);
        self.backends
            .read()
            .unwrap()
            .get(scheme)
            .cloned()
            .ok_or_else(|| {
                VfsError::Unsupported(format!("no backend mounted for scheme '{scheme}'"))
            })
    }

    pub fn capabilities(&self, id: &str) -> Result<Capabilities> {
        Ok(self.backend_for(id)?.capabilities())
    }

    pub async fn stat(&self, id: &str) -> Result<Entry> {
        self.backend_for(id)?.stat(id).await
    }

    pub async fn list(&self, id: &str) -> Result<Vec<Entry>> {
        self.backend_for(id)?.list(id).await
    }

    pub async fn create_dir(&self, parent: &str, name: &str) -> Result<Entry> {
        self.backend_for(parent)?.create_dir(parent, name).await
    }

    pub async fn create_file(&self, parent: &str, name: &str) -> Result<Entry> {
        self.backend_for(parent)?.create_file(parent, name).await
    }

    pub async fn remove(&self, id: &str, recursive: bool) -> Result<()> {
        self.backend_for(id)?.remove(id, recursive).await
    }

    pub async fn rename(&self, id: &str, new_name: &str) -> Result<Entry> {
        self.backend_for(id)?.rename(id, new_name).await
    }

    pub async fn read_range(&self, id: &str, offset: u64, len: usize) -> Result<Vec<u8>> {
        self.backend_for(id)?.read_range(id, offset, len).await
    }

    pub async fn write_range(&self, id: &str, offset: u64, data: &[u8]) -> Result<()> {
        self.backend_for(id)?.write_range(id, offset, data).await
    }

    pub async fn truncate(&self, id: &str, size: u64) -> Result<()> {
        self.backend_for(id)?.truncate(id, size).await
    }

    /// Stream a backend file into a caller owned fd.
    pub async fn read_to_fd(
        &self,
        id: &str,
        fd: i32,
        offset: u64,
        cancel: &crate::cancel::CancelToken,
    ) -> Result<u64> {
        self.backend_for(id)?
            .read_to_fd(id, fd, offset, cancel)
            .await
    }

    /// Stream a caller owned fd into a backend file.
    pub async fn write_from_fd(
        &self,
        id: &str,
        fd: i32,
        offset: u64,
        cancel: &crate::cancel::CancelToken,
    ) -> Result<u64> {
        self.backend_for(id)?
            .write_from_fd(id, fd, offset, cancel)
            .await
    }

    /// Join a child name onto a parent id (scheme preserving).
    pub fn join(parent: &str, name: &str) -> String {
        uri::join(parent, name)
    }

    /// True when both ids live on the same backend (cheap rename possible).
    pub fn same_backend(&self, a: &str, b: &str) -> bool {
        split_id(a).0 == split_id(b).0
    }

    /// Text used by UI when the id is a local path.
    pub fn display_path(id: &str) -> String {
        let (scheme, rest) = split_id(id);
        if scheme == LOCAL_SCHEME {
            rest.to_string()
        } else {
            id.to_string()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn dispatches_local_ids() {
        let root = std::env::temp_dir().join(format!(
            "sfiles-vfs-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let vfs = Vfs::with_local_root(&root).unwrap();
        let root_id = vfs.local_root().to_string();
        assert!(vfs.capabilities(&root_id).unwrap().can_write);

        let dir = vfs.create_dir(&root_id, "media").await.unwrap();
        let child = Vfs::join(&dir.id, "x.bin");
        vfs.write_range(&child, 0, &[1, 2, 3]).await.unwrap();
        assert_eq!(vfs.read_range(&child, 1, 2).await.unwrap(), vec![2, 3]);

        let err = vfs.list("smb://nas/share").await.unwrap_err();
        assert!(matches!(err, VfsError::Unsupported(_)));

        std::fs::remove_dir_all(&root).ok();
    }
}
