use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Component, Path, PathBuf};

use async_trait::async_trait;
use tokio::task;

use crate::backend::Backend;
use crate::cancel::CancelToken;
use crate::capabilities::Capabilities;
use crate::entry::{guess_mime, mtime_ms, Entry, EntryKind};
use crate::error::{Result, VfsError};
use crate::fd;
use crate::uri::{split_id, LOCAL_SCHEME};
use crate::DEFAULT_CHUNK_SIZE;

/// Local filesystem backend, jailed to a root directory.
///
/// The jail matters: on iOS the app can only see its container, on Android we
/// point the root at either app storage or a SAF-mounted tree, and on desktop we
/// still want `..` traversal to be rejected so a crafted deep link cannot escape
/// the configured volume.
pub struct LocalBackend {
    root: PathBuf,
}

impl LocalBackend {
    pub fn new(root: impl AsRef<Path>) -> Result<Self> {
        let root = root.as_ref();
        std::fs::create_dir_all(root).map_err(|e| VfsError::io_at(root, e))?;
        let root = std::fs::canonicalize(root).map_err(|e| VfsError::io_at(root, e))?;
        Ok(Self { root })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Canonical id of the backend root. This is what the UI opens by default.
    pub fn root_id(&self) -> String {
        self.root.to_string_lossy().into_owned()
    }

    fn resolve(&self, id: &str) -> Result<PathBuf> {
        let (scheme, rest) = split_id(id);
        if scheme != LOCAL_SCHEME {
            return Err(VfsError::Unsupported(format!(
                "local backend cannot handle {id}"
            )));
        }
        let rest = rest.trim();
        let joined = if rest.is_empty() || rest == "/" || rest == "." {
            self.root.clone()
        } else {
            let candidate = Path::new(rest);
            if candidate.is_absolute() {
                candidate.to_path_buf()
            } else {
                self.root.join(candidate)
            }
        };
        let normalized = normalize(&joined);
        if !normalized.starts_with(&self.root) {
            return Err(VfsError::PermissionDenied(format!(
                "path escapes local root: {}",
                normalized.display()
            )));
        }
        Ok(normalized)
    }
}

/// Lexically normalize a path (no filesystem access, so it works for paths that
/// do not exist yet, which is exactly what `create_file` needs).
fn normalize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::ParentDir => {
                out.pop();
            }
            Component::CurDir => {}
            other => out.push(other.as_os_str()),
        }
    }
    out
}

fn validate_name(name: &str) -> Result<()> {
    let invalid = name.is_empty()
        || name == "."
        || name == ".."
        || name.contains('/')
        || name.contains('\\')
        || name.contains('\0');
    if invalid {
        return Err(VfsError::InvalidName(name.to_string()));
    }
    Ok(())
}

fn entry_of(path: &Path, meta: &std::fs::Metadata) -> Entry {
    let file_type = meta.file_type();
    let kind = if file_type.is_symlink() {
        EntryKind::Symlink
    } else if file_type.is_dir() {
        EntryKind::Directory
    } else if file_type.is_file() {
        EntryKind::File
    } else {
        EntryKind::Special
    };
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| path.to_string_lossy().into_owned());
    let mime = if kind == EntryKind::File {
        guess_mime(&name)
    } else {
        None
    };
    Entry {
        id: path.to_string_lossy().into_owned(),
        parent: path.parent().map(|p| p.to_string_lossy().into_owned()),
        name: name.clone(),
        kind,
        size: if kind == EntryKind::Directory {
            0
        } else {
            meta.len()
        },
        modified_ms: mtime_ms(meta.modified().ok()),
        mime,
        hidden: name.starts_with('.'),
        readonly: meta.permissions().readonly(),
    }
}

#[async_trait]
impl Backend for LocalBackend {
    fn scheme(&self) -> &'static str {
        LOCAL_SCHEME
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities::READ_WRITE
    }

    async fn stat(&self, id: &str) -> Result<Entry> {
        let path = self.resolve(id)?;
        task::spawn_blocking(move || {
            let meta = std::fs::symlink_metadata(&path).map_err(|e| VfsError::io_at(&path, e))?;
            Ok(entry_of(&path, &meta))
        })
        .await
        .map_err(join_error)?
    }

    async fn list(&self, id: &str) -> Result<Vec<Entry>> {
        let path = self.resolve(id)?;
        task::spawn_blocking(move || {
            let mut entries = Vec::new();
            let dir = std::fs::read_dir(&path).map_err(|e| VfsError::io_at(&path, e))?;
            for item in dir {
                let item = item.map_err(|e| VfsError::io_at(&path, e))?;
                let child = item.path();
                match std::fs::symlink_metadata(&child) {
                    Ok(meta) => entries.push(entry_of(&child, &meta)),
                    // A file deleted between readdir and stat is not an error.
                    Err(_) => continue,
                }
            }
            entries.sort_by(|a, b| {
                let a_dir = a.kind == EntryKind::Directory;
                let b_dir = b.kind == EntryKind::Directory;
                b_dir
                    .cmp(&a_dir)
                    .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
            });
            Ok(entries)
        })
        .await
        .map_err(join_error)?
    }

    async fn create_dir(&self, parent: &str, name: &str) -> Result<Entry> {
        validate_name(name)?;
        let parent = self.resolve(parent)?;
        let target = parent.join(name);
        task::spawn_blocking(move || {
            std::fs::create_dir(&target).map_err(|e| VfsError::io_at(&target, e))?;
            let meta =
                std::fs::symlink_metadata(&target).map_err(|e| VfsError::io_at(&target, e))?;
            Ok(entry_of(&target, &meta))
        })
        .await
        .map_err(join_error)?
    }

    async fn create_file(&self, parent: &str, name: &str) -> Result<Entry> {
        validate_name(name)?;
        let parent = self.resolve(parent)?;
        let target = parent.join(name);
        task::spawn_blocking(move || {
            std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&target)
                .map_err(|e| VfsError::io_at(&target, e))?;
            let meta =
                std::fs::symlink_metadata(&target).map_err(|e| VfsError::io_at(&target, e))?;
            Ok(entry_of(&target, &meta))
        })
        .await
        .map_err(join_error)?
    }

    async fn remove(&self, id: &str, recursive: bool) -> Result<()> {
        let path = self.resolve(id)?;
        task::spawn_blocking(move || {
            let meta = std::fs::symlink_metadata(&path).map_err(|e| VfsError::io_at(&path, e))?;
            if meta.is_dir() {
                if recursive {
                    std::fs::remove_dir_all(&path).map_err(|e| VfsError::io_at(&path, e))
                } else {
                    std::fs::remove_dir(&path).map_err(|e| VfsError::io_at(&path, e))
                }
            } else {
                std::fs::remove_file(&path).map_err(|e| VfsError::io_at(&path, e))
            }
        })
        .await
        .map_err(join_error)?
    }

    async fn rename(&self, id: &str, new_name: &str) -> Result<Entry> {
        validate_name(new_name)?;
        let source = self.resolve(id)?;
        let parent = source
            .parent()
            .ok_or_else(|| VfsError::PermissionDenied("cannot rename backend root".into()))?
            .to_path_buf();
        let target = parent.join(new_name);
        task::spawn_blocking(move || {
            std::fs::rename(&source, &target).map_err(|e| VfsError::io_at(&source, e))?;
            let meta =
                std::fs::symlink_metadata(&target).map_err(|e| VfsError::io_at(&target, e))?;
            Ok(entry_of(&target, &meta))
        })
        .await
        .map_err(join_error)?
    }

    async fn read_range(&self, id: &str, offset: u64, len: usize) -> Result<Vec<u8>> {
        let path = self.resolve(id)?;
        task::spawn_blocking(move || {
            let mut file = std::fs::File::open(&path).map_err(|e| VfsError::io_at(&path, e))?;
            file.seek(SeekFrom::Start(offset))
                .map_err(|e| VfsError::io_at(&path, e))?;
            let mut buf = vec![0u8; len];
            let mut filled = 0usize;
            while filled < len {
                let n = file
                    .read(&mut buf[filled..])
                    .map_err(|e| VfsError::io_at(&path, e))?;
                if n == 0 {
                    break;
                }
                filled += n;
            }
            buf.truncate(filled);
            Ok(buf)
        })
        .await
        .map_err(join_error)?
    }

    async fn write_range(&self, id: &str, offset: u64, data: &[u8]) -> Result<()> {
        let path = self.resolve(id)?;
        let data = data.to_vec();
        task::spawn_blocking(move || {
            let mut file = std::fs::OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(false)
                .open(&path)
                .map_err(|e| VfsError::io_at(&path, e))?;
            file.seek(SeekFrom::Start(offset))
                .map_err(|e| VfsError::io_at(&path, e))?;
            file.write_all(&data).map_err(|e| VfsError::io_at(&path, e))
        })
        .await
        .map_err(join_error)?
    }

    async fn truncate(&self, id: &str, size: u64) -> Result<()> {
        let path = self.resolve(id)?;
        task::spawn_blocking(move || {
            let file = std::fs::OpenOptions::new()
                .write(true)
                .open(&path)
                .map_err(|e| VfsError::io_at(&path, e))?;
            file.set_len(size).map_err(|e| VfsError::io_at(&path, e))
        })
        .await
        .map_err(join_error)?
    }

    async fn read_to_fd(
        &self,
        id: &str,
        fd: i32,
        offset: u64,
        cancel: &CancelToken,
    ) -> Result<u64> {
        let path = self.resolve(id)?;
        let cancel = cancel.clone();
        task::spawn_blocking(move || {
            let mut file = std::fs::File::open(&path).map_err(|e| VfsError::io_at(&path, e))?;
            file.seek(SeekFrom::Start(offset))
                .map_err(|e| VfsError::io_at(&path, e))?;
            let mut buf = vec![0u8; DEFAULT_CHUNK_SIZE];
            let mut total = 0u64;
            loop {
                if cancel.is_cancelled() {
                    return Err(VfsError::Cancelled);
                }
                let n = file.read(&mut buf).map_err(|e| VfsError::io_at(&path, e))?;
                if n == 0 {
                    break;
                }
                fd::write_all(fd, &buf[..n]).map_err(VfsError::io)?;
                total += n as u64;
            }
            Ok(total)
        })
        .await
        .map_err(join_error)?
    }

    async fn write_from_fd(
        &self,
        id: &str,
        fd: i32,
        offset: u64,
        cancel: &CancelToken,
    ) -> Result<u64> {
        let path = self.resolve(id)?;
        let cancel = cancel.clone();
        task::spawn_blocking(move || {
            let mut file = std::fs::OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(false)
                .open(&path)
                .map_err(|e| VfsError::io_at(&path, e))?;
            file.seek(SeekFrom::Start(offset))
                .map_err(|e| VfsError::io_at(&path, e))?;
            let mut buf = vec![0u8; DEFAULT_CHUNK_SIZE];
            let mut total = 0u64;
            loop {
                if cancel.is_cancelled() {
                    return Err(VfsError::Cancelled);
                }
                let n = fd::read_some(fd, &mut buf).map_err(VfsError::io)?;
                if n == 0 {
                    break;
                }
                file.write_all(&buf[..n])
                    .map_err(|e| VfsError::io_at(&path, e))?;
                total += n as u64;
            }
            Ok(total)
        })
        .await
        .map_err(join_error)?
    }
}

fn join_error(err: task::JoinError) -> VfsError {
    VfsError::Io(format!("blocking task failed: {err}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_root(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "sfiles-test-{tag}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        dir
    }

    #[tokio::test]
    async fn list_create_write_read_roundtrip() {
        let root = temp_root("roundtrip");
        let backend = LocalBackend::new(&root).unwrap();
        let root_id = backend.root_id();

        let dir = backend.create_dir(&root_id, "docs").await.unwrap();
        assert_eq!(dir.kind, EntryKind::Directory);

        let file = backend.create_file(&dir.id, "a.txt").await.unwrap();
        backend
            .write_range(&file.id, 0, b"hello world")
            .await
            .unwrap();

        let mut got = backend.read_range(&file.id, 6, 5).await.unwrap();
        assert_eq!(got, b"world");
        got = backend.read_range(&file.id, 0, 5).await.unwrap();
        assert_eq!(got, b"hello");

        let listed = backend.list(&dir.id).await.unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].name, "a.txt");
        assert_eq!(listed[0].size, 11);
        assert_eq!(listed[0].mime.as_deref(), Some("text/plain"));

        backend.truncate(&file.id, 5).await.unwrap();
        let stat = backend.stat(&file.id).await.unwrap();
        assert_eq!(stat.size, 5);

        let renamed = backend.rename(&file.id, "b.txt").await.unwrap();
        assert_eq!(renamed.name, "b.txt");

        backend.remove(&dir.id, true).await.unwrap();
        assert!(backend.stat(&dir.id).await.is_err());

        std::fs::remove_dir_all(&root).ok();
    }

    #[tokio::test]
    async fn jail_rejects_escape() {
        let root = temp_root("jail");
        let backend = LocalBackend::new(&root).unwrap();
        let err = backend.list("/etc").await.unwrap_err();
        assert!(matches!(err, VfsError::PermissionDenied(_)));
        let err = backend
            .list(&format!("{}/../../etc", backend.root_id()))
            .await
            .unwrap_err();
        assert!(matches!(err, VfsError::PermissionDenied(_)));
        std::fs::remove_dir_all(&root).ok();
    }

    #[tokio::test]
    async fn rejects_separators_in_names() {
        let root = temp_root("names");
        let backend = LocalBackend::new(&root).unwrap();
        let err = backend
            .create_dir(&backend.root_id(), "../evil")
            .await
            .unwrap_err();
        assert!(matches!(err, VfsError::InvalidName(_)));
        std::fs::remove_dir_all(&root).ok();
    }
}
