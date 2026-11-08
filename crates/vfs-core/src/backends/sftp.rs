//! SFTP backend (SSH File Transfer Protocol), built on russh + russh-sftp.
//!
//! Like SMB, the protocol maps 1:1 onto the POSIX-shaped `Backend` contract:
//! LSTAT/READDIR, positional reads and writes, SETSTAT.fsize for truncate,
//! MKDIR/REMOVE/RMDIR/RENAME - so `can_random_write` is genuinely true.
//!
//! Session model: one SSH connection carrying one SFTP subsystem channel,
//! established eagerly at mount and re-established lazily after a transport
//! failure (contract SS4: bounded retries with exponential backoff). Protocol
//! status codes map to semantic errors and are never retried.
//!
//! Dependency note: russh is pinned to 0.55 because every newer release asks
//! for RustCrypto crate versions that the single lockfile cannot hold next to
//! smb's sspi pins; the version-by-version analysis lives in the workspace
//! Cargo.toml. Upgrade path: unpin smb's sspi, then russh can move forward.
//!
//! Security note: any server host key is accepted (same trust model as smb
//! NTLMv2 on trusted LAN media boxes). TOFU fingerprint pinning is M2+ work.

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt};
use tokio::sync::Mutex;

use russh::client::{self, AuthResult};
use russh::keys::{PrivateKey, PrivateKeyWithHashAlg};
use russh_sftp::client::error::Error as SftpError;
use russh_sftp::client::SftpSession;
use russh_sftp::protocol::{FileAttributes, FileType, OpenFlags, StatusCode};

use crate::backend::Backend;
use crate::capabilities::Capabilities;
use crate::entry::{guess_mime, Entry, EntryKind};
use crate::error::{Result, VfsError};
use crate::uri::split_id;

pub const SCHEME: &str = "sftp";

const MAX_ATTEMPTS: u32 = 3;

/// How to authenticate against the SSH server.
#[derive(Debug, Clone)]
pub enum SftpAuth {
    Password {
        username: String,
        password: String,
    },
    /// OpenSSH/PEM encoded private key held in memory, with the passphrase
    /// needed when the key is encrypted.
    PrivateKey {
        username: String,
        key_pem: String,
        passphrase: Option<String>,
    },
}

impl SftpAuth {
    pub fn password(username: impl Into<String>, password: impl Into<String>) -> Self {
        Self::Password {
            username: username.into(),
            password: password.into(),
        }
    }

    pub fn private_key(
        username: impl Into<String>,
        key_pem: impl Into<String>,
        passphrase: Option<String>,
    ) -> Self {
        Self::PrivateKey {
            username: username.into(),
            key_pem: key_pem.into(),
            passphrase,
        }
    }
}

/// russh client callbacks. Any host key is accepted (see module note).
struct SshClient;

impl client::Handler for SshClient {
    type Error = russh::Error;

    async fn check_server_key(
        &mut self,
        _server_public_key: &russh::keys::ssh_key::PublicKey,
    ) -> std::result::Result<bool, Self::Error> {
        Ok(true)
    }
}

/// Live SSH handle + SFTP session; dropped and rebuilt on reconnect.
struct Conn {
    /// Handle must stay alive for the SSH session task to keep running.
    _ssh: client::Handle<SshClient>,
    sftp: Arc<SftpSession>,
}

/// A single SFTP mount (`sftp://<host>[:<port>]/<root_abs>/...`), rooted at
/// the login user's canonicalized home directory.
pub struct SftpBackend {
    host: String,
    port: u16,
    auth: SftpAuth,
    /// Canonical path the SSH session landed in (`canonicalize(".")`); the
    /// jail all entry ids must stay inside.
    root_abs: String,
    conn: Mutex<Option<Conn>>,
}

impl SftpBackend {
    /// Connect eagerly so bad credentials/hosts fail at mount time, not on
    /// the first browse click. `port` defaults to 22 when passed as 0.
    pub async fn connect(host: &str, port: u16, auth: SftpAuth) -> Result<Self> {
        let backend = Self {
            host: host.trim().trim_matches('/').to_string(),
            port: if port == 0 { 22 } else { port },
            auth,
            root_abs: String::new(),
            conn: Mutex::new(None),
        };
        let (ssh, sftp) = backend.establish_session().await?;
        let root = sftp.canonicalize(".").await.map_err(map_sftp_err)?;
        let root_abs = root.trim_end_matches('/').to_string();
        let mut conn = backend.conn.lock().await;
        *conn = Some(Conn {
            _ssh: ssh,
            sftp: Arc::new(sftp),
        });
        drop(conn);
        Ok(Self {
            root_abs: if root_abs.is_empty() {
                "/".to_string()
            } else {
                root_abs
            },
            ..backend
        })
    }

    /// Canonical id of the mount root.
    pub fn root_id(&self) -> String {
        self.id_for(&self.root_abs)
    }

    /// `host` when the port is the default, `host:port` otherwise.
    fn authority(&self) -> String {
        if self.port == 22 {
            self.host.clone()
        } else {
            format!("{}:{}", self.host, self.port)
        }
    }

    fn id_for(&self, abs: &str) -> String {
        format!("{SCHEME}://{}{}", self.authority(), abs)
    }

    /// Entry id -> absolute SFTP path, jailed under `root_abs`.
    fn resolve_path(&self, id: &str) -> Result<String> {
        let (scheme, rest) = split_id(id);
        if scheme != SCHEME {
            return Err(VfsError::Unsupported(format!(
                "sftp backend cannot handle {id}"
            )));
        }
        let (authority, path) = match rest.find('/') {
            Some(idx) => rest.split_at(idx),
            None => (rest, ""),
        };
        if !authority.eq_ignore_ascii_case(&self.authority()) {
            return Err(VfsError::Unsupported(format!(
                "id belongs to another sftp host: {id}"
            )));
        }
        // Bare `sftp://host` refers to the mount root.
        if path.is_empty() {
            return Ok(self.root_abs.clone());
        }
        // Same lexical normalization as local/smb: resolve `.`/`..` first...
        let mut kept: Vec<&str> = Vec::new();
        for seg in path.split('/').filter(|s| !s.is_empty()) {
            match seg {
                "." => {}
                ".." if kept.pop().is_none() => {
                    return Err(VfsError::PermissionDenied(format!(
                        "path escapes sftp mount root: {id}"
                    )))
                }
                ".." => {}
                other => kept.push(other),
            }
        }
        let abs = format!("/{}", kept.join("/"));
        // ...then reject anything that ended up outside the login root.
        if self.root_abs != "/"
            && abs != self.root_abs
            && !abs.starts_with(&format!("{}/", self.root_abs))
        {
            return Err(VfsError::PermissionDenied(format!(
                "path escapes sftp mount root: {id}"
            )));
        }
        Ok(abs)
    }

    fn entry_of(
        &self,
        id: String,
        name: String,
        parent: Option<String>,
        attrs: &FileAttributes,
    ) -> Entry {
        // NOTE: the FileAttributes bit-setters overlap (`LNK` includes the
        // `REG` bits), so `is_regular()` lies for symlinks; the field-based
        // `file_type()` is the only exact kind detector.
        let kind = match attrs.file_type() {
            FileType::Dir => EntryKind::Directory,
            FileType::File => EntryKind::File,
            FileType::Symlink => EntryKind::Symlink,
            FileType::Other => {
                // Some minimal servers omit the mode bits entirely; treating
                // an untyped entry as a file is kinder than as special junk.
                if attrs.permissions.is_none() {
                    EntryKind::File
                } else {
                    EntryKind::Special
                }
            }
        };
        Entry {
            id,
            parent,
            name: name.clone(),
            kind,
            size: if kind == EntryKind::Directory {
                0
            } else {
                attrs.size.unwrap_or(0)
            },
            modified_ms: attrs.mtime.map(|secs| secs as i64 * 1000),
            mime: (kind == EntryKind::File)
                .then(|| guess_mime(&name))
                .flatten(),
            hidden: name.starts_with('.'),
            // No write bit for anyone -> the UI should show the lock badge.
            readonly: attrs.permissions.map(|p| p & 0o222 == 0).unwrap_or(false),
        }
    }

    fn entry_at_path(&self, abs: &str, attrs: &FileAttributes) -> Entry {
        if abs == self.root_abs {
            return self.entry_of(self.id_for(abs), self.authority(), None, attrs);
        }
        let name = abs.rsplit('/').next().unwrap_or(abs).to_string();
        // The jail guarantees a non-empty parent here (abs is under root_abs).
        let parent_abs = &abs[..abs.len() - name.len() - 1];
        let parent_id = if parent_abs.is_empty() {
            self.id_for("/")
        } else {
            self.id_for(parent_abs)
        };
        self.entry_of(self.id_for(abs), name, Some(parent_id), attrs)
    }

    /// Open a fresh SSH connection + SFTP channel and authenticate.
    async fn establish_session(&self) -> Result<(client::Handle<SshClient>, SftpSession)> {
        let config = client::Config {
            nodelay: true,
            keepalive_interval: Some(Duration::from_secs(30)),
            ..Default::default()
        };
        let mut ssh = client::connect(Arc::new(config), (self.host.as_str(), self.port), SshClient)
            .await
            .map_err(net_err)?;

        let result = match &self.auth {
            SftpAuth::Password { username, password } => ssh
                .authenticate_password(username, password)
                .await
                .map_err(auth_err)?,
            SftpAuth::PrivateKey {
                username,
                key_pem,
                passphrase,
            } => {
                let mut key = PrivateKey::from_openssh(key_pem).map_err(|e| {
                    VfsError::PermissionDenied(format!("sftp key parse failed: {e}"))
                })?;
                if key.is_encrypted() {
                    let Some(pass) = passphrase else {
                        return Err(VfsError::PermissionDenied(
                            "sftp key is encrypted but no passphrase given".into(),
                        ));
                    };
                    key = key.decrypt(pass).map_err(|e| {
                        VfsError::PermissionDenied(format!("sftp key decrypt failed: {e}"))
                    })?;
                }
                ssh.authenticate_publickey(
                    username,
                    PrivateKeyWithHashAlg::new(Arc::new(key), None),
                )
                .await
                .map_err(auth_err)?
            }
        };
        if !matches!(result, AuthResult::Success) {
            return Err(VfsError::PermissionDenied(
                "sftp authentication failed".into(),
            ));
        }

        let channel = ssh.channel_open_session().await.map_err(net_err)?;
        channel
            .request_subsystem(true, "sftp")
            .await
            .map_err(net_err)?;
        let sftp = SftpSession::new(channel.into_stream())
            .await
            .map_err(map_sftp_err)?;
        Ok((ssh, sftp))
    }

    /// Current SFTP session, (re)connecting when the cached one is gone.
    async fn sftp(&self) -> Result<Arc<SftpSession>> {
        let mut guard = self.conn.lock().await;
        if let Some(conn) = guard.as_ref() {
            return Ok(conn.sftp.clone());
        }
        let (ssh, sftp) = self.establish_session().await?;
        let sftp = Arc::new(sftp);
        *guard = Some(Conn {
            _ssh: ssh,
            sftp: sftp.clone(),
        });
        Ok(sftp)
    }

    async fn drop_conn(&self) {
        *self.conn.lock().await = None;
    }

    /// Retry transport-class failures with bounded backoff (contract SS4);
    /// a dropped session is re-established before the retry, mirroring how
    /// the smb backend re-issues `share_connect`.
    async fn retry<T, F, Fut>(&self, mut op: F) -> Result<T>
    where
        F: FnMut(Arc<SftpSession>) -> Fut,
        Fut: std::future::Future<Output = Result<T>>,
    {
        let mut delay = Duration::from_millis(200);
        let mut attempt = 0u32;
        loop {
            let sftp = self.sftp().await?;
            match op(sftp).await {
                Err(err) if is_transport(&err) && attempt + 1 < MAX_ATTEMPTS => {
                    self.drop_conn().await;
                    tokio::time::sleep(delay).await;
                    delay *= 4;
                    attempt += 1;
                }
                other => return other,
            }
        }
    }
}

#[async_trait]
impl Backend for SftpBackend {
    fn scheme(&self) -> &'static str {
        SCHEME
    }

    fn display_name(&self) -> String {
        format!("sftp ({})", self.authority())
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities {
            can_watch: false, // SFTP has no change-notification verb.
            ..Capabilities::READ_WRITE
        }
    }

    async fn stat(&self, id: &str) -> Result<Entry> {
        self.retry(|sftp| async move {
            let abs = self.resolve_path(id)?;
            // Contract SS2: lstat semantics, symlinks are not followed.
            let attrs = sftp
                .symlink_metadata(&abs)
                .await
                .map_err(|e| map_sftp_err_at(e, &abs))?;
            Ok(self.entry_at_path(&abs, &attrs))
        })
        .await
    }

    async fn list(&self, id: &str) -> Result<Vec<Entry>> {
        self.retry(|sftp| async move {
            let abs = self.resolve_path(id)?;
            let attrs = sftp
                .symlink_metadata(&abs)
                .await
                .map_err(|e| map_sftp_err_at(e, &abs))?;
            if !attrs.file_type().is_dir() {
                return Err(VfsError::Io(format!("not a directory: {id}")));
            }
            let read_dir = sftp
                .read_dir(&abs)
                .await
                .map_err(|e| map_sftp_err_at(e, &abs))?;
            let mut entries = Vec::new();
            for item in read_dir {
                // ReadDir folds one readdir reply per entry already; a bad
                // entry cannot arrive here, so the listing never fails midway.
                let name = item.file_name();
                let child_abs = format!("{}/{}", abs.trim_end_matches('/'), name);
                let child = self.entry_of(
                    self.id_for(&child_abs),
                    name,
                    Some(id.to_string()),
                    &item.metadata(),
                );
                entries.push(child);
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
    }

    async fn create_dir(&self, parent: &str, name: &str) -> Result<Entry> {
        validate_name(name)?;
        self.retry(|sftp| async move {
            let child_id = crate::uri::join(parent, name);
            let abs = self.resolve_path(&child_id)?;
            // SFTP v3 has no "must not exist" flag for MKDIR; OpenSSH answers
            // an existing dir with a generic FAILURE, so check first.
            if sftp.symlink_metadata(&abs).await.is_ok() {
                return Err(VfsError::AlreadyExists(child_id));
            }
            sftp.create_dir(&abs)
                .await
                .map_err(|e| map_sftp_err_at(e, &abs))?;
            let attrs = sftp
                .symlink_metadata(&abs)
                .await
                .map_err(|e| map_sftp_err_at(e, &abs))?;
            Ok(self.entry_at_path(&abs, &attrs))
        })
        .await
    }

    async fn create_file(&self, parent: &str, name: &str) -> Result<Entry> {
        validate_name(name)?;
        self.retry(|sftp| async move {
            let child_id = crate::uri::join(parent, name);
            let abs = self.resolve_path(&child_id)?;
            if sftp.symlink_metadata(&abs).await.is_ok() {
                return Err(VfsError::AlreadyExists(child_id));
            }
            let file = sftp
                .open_with_flags(&abs, OpenFlags::CREATE | OpenFlags::WRITE)
                .await
                .map_err(|e| map_sftp_err_at(e, &abs))?;
            file.close().await.map_err(sftp_io_err)?;
            let attrs = sftp
                .symlink_metadata(&abs)
                .await
                .map_err(|e| map_sftp_err_at(e, &abs))?;
            Ok(self.entry_at_path(&abs, &attrs))
        })
        .await
    }

    async fn remove(&self, id: &str, recursive: bool) -> Result<()> {
        // Not retried end-to-end: after a stuck-but-successful delete the
        // retry would land on NotFound and report a false failure.
        let entry = self.stat(id).await?;
        if entry.is_dir() {
            if recursive {
                for child in self.list(id).await? {
                    Box::pin(self.remove(&child.id, true)).await?;
                }
            } else if !self.list(id).await?.is_empty() {
                // RMDIR reports non-empty dirs as a generic FAILURE on the
                // wire; check first so the caller gets a deterministic error
                // (contract SS2 forbids silent recursion).
                return Err(VfsError::Io(format!(
                    "directory not empty (pass recursive=true): {id}"
                )));
            }
            let abs = self.resolve_path(id)?;
            let sftp = self.sftp().await?;
            sftp.remove_dir(&abs)
                .await
                .map_err(|e| map_sftp_err_at(e, &abs))
        } else {
            let abs = self.resolve_path(id)?;
            let sftp = self.sftp().await?;
            sftp.remove_file(&abs)
                .await
                .map_err(|e| map_sftp_err_at(e, &abs))
        }
    }

    async fn rename(&self, id: &str, new_name: &str) -> Result<Entry> {
        validate_name(new_name)?;
        let abs = self.resolve_path(id)?;
        if abs == self.root_abs {
            return Err(VfsError::PermissionDenied(
                "cannot rename the mount root".into(),
            ));
        }
        // Same-parent only (contract SS2: cross-directory moves are the
        // engine's job). RENAME replaces the basename, not the directory.
        let base = abs.rsplit('/').next().unwrap_or(&abs);
        let new_abs = format!("{}{new_name}", &abs[..abs.len() - base.len()]);
        self.retry(|sftp| {
            let abs = abs.clone();
            let new_abs = new_abs.clone();
            async move {
                sftp.rename(&abs, &new_abs)
                    .await
                    .map_err(|e| map_sftp_err_at(e, &abs))?;
                let attrs = sftp
                    .symlink_metadata(&new_abs)
                    .await
                    .map_err(|e| map_sftp_err_at(e, &new_abs))?;
                Ok(self.entry_at_path(&new_abs, &attrs))
            }
        })
        .await
    }

    async fn read_range(&self, id: &str, offset: u64, len: usize) -> Result<Vec<u8>> {
        if len == 0 {
            return Ok(Vec::new());
        }
        self.retry(|sftp| async move {
            let abs = self.resolve_path(id)?;
            let mut file = sftp
                .open(&abs)
                .await
                .map_err(|e| map_sftp_err_at(e, &abs))?;
            file.seek(std::io::SeekFrom::Start(offset))
                .await
                .map_err(sftp_io_err)?;
            let mut buf = vec![0u8; len];
            let mut filled = 0usize;
            while filled < len {
                let n = file.read(&mut buf[filled..]).await.map_err(sftp_io_err)?;
                if n == 0 {
                    break; // EOF: short read is allowed (contract SS2)
                }
                filled += n;
            }
            file.close().await.ok();
            buf.truncate(filled);
            Ok(buf)
        })
        .await
    }

    async fn write_range(&self, id: &str, offset: u64, data: &[u8]) -> Result<()> {
        self.retry(|sftp| async move {
            let abs = self.resolve_path(id)?;
            // WRITE|CREATE without TRUNCATE: native POSIX-slice semantics,
            // no negotiation dance needed like on WebDAV.
            let mut file = sftp
                .open_with_flags(&abs, OpenFlags::WRITE | OpenFlags::CREATE)
                .await
                .map_err(|e| map_sftp_err_at(e, &abs))?;
            file.seek(std::io::SeekFrom::Start(offset))
                .await
                .map_err(sftp_io_err)?;
            file.write_all(data).await.map_err(sftp_io_err)?;
            // flush drains the pending write acks, so server-side write
            // failures surface here instead of being dropped with the handle.
            file.flush().await.map_err(sftp_io_err)?;
            file.close().await.map_err(sftp_io_err)?;
            Ok(())
        })
        .await
    }

    async fn truncate(&self, id: &str, size: u64) -> Result<()> {
        self.retry(|sftp| async move {
            let abs = self.resolve_path(id)?;
            let attrs = FileAttributes {
                size: Some(size),
                ..Default::default()
            };
            sftp.set_metadata(&abs, attrs)
                .await
                .map_err(|e| map_sftp_err_at(e, &abs))
        })
        .await
    }
}

/// Transport-class failures are worth a retry; protocol status codes are
/// deterministic and mapped immediately.
fn is_transport(err: &VfsError) -> bool {
    matches!(err, VfsError::Network(_))
}

fn net_err(err: russh::Error) -> VfsError {
    VfsError::Network(err.to_string())
}

/// Errors during the auth handshake: rejected methods are semantic
/// (`PermissionDenied`), everything else is transport.
fn auth_err(err: russh::Error) -> VfsError {
    match err {
        russh::Error::NotAuthenticated | russh::Error::UnsupportedAuthMethod => {
            VfsError::PermissionDenied(err.to_string())
        }
        other => VfsError::Network(other.to_string()),
    }
}

/// russh-sftp wraps every client error into `io::Error::other` inside its
/// `File` AsyncRead/AsyncWrite impls, so Other means an SFTP-level failure
/// (worth retrying after reconnect), while real io kinds map semantically.
fn sftp_io_err(err: std::io::Error) -> VfsError {
    if err.kind() == std::io::ErrorKind::Other {
        VfsError::Network(err.to_string())
    } else {
        VfsError::io(err)
    }
}

fn map_sftp_err(err: SftpError) -> VfsError {
    match err {
        SftpError::Status(status) => match status.status_code {
            StatusCode::NoSuchFile => VfsError::NotFound(status.error_message),
            StatusCode::PermissionDenied => VfsError::PermissionDenied(status.error_message),
            StatusCode::OpUnsupported => VfsError::Unsupported(status.error_message),
            StatusCode::NoConnection | StatusCode::ConnectionLost => {
                VfsError::Network(status.error_message)
            }
            other => VfsError::Io(format!("{other}: {}", status.error_message)),
        },
        SftpError::IO(e) => VfsError::Network(e),
        SftpError::Timeout => VfsError::Network("sftp request timed out".into()),
        SftpError::UnexpectedPacket => VfsError::Network("unexpected sftp packet".into()),
        SftpError::UnexpectedBehavior(e) => VfsError::Network(e),
        // Server-advertised limits (e.g. max open handles) are deterministic.
        SftpError::Limited(e) => VfsError::Io(format!("sftp server limit: {e}")),
    }
}

/// Attach the request path to the two variants whose payload UI may surface.
fn map_sftp_err_at(err: SftpError, abs: &str) -> VfsError {
    match map_sftp_err(err) {
        VfsError::NotFound(_) => VfsError::NotFound(abs.to_string()),
        VfsError::PermissionDenied(msg) => VfsError::PermissionDenied(format!("{abs}: {msg}")),
        other => other,
    }
}

/// POSIX-illegal names are rejected client-side so the UI gets `InvalidName`
/// instead of a wire error.
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

#[cfg(test)]
mod tests {
    use super::*;

    fn backend() -> SftpBackend {
        // Construction without connecting: only used for id<->path unit tests.
        SftpBackend {
            host: "NAS.local".into(),
            port: 2222,
            auth: SftpAuth::password("alice", "secret"),
            root_abs: "/home/alice".into(),
            conn: Mutex::new(None),
        }
    }

    #[test]
    fn ids_map_to_paths() {
        let b = backend();
        assert_eq!(b.root_id(), "sftp://NAS.local:2222/home/alice");
        assert_eq!(
            b.resolve_path("sftp://nas.LOCAL:2222/home/alice/我的 片/film.mkv")
                .unwrap(),
            "/home/alice/我的 片/film.mkv"
        );
        let normalized = b
            .resolve_path("sftp://NAS.local:2222/home/alice/a/./b/../c.txt")
            .unwrap();
        assert_eq!(normalized, "/home/alice/a/c.txt");
        // Bare host ids point at the mount root.
        assert_eq!(
            b.resolve_path("sftp://NAS.local:2222").unwrap(),
            "/home/alice"
        );
    }

    #[test]
    fn rejects_escapes_and_foreign_mounts() {
        let b = backend();
        let err = b
            .resolve_path("sftp://NAS.local:2222/home/alice/../../etc/passwd")
            .unwrap_err();
        assert!(matches!(err, VfsError::PermissionDenied(_)));
        let err = b
            .resolve_path("sftp://NAS.local:2222/etc/hostname")
            .unwrap_err();
        assert!(matches!(err, VfsError::PermissionDenied(_)));
        assert!(b.resolve_path("sftp://other:2222/home/alice/a").is_err());
        assert!(b.resolve_path("sftp://NAS.local/home/alice/a").is_err()); // wrong port
        assert!(b
            .resolve_path("webdav://NAS.local:2222/home/alice")
            .is_err());
    }

    #[test]
    fn default_port_is_dropped_from_authority() {
        let b = SftpBackend {
            host: "nas".into(),
            port: 22,
            auth: SftpAuth::password("alice", "secret"),
            root_abs: "/".into(),
            conn: Mutex::new(None),
        };
        assert_eq!(b.id_for("/a/b.txt"), "sftp://nas/a/b.txt");
        // A jail at "/" never rejects.
        assert_eq!(
            b.resolve_path("sftp://nas/anything/goes").unwrap(),
            "/anything/goes"
        );
    }

    #[test]
    fn name_validation() {
        assert!(validate_name("normal file.txt").is_ok());
        assert!(validate_name("中文名 (1).mkv").is_ok());
        assert!(validate_name("").is_err());
        assert!(matches!(
            validate_name("a/b").unwrap_err(),
            VfsError::InvalidName(_)
        ));
        assert!(validate_name("..").is_err());
        assert!(validate_name("a\\b").is_err());
        assert!(validate_name("nul\0x").is_err());
    }

    #[test]
    fn status_codes_map_to_semantic_errors() {
        let status = |code| russh_sftp::protocol::Status {
            id: 0,
            status_code: code,
            error_message: "msg".into(),
            language_tag: String::new(),
        };
        assert!(matches!(
            map_sftp_err(SftpError::Status(status(StatusCode::NoSuchFile))),
            VfsError::NotFound(_)
        ));
        assert!(matches!(
            map_sftp_err(SftpError::Status(status(StatusCode::PermissionDenied))),
            VfsError::PermissionDenied(_)
        ));
        assert!(matches!(
            map_sftp_err(SftpError::Status(status(StatusCode::Failure))),
            VfsError::Io(_)
        ));
        assert!(matches!(
            map_sftp_err(SftpError::Status(status(StatusCode::ConnectionLost))),
            VfsError::Network(_)
        ));
        assert!(matches!(
            map_sftp_err(SftpError::Status(status(StatusCode::OpUnsupported))),
            VfsError::Unsupported(_)
        ));
        assert!(matches!(
            map_sftp_err(SftpError::Timeout),
            VfsError::Network(_)
        ));
        assert!(matches!(
            map_sftp_err(SftpError::Limited("x".into())),
            VfsError::Io(_)
        ));
    }

    #[test]
    fn entry_mapping_uses_lstat_kinds() {
        let b = backend();
        let mut attrs = FileAttributes {
            size: Some(7),
            mtime: Some(1_700_000_000),
            ..Default::default()
        };
        attrs.set_symlink(true);
        let e = b.entry_at_path("/home/alice/link", &attrs);
        assert_eq!(e.kind, EntryKind::Symlink);
        assert_eq!(e.size, 7);
        assert_eq!(e.modified_ms, Some(1_700_000_000_000));
        assert_eq!(
            e.parent.as_deref(),
            Some("sftp://NAS.local:2222/home/alice")
        );

        let mut attrs = FileAttributes {
            permissions: Some(0o40500),
            ..Default::default()
        };
        attrs.set_dir(true);
        let root = b.entry_at_path("/home/alice", &attrs);
        assert_eq!(root.kind, EntryKind::Directory);
        assert_eq!(root.name, "NAS.local:2222");
        assert_eq!(root.parent, None);
        assert!(root.readonly);
    }
}
