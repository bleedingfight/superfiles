//! SMB 2/3 backend, built on the pure-Rust [`smb`] crate (afiffon/smb-rs).
//!
//! Unlike WebDAV, the protocol has native random reads, random writes and
//! SET_END_OF_FILE, so the POSIX-shaped `Backend` contract maps 1:1 and
//! `can_random_write` is genuinely true (nice for resumable transfers).
//!
//! Cost model note: each operation opens a fresh handle (CREATE/CLOSE round
//! trip, ~1 ms on LAN) instead of caching per-entry handles, which keeps the
//! backend stateless per the contract and safe under concurrent transfers.
//! Handle reuse/pooling is an explicit future optimization.

use std::sync::Arc;

use async_trait::async_trait;
use futures_util::StreamExt;

use smb::resource::SetLen;
use smb::{
    Client, ClientConfig, CreateDisposition, CreateOptions, FileAccessMask, FileAllInformation,
    FileAttributes, FileCreateArgs, FileDispositionInformation, FileIdBothDirectoryInformation,
    FileRenameInformation, ReadAt, Resource, ResourceHandle, Status, UncPath, WriteAt,
};

/// `Resource` (enum) derefs nowhere; borrow the common handle per variant.
fn handle_of(res: &Resource) -> &ResourceHandle {
    match res {
        Resource::File(f) => f.handle(),
        Resource::Directory(d) => d.handle(),
        Resource::Pipe(p) => p.handle(),
    }
}

use crate::backend::Backend;
use crate::capabilities::Capabilities;
use crate::entry::{guess_mime, mtime_ms, Entry, EntryKind};
use crate::error::{Result, VfsError};
use crate::uri::split_id;

pub const SCHEME: &str = "smb";

/// Credentials. Kerberos (and with it sspi clients) are an M2+ concern; NTLMv2
/// username/password is the baseline that Synology/QNAP/Windows/Samba all do.
#[derive(Debug, Clone)]
pub struct SmbAuth {
    pub username: String,
    pub password: String,
}

impl SmbAuth {
    pub fn new(username: impl Into<String>, password: impl Into<String>) -> Self {
        Self {
            username: username.into(),
            password: password.into(),
        }
    }

    /// Anonymous share login; honored only when the server maps guests
    /// (e.g. Samba `map to guest = Bad User`).
    pub fn guest() -> Self {
        Self::new("guest", "")
    }
}

/// A single mounted share (`smb://<host>/<share>/...`).
pub struct SmbBackend {
    client: Arc<Client>,
    host: String,
    share: String,
    auth: SmbAuth,
}

impl SmbBackend {
    /// Connect eagerly so bad credentials/hosts fail at mount time, not on
    /// the first browse click.
    pub async fn connect(host: &str, share: &str, auth: SmbAuth) -> Result<Self> {
        let backend = Self {
            client: Arc::new(Client::new(ClientConfig::default())),
            host: host.trim_matches(['/', '\\']).to_string(),
            share: share.trim_matches(['/', '\\']).to_string(),
            auth,
        };
        backend.share_connect().await?;
        Ok(backend)
    }

    async fn share_connect(&self) -> Result<()> {
        let target = self.root_unc()?;
        self.client
            .share_connect(&target, &self.auth.username, self.auth.password.clone())
            .await
            .map_err(map_err)
    }

    /// Canonical id of the share root.
    pub fn root_id(&self) -> String {
        format!("{SCHEME}://{}/{}", self.host, self.share)
    }

    fn root_unc(&self) -> Result<UncPath> {
        format!(r"\\{}\{}", self.host, self.share)
            .parse()
            .map_err(|e| VfsError::Unsupported(format!("bad smb unc path: {e}")))
    }

    /// Entry id -> `\\host\share\rel\path` (empty rel = share root).
    fn resolve_unc(&self, id: &str) -> Result<UncPath> {
        let rel = self.resolve_rel(id)?;
        let root = self.root_unc()?;
        Ok(if rel.is_empty() {
            root
        } else {
            root.with_path(&rel)
        })
    }

    /// Entry id -> share-relative path joined with `\` ("" for the share root).
    fn resolve_rel(&self, id: &str) -> Result<String> {
        let (scheme, rest) = split_id(id);
        if scheme != SCHEME {
            return Err(VfsError::Unsupported(format!(
                "smb backend cannot handle {id}"
            )));
        }
        let mut segments = rest.split(['/', '\\']).filter(|s| !s.is_empty());
        let host = segments.next().unwrap_or_default();
        if !host.eq_ignore_ascii_case(&self.host) {
            return Err(VfsError::Unsupported(format!(
                "id belongs to another smb host: {id}"
            )));
        }
        let share = segments
            .next()
            .ok_or_else(|| VfsError::Unsupported(format!("smb id misses share: {id}")))?;
        if !share.eq_ignore_ascii_case(&self.share) {
            return Err(VfsError::Unsupported(format!(
                "id belongs to another smb share: {id}"
            )));
        }
        // Same lexical jail as local: `..` must not pop above the share root.
        let mut kept: Vec<&str> = Vec::new();
        for seg in segments {
            match seg {
                "." => {}
                ".." if kept.pop().is_none() => {
                    return Err(VfsError::PermissionDenied(format!(
                        "path escapes share root: {id}"
                    )))
                }
                ".." => {}
                other => kept.push(other),
            }
        }
        Ok(kept.join("\\"))
    }

    /// Open an existing object; the resulting [Resource] knows its own kind.
    async fn open(&self, id: &str, access: FileAccessMask) -> Result<Resource> {
        let unc = self.resolve_unc(id)?;
        self.client
            .create_file(&unc, &FileCreateArgs::make_open_existing(access))
            .await
            .map_err(map_err)
    }

    /// Retry transport-class failures with bounded backoff (contract §4);
    /// protocol errors (status codes) are never retried.
    async fn retry<T, F, Fut>(&self, mut op: F) -> Result<T>
    where
        F: FnMut() -> Fut,
        Fut: std::future::Future<Output = Result<T>>,
    {
        const MAX_ATTEMPTS: u32 = 3;
        let mut delay = std::time::Duration::from_millis(200);
        let mut attempt = 0u32;
        loop {
            match op().await {
                Err(err) if is_transport(&err) && attempt + 1 < MAX_ATTEMPTS => {
                    // A stopped connection is re-established before the retry,
                    // mirroring how the WebDAV backend re-sends its request.
                    if matches!(err, VfsError::Network(_)) {
                        let _ = self.share_connect().await;
                    }
                    tokio::time::sleep(delay).await;
                    delay *= 4;
                    attempt += 1;
                }
                other => return other,
            }
        }
    }

    fn entry_of_child(&self, parent_id: &str, info: &FileIdBothDirectoryInformation) -> Entry {
        let name = info.file_name.to_string();
        let kind = if info.file_attributes.directory() {
            EntryKind::Directory
        } else {
            EntryKind::File
        };
        let id = crate::uri::join(parent_id, &name);
        Entry {
            id,
            parent: Some(parent_id.to_string()),
            name: name.clone(),
            kind,
            size: if kind == EntryKind::Directory {
                0
            } else {
                info.end_of_file
            },
            modified_ms: mtime_ms(Some(info.last_write_time.into())),
            mime: (kind == EntryKind::File)
                .then(|| guess_mime(&name))
                .flatten(),
            hidden: info.file_attributes.hidden() || name.starts_with('.'),
            readonly: info.file_attributes.readonly(),
        }
    }
}

#[async_trait]
impl Backend for SmbBackend {
    fn scheme(&self) -> &'static str {
        SCHEME
    }

    fn display_name(&self) -> String {
        format!("smb ({}/{})", self.host, self.share)
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities {
            can_watch: false, // Directory::watch exists in the crate; VFS has no watch API yet.
            ..Capabilities::READ_WRITE
        }
    }

    async fn stat(&self, id: &str) -> Result<Entry> {
        self.retry(|| async {
            let res = self.open(id, read_access()).await?;
            let info: FileAllInformation = handle_of(&res).query_info().await.map_err(map_err)?;
            handle_of(&res).close().await.map_err(map_err)?;

            let name = if id == self.root_id() {
                self.share.clone()
            } else {
                id.rsplit(['/', '\\'])
                    .find(|s| !s.is_empty())
                    .unwrap_or_default()
                    .to_string()
            };
            let kind = if info.basic.file_attributes.directory() {
                EntryKind::Directory
            } else {
                EntryKind::File
            };
            Ok(Entry {
                id: id.to_string(),
                parent: crate::uri::parent_of(id).or(Some(self.root_id())),
                name: name.clone(),
                kind,
                size: if kind == EntryKind::Directory {
                    0
                } else {
                    info.standard.end_of_file
                },
                modified_ms: mtime_ms(Some(info.basic.last_write_time.into())),
                mime: (kind == EntryKind::File)
                    .then(|| guess_mime(&name))
                    .flatten(),
                hidden: info.basic.file_attributes.hidden() || name.starts_with('.'),
                readonly: info.basic.file_attributes.readonly(),
            })
        })
        .await
    }

    async fn list(&self, id: &str) -> Result<Vec<Entry>> {
        self.retry(|| async {
            let res = self.open(id, read_access()).await?;
            if !res.is_dir() {
                handle_of(&res).close().await.ok();
                return Err(VfsError::Io(format!("not a directory: {id}")));
            }
            let dir = Arc::new(res.unwrap_dir());
            let mut stream = smb::Directory::query::<FileIdBothDirectoryInformation>(&dir, "*")
                .await
                .map_err(map_err)?;
            let mut entries = Vec::new();
            while let Some(item) = stream.next().await {
                match item {
                    Ok(info) => {
                        let entry = self.entry_of_child(id, &info);
                        // Some servers echo "." / ".." in the enumeration.
                        if entry.name != "." && entry.name != ".." {
                            entries.push(entry);
                        }
                    }
                    Err(_) => continue, // single bad item must not fail the listing
                }
            }
            drop(stream);
            dir.handle().close().await.map_err(map_err)?;
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
    }

    async fn create_dir(&self, parent: &str, name: &str) -> Result<Entry> {
        validate_name(name)?;
        let child_id = crate::uri::join(parent, name);
        self.retry(|| async {
            let unc = self.resolve_unc(&child_id)?;
            let args = FileCreateArgs {
                disposition: CreateDisposition::Create,
                attributes: FileAttributes::new().with_directory(true),
                options: CreateOptions::new().with_directory_file(true),
                desired_access: FileAccessMask::new().with_generic_all(true),
            };
            let res = self
                .client
                .create_file(&unc, &args)
                .await
                .map_err(map_err)?;
            handle_of(&res).close().await.map_err(map_err)?;
            self.stat(&child_id).await
        })
        .await
    }

    async fn create_file(&self, parent: &str, name: &str) -> Result<Entry> {
        validate_name(name)?;
        let child_id = crate::uri::join(parent, name);
        self.retry(|| async {
            let unc = self.resolve_unc(&child_id)?;
            let res = self
                .client
                .create_file(
                    &unc,
                    &FileCreateArgs::make_create_new(
                        FileAttributes::new(),
                        CreateOptions::new().with_non_directory_file(true),
                    ),
                )
                .await
                .map_err(map_err)?;
            handle_of(&res).close().await.map_err(map_err)?;
            self.stat(&child_id).await
        })
        .await
    }

    async fn remove(&self, id: &str, recursive: bool) -> Result<()> {
        // Not retried end-to-end: after a stuck-but-successful delete the
        // retry would land on NotFound and report a false failure.
        let entry = self.stat(id).await?;
        if entry.is_dir() && recursive {
            for child in self.list(id).await? {
                Box::pin(self.remove(&child.id, true)).await?;
            }
        }
        self.delete_leaf(&entry).await
    }

    async fn rename(&self, id: &str, new_name: &str) -> Result<Entry> {
        validate_name(new_name)?;
        // MS-FSCC 2.4.34.2: with root_directory = 0 the FileName is the full
        // share-relative path, NOT a basename. Same-parent only (contract §2:
        // cross-directory moves are the engine's job).
        let src_rel = self.resolve_rel(id)?;
        let new_rel = match src_rel.rfind('\\') {
            Some(idx) => format!("{}\\{new_name}", &src_rel[..idx]),
            None => new_name.to_string(),
        };
        let res = self.open(id, write_access()).await?;
        handle_of(&res)
            .set_info(FileRenameInformation {
                replace_if_exists: true.into(),
                root_directory: 0,
                file_name: new_rel.as_str().into(),
            })
            .await
            .map_err(map_err)?;
        handle_of(&res).close().await.map_err(map_err)?;
        let parent = crate::uri::parent_of(id).unwrap_or_else(|| self.root_id());
        self.stat(&crate::uri::join(&parent, new_name)).await
    }

    async fn read_range(&self, id: &str, offset: u64, len: usize) -> Result<Vec<u8>> {
        if len == 0 {
            return Ok(Vec::new());
        }
        self.retry(|| async {
            let res = self.open(id, read_access()).await?;
            let Some(file) = res.as_file() else {
                handle_of(&res).close().await.ok();
                return Err(VfsError::Io(format!("not a file: {id}")));
            };
            let mut buf = vec![0u8; len];
            let mut filled = 0usize;
            while filled < len {
                let n = file
                    .read_at(&mut buf[filled..], offset + filled as u64)
                    .await
                    .map_err(map_err)?;
                if n == 0 {
                    break; // EOF: short read is allowed (contract §2)
                }
                filled += n;
            }
            buf.truncate(filled);
            file.handle().close().await.ok();
            Ok(buf)
        })
        .await
    }

    async fn write_range(&self, id: &str, offset: u64, data: &[u8]) -> Result<()> {
        self.retry(|| async {
            // OpenIf + generic write: native POSIX-slice semantics, no
            // negotiation dance needed like on WebDAV.
            let unc = self.resolve_unc(id)?;
            let args = FileCreateArgs {
                disposition: CreateDisposition::OpenIf,
                attributes: FileAttributes::new(),
                options: CreateOptions::new().with_non_directory_file(true),
                desired_access: write_access(),
            };
            let res = self
                .client
                .create_file(&unc, &args)
                .await
                .map_err(map_err)?;
            let Some(file) = res.as_file() else {
                handle_of(&res).close().await.ok();
                return Err(VfsError::Io(format!("not a file: {id}")));
            };
            let mut written = 0usize;
            while written < data.len() {
                let n = file
                    .write_at(&data[written..], offset + written as u64)
                    .await
                    .map_err(map_err)?;
                if n == 0 {
                    return Err(VfsError::Io(format!("zero-length write at {id}+{offset}")));
                }
                written += n;
            }
            file.flush().await.map_err(VfsError::io)?;
            file.handle().close().await.map_err(map_err)?;
            Ok(())
        })
        .await
    }

    async fn truncate(&self, id: &str, size: u64) -> Result<()> {
        self.retry(|| async {
            let res = self.open(id, write_access()).await?;
            let Some(file) = res.as_file() else {
                handle_of(&res).close().await.ok();
                return Err(VfsError::Io(format!("not a file: {id}")));
            };
            file.set_len(size).await.map_err(map_err)?;
            file.handle().close().await.map_err(map_err)?;
            Ok(())
        })
        .await
    }
}

impl SmbBackend {
    /// Mark-and-close deletion for a single (possibly checked-empty) file or
    /// directory. Server rejects non-empty dirs with STATUS_DIRECTORY_NOT_EMPTY.
    async fn delete_leaf(&self, entry: &Entry) -> Result<()> {
        let res = self.open(&entry.id, write_access()).await?;
        if let Resource::Directory(dir) = res {
            // Contract §2: recursive=false must never silently recurse.
            let dir = Arc::new(dir);
            let mut stream = smb::Directory::query::<FileIdBothDirectoryInformation>(&dir, "*")
                .await
                .map_err(map_err)?;
            // Samba echoes "." and ".." back for SMB2 queries; they don't
            // count as content.
            let mut not_empty = false;
            while let Some(item) = stream.next().await {
                if let Ok(info) = item {
                    let name = info.file_name.to_string();
                    if name != "." && name != ".." {
                        not_empty = true;
                        break;
                    }
                }
            }
            drop(stream);
            if not_empty {
                dir.close().await.ok();
                return Err(VfsError::Io(format!(
                    "directory not empty (pass recursive=true): {}",
                    entry.id
                )));
            }
            dir.set_info(FileDispositionInformation {
                delete_pending: true.into(),
            })
            .await
            .map_err(map_err)?;
            dir.close().await.map_err(map_err)?;
            Ok(())
        } else {
            handle_of(&res)
                .set_info(FileDispositionInformation {
                    delete_pending: true.into(),
                })
                .await
                .map_err(map_err)?;
            handle_of(&res).close().await.map_err(map_err)?;
            Ok(())
        }
    }
}

fn read_access() -> FileAccessMask {
    FileAccessMask::new().with_generic_read(true)
}

fn write_access() -> FileAccessMask {
    FileAccessMask::new()
        .with_generic_read(true)
        .with_generic_write(true)
        .with_delete(true)
}

/// Transport-class failures are worth a retry; anything with a real NT
/// status is deterministic and mapped immediately.
fn is_transport(err: &VfsError) -> bool {
    matches!(err, VfsError::Network(_))
}

fn map_err(err: smb::Error) -> VfsError {
    use smb::Error as E;
    match err {
        E::ReceivedErrorMessage(status, _) | E::UnexpectedMessageStatus(status) => {
            map_status(status)
        }
        E::ConnectionStopped => VfsError::Network("smb connection stopped".into()),
        E::IoError(e) if e.kind() == std::io::ErrorKind::Other => {
            // resource layer wraps statuses into io::Error on read/write
            VfsError::Network(e.to_string())
        }
        E::IoError(e) => VfsError::io(e),
        E::SspiError(e) => VfsError::PermissionDenied(format!("smb auth: {e}")),
        E::NegotiationError(e) => VfsError::Network(format!("smb negotiation: {e}")),
        other => VfsError::Io(other.to_string()),
    }
}

fn map_status(status: u32) -> VfsError {
    match status {
        Status::U32_OBJECT_NAME_NOT_FOUND | Status::U32_OBJECT_PATH_NOT_FOUND => {
            VfsError::NotFound(Status::try_display_as_status(status))
        }
        Status::U32_OBJECT_NAME_COLLISION => VfsError::AlreadyExists("target exists".into()),
        Status::U32_ACCESS_DENIED | Status::U32_SHARING_VIOLATION | Status::U32_LOGON_FAILURE => {
            VfsError::PermissionDenied(Status::try_display_as_status(status))
        }
        Status::U32_DIRECTORY_NOT_EMPTY => {
            VfsError::Io("directory not empty (pass recursive=true)".into())
        }
        other => VfsError::Io(format!(
            "smb status {}",
            Status::try_display_as_status(other)
        )),
    }
}

/// Windows-illegal names are rejected client-side so the UI gets `InvalidName`
/// instead of a wire error.
fn validate_name(name: &str) -> Result<()> {
    let invalid = name.is_empty()
        || name == "."
        || name == ".."
        || name.contains(['/', '\\', '<', '>', ':', '"', '|', '?', '*', '\0'])
        || name.ends_with(['.', ' ']);
    if invalid {
        return Err(VfsError::InvalidName(name.to_string()));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn backend() -> SmbBackend {
        // Construction without connecting: only used for id↔UNC unit tests.
        SmbBackend {
            client: Arc::new(Client::new(ClientConfig::default())),
            host: "NAS.local".into(),
            share: "Media".into(),
            auth: SmbAuth::guest(),
        }
    }

    #[test]
    fn ids_map_to_unc_paths() {
        let b = backend();
        let root = b.resolve_unc("smb://NAS.local/Media").unwrap();
        assert_eq!(root.to_string(), r"\\NAS.local\Media");
        let nested = b
            .resolve_unc("smb://nas.LOCAL/Media/我的 片/film (1).mkv")
            .unwrap();
        assert_eq!(
            nested.to_string(),
            r"\\NAS.local\Media\我的 片\film (1).mkv"
        );
        let normalized = b
            .resolve_unc("smb://NAS.local/media/a/./b/../c.txt")
            .unwrap();
        assert_eq!(normalized.to_string(), r"\\NAS.local\Media\a\c.txt");
    }

    #[test]
    fn rejects_escapes_and_foreign_mounts() {
        let b = backend();
        let err = b
            .resolve_unc("smb://NAS.local/Media/../../etc")
            .unwrap_err();
        assert!(matches!(err, VfsError::PermissionDenied(_)));
        assert!(b.resolve_unc("smb://other/Media/a").is_err());
        assert!(b.resolve_unc("smb://NAS.local/other/a").is_err());
        assert!(b.resolve_unc("webdav://NAS.local/Media/a").is_err());
    }

    #[test]
    fn windows_illegal_names() {
        assert!(validate_name("normal file.txt").is_ok());
        assert!(validate_name("a<b>.txt").is_err());
        assert!(validate_name("trailing.").is_err());
        assert!(validate_name("trailing ").is_err());
        assert!(matches!(
            validate_name("a/b").unwrap_err(),
            VfsError::InvalidName(_)
        ));
    }
}
