//! Dropbox backend (HTTP v2 API), path-based namespace.
//!
//! Protocol notes:
//!
//! * Metadata lives on `api.dropboxapi.com/2/...` (JSON RPC); content transfer
//!   uses `content.dropboxapi.com/2/files/{download,upload,...}` where the
//!   request parameters ride in a `Dropbox-API-Arg` header and the body is the
//!   raw bytes.
//! * Paths are hierarchical, so an entry id maps 1:1 to a Dropbox path. The
//!   mount root is spelled `dropbox://root` and children are
//!   `dropbox://root/<path>`.
//! * Downloads support `Range`, so `can_seek` is true. Random writes do not
//!   exist: `write_range` spools into a local temp file and `truncate` uploads
//!   it whole (simple `files/upload` for empty/small, upload session for large).

use std::path::Path;
use std::sync::Arc;

use async_trait::async_trait;
use serde_json::json;

use crate::backend::Backend;
use crate::capabilities::Capabilities;
use crate::entry::{guess_mime, Entry, EntryKind};
use crate::error::{Result, VfsError};
use crate::uri::split_id;

use super::cloud::{self, parse_rfc3339_ms, CloudAuth, SpoolPool};

pub const SCHEME: &str = "dropbox";

const RPC_BASE: &str = "https://api.dropboxapi.com/2";
const CONTENT_BASE: &str = "https://content.dropboxapi.com/2";

/// Above this size `files/upload` is replaced by an upload session (Dropbox
/// simple upload limit is 150 MB; we stay well under it to bound memory).
const SIMPLE_UPLOAD_LIMIT: u64 = 8 * 1024 * 1024;

#[derive(Debug, serde::Deserialize)]
struct DbxEntry {
    #[serde(rename = ".tag")]
    tag: String,
    name: String,
    #[serde(default)]
    path_display: Option<String>,
    #[serde(default)]
    size: Option<u64>,
    #[serde(default)]
    server_modified: Option<String>,
    #[serde(default)]
    is_downloadable: Option<bool>,
}

#[derive(Debug, serde::Deserialize)]
struct DbxList {
    #[serde(default)]
    entries: Vec<DbxEntry>,
    #[serde(default)]
    cursor: Option<String>,
    #[serde(default)]
    has_more: bool,
}

/// A single Dropbox mount (single account). Mount it via [`crate::Vfs::mount_at`].
pub struct DropboxBackend {
    client: reqwest::Client,
    auth: CloudAuth,
    spool: Arc<SpoolPool>,
}

impl DropboxBackend {
    pub fn new(
        access_token: String,
        refresh_token: Option<String>,
        client_id: String,
        client_secret: Option<String>,
    ) -> Self {
        let client = cloud::http_client();
        let auth = CloudAuth::new(
            client.clone(),
            access_token,
            refresh_token,
            client_id,
            client_secret,
            "https://api.dropboxapi.com/oauth2/token".to_string(),
        );
        Self {
            client,
            auth,
            spool: SpoolPool::new(),
        }
    }

    /// Canonical id of the mount root: `dropbox://root`.
    pub fn root_id(&self) -> String {
        make_id("")
    }

    /// Dropbox path ("" = root, else "/a/b") for a backend id.
    fn path_of(&self, id: &str) -> Result<String> {
        let (scheme, rest) = split_id(id);
        if scheme != SCHEME {
            return Err(VfsError::Unsupported(format!(
                "dropbox backend cannot handle {id}"
            )));
        }
        if rest == "root" {
            return Ok(String::new());
        }
        match rest.strip_prefix("root/") {
            Some(path) if !path.is_empty() => Ok(format!("/{path}")),
            _ => Err(VfsError::Unsupported(format!("bad dropbox id: {id}"))),
        }
    }

    fn entry_of(&self, entry: DbxEntry) -> Entry {
        let is_dir = entry.tag == "folder";
        let name = entry.name.clone();
        let path = entry
            .path_display
            .clone()
            .unwrap_or_else(|| format!("/{name}"));
        let kind = if is_dir {
            EntryKind::Directory
        } else {
            EntryKind::File
        };
        let mime = if kind == EntryKind::File {
            guess_mime(&name)
        } else {
            None
        };
        Entry {
            id: make_id(&path),
            parent: parent_id(&path),
            name,
            kind,
            size: if is_dir { 0 } else { entry.size.unwrap_or(0) },
            modified_ms: entry.server_modified.as_deref().and_then(parse_rfc3339_ms),
            mime,
            hidden: entry.name.starts_with('.'),
            readonly: if is_dir {
                false
            } else {
                !entry.is_downloadable.unwrap_or(true)
            },
        }
    }

    async fn rpc(&self, url: &str, arg: serde_json::Value) -> Result<serde_json::Value> {
        let resp = cloud::send_with_auth(&self.client, &self.auth, true, |c| {
            c.post(url)
                .header(reqwest::header::CONTENT_TYPE, "application/json")
                .body(arg.to_string())
        })
        .await?;
        if !resp.status().is_success() {
            return Err(self.map_error(resp, "").await);
        }
        let body = resp.text().await.map_err(net_err)?;
        if body.is_empty() {
            return Ok(serde_json::Value::Null);
        }
        serde_json::from_str(&body)
            .map_err(|e| VfsError::Network(format!("invalid Dropbox JSON: {e}")))
    }

    /// Content request: parameters in the `Dropbox-API-Arg` header, raw body.
    async fn content(
        &self,
        url: &str,
        api_arg: serde_json::Value,
        range: Option<String>,
        body: Option<Vec<u8>>,
    ) -> Result<reqwest::Response> {
        let resp = cloud::send_with_auth(&self.client, &self.auth, false, |c| {
            let mut req = c.post(url).header("Dropbox-API-Arg", api_arg.to_string());
            if let Some(range) = &range {
                req = req.header(reqwest::header::RANGE, range.clone());
            }
            if let Some(body) = &body {
                req = req.body(body.clone());
            }
            req
        })
        .await?;
        if resp.status().is_success() || resp.status().as_u16() == 206 {
            Ok(resp)
        } else {
            Err(self.map_error(resp, "").await)
        }
    }

    async fn map_error(&self, resp: reqwest::Response, path: &str) -> VfsError {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        let summary = serde_json::from_str::<serde_json::Value>(&body)
            .ok()
            .and_then(|v| {
                v.get("error_summary")
                    .and_then(|s| s.as_str())
                    .map(String::from)
            });
        let detail = summary.unwrap_or(body);
        match status.as_u16() {
            401 => VfsError::PermissionDenied(format!("dropbox auth: {detail}")),
            404 => VfsError::NotFound(path.to_string()),
            409 => {
                if detail.contains("not_found") || detail.contains("not_found/") {
                    VfsError::NotFound(format!("parent of {path}"))
                } else if detail.contains("conflict") || detail.contains("already_exists") {
                    VfsError::AlreadyExists(path.to_string())
                } else {
                    VfsError::Io(format!("{path}: {detail}"))
                }
            }
            416 => VfsError::Io(format!("range not satisfiable: {path}")),
            _ => VfsError::Network(format!("{path}: HTTP {status}: {detail}")),
        }
    }

    async fn upload_spool(&self, spool: &super::cloud::Spool, size: u64) -> Result<()> {
        let path = join_path(&spool.parent, &spool.name);
        let commit = json!({
            "path": path,
            "mode": "overwrite",
            "autorename": false,
            "mute": true
        });
        if size == 0 {
            let arg = json!({
                "path": path,
                "mode": "overwrite",
                "autorename": false,
                "mute": true
            });
            let resp = self
                .content(
                    &format!("{CONTENT_BASE}/files/upload"),
                    arg,
                    None,
                    Some(Vec::new()),
                )
                .await?;
            let body = resp.text().await.map_err(net_err)?;
            let _: DbxEntry = serde_json::from_str(&body)
                .map_err(|e| VfsError::Network(format!("invalid upload response: {e}")))?;
            return Ok(());
        }
        if size <= SIMPLE_UPLOAD_LIMIT {
            let data = tokio::fs::read(&spool.path).await.map_err(VfsError::io)?;
            let arg = json!({
                "path": path,
                "mode": "overwrite",
                "autorename": false,
                "mute": true
            });
            let resp = self
                .content(
                    &format!("{CONTENT_BASE}/files/upload"),
                    arg,
                    None,
                    Some(data),
                )
                .await?;
            let body = resp.text().await.map_err(net_err)?;
            let _: DbxEntry = serde_json::from_str(&body)
                .map_err(|e| VfsError::Network(format!("invalid upload response: {e}")))?;
            return Ok(());
        }
        self.upload_session(&spool.path, size, &commit).await
    }

    async fn upload_session(
        &self,
        file: &Path,
        size: u64,
        commit: &serde_json::Value,
    ) -> Result<()> {
        // start
        let resp = self
            .content(
                &format!("{CONTENT_BASE}/files/upload_session/start"),
                json!({ "close": false }),
                None,
                Some(Vec::new()),
            )
            .await?;
        let body = resp.text().await.map_err(net_err)?;
        let session_id = serde_json::from_str::<serde_json::Value>(&body)
            .map_err(|e| VfsError::Network(format!("invalid session start: {e}")))?
            .get("session_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| VfsError::Network("upload session missing session_id".into()))?
            .to_string();

        // append in chunks
        let mut file = tokio::fs::File::open(file).await.map_err(VfsError::io)?;
        use tokio::io::AsyncReadExt;
        let mut offset = 0u64;
        let mut buf = vec![0u8; cloud::UPLOAD_CHUNK];
        while offset < size {
            let want = ((size - offset) as usize).min(buf.len());
            let n = file.read(&mut buf[..want]).await.map_err(VfsError::io)?;
            if n == 0 {
                break;
            }
            let arg = json!({
                "cursor": { "session_id": session_id, "offset": offset }
            });
            let resp = self
                .content(
                    &format!("{CONTENT_BASE}/files/upload_session/append_v2"),
                    arg,
                    None,
                    Some(buf[..n].to_vec()),
                )
                .await?;
            let _ = resp.bytes().await.map_err(net_err)?;
            offset += n as u64;
        }

        // finish
        let arg = json!({
            "cursor": { "session_id": session_id, "offset": offset },
            "commit": commit
        });
        let resp = self
            .content(
                &format!("{CONTENT_BASE}/files/upload_session/finish"),
                arg,
                None,
                Some(Vec::new()),
            )
            .await?;
        let body = resp.text().await.map_err(net_err)?;
        let _: DbxEntry = serde_json::from_str(&body)
            .map_err(|e| VfsError::Network(format!("invalid upload finish: {e}")))?;
        Ok(())
    }

    async fn create_empty(&self, path: &str, add: bool) -> Result<Entry> {
        let mode = if add { "add" } else { "overwrite" };
        let arg = json!({
            "path": path,
            "mode": mode,
            "autorename": false,
            "mute": true
        });
        let resp = self
            .content(
                &format!("{CONTENT_BASE}/files/upload"),
                arg,
                None,
                Some(Vec::new()),
            )
            .await?;
        let body = resp.text().await.map_err(net_err)?;
        let entry: DbxEntry = serde_json::from_str(&body)
            .map_err(|e| VfsError::Network(format!("invalid upload response: {e}")))?;
        Ok(self.entry_of(entry))
    }
}

#[async_trait]
impl Backend for DropboxBackend {
    fn scheme(&self) -> &'static str {
        SCHEME
    }

    fn display_name(&self) -> String {
        "dropbox".to_string()
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities {
            can_list: true,
            can_read: true,
            can_write: true,
            can_create: true,
            can_rename: true,
            can_delete: true,
            can_seek: true,
            can_random_write: false,
            can_watch: false,
            native_thumbnails: false,
        }
    }

    async fn stat(&self, id: &str) -> Result<Entry> {
        let path = self.path_of(id)?;
        let arg = json!({ "path": path });
        let v = self
            .rpc(&format!("{RPC_BASE}/files/get_metadata"), arg)
            .await?;
        let entry: DbxEntry = serde_json::from_value(v)
            .map_err(|e| VfsError::Network(format!("invalid metadata: {e}")))?;
        Ok(self.entry_of(entry))
    }

    async fn list(&self, id: &str) -> Result<Vec<Entry>> {
        let path = self.path_of(id)?;
        let mut out = Vec::new();
        let mut cursor: Option<String> = None;
        loop {
            let (url, arg) = match &cursor {
                Some(cursor) => (
                    format!("{RPC_BASE}/files/list_folder/continue"),
                    json!({ "cursor": cursor }),
                ),
                None => (
                    format!("{RPC_BASE}/files/list_folder"),
                    json!({ "path": path, "limit": 2000 }),
                ),
            };
            let v = self.rpc(&url, arg).await?;
            let list: DbxList = serde_json::from_value(v)
                .map_err(|e| VfsError::Network(format!("invalid list response: {e}")))?;
            for entry in list.entries {
                out.push(self.entry_of(entry));
            }
            if list.has_more {
                cursor = list.cursor;
            } else {
                break;
            }
        }
        sort_entries(&mut out);
        Ok(out)
    }

    async fn create_dir(&self, parent: &str, name: &str) -> Result<Entry> {
        validate_name(name)?;
        let parent_path = self.path_of(parent)?;
        let path = join_path(&parent_path, name);
        let arg = json!({ "path": path, "autorename": false });
        let v = self
            .rpc(&format!("{RPC_BASE}/files/create_folder_v2"), arg)
            .await?;
        let meta = v
            .get("metadata")
            .cloned()
            .unwrap_or(serde_json::Value::Null);
        let entry: DbxEntry = serde_json::from_value(meta)
            .map_err(|e| VfsError::Network(format!("invalid create_folder response: {e}")))?;
        Ok(self.entry_of(entry))
    }

    async fn create_file(&self, parent: &str, name: &str) -> Result<Entry> {
        validate_name(name)?;
        let parent_path = self.path_of(parent)?;
        let path = join_path(&parent_path, name);
        self.create_empty(&path, true).await
    }

    async fn remove(&self, id: &str, recursive: bool) -> Result<()> {
        let path = self.path_of(id)?;
        if path.is_empty() {
            return Err(VfsError::PermissionDenied(
                "cannot delete the mount root".into(),
            ));
        }
        if !recursive {
            if let Ok(entry) = self.stat(id).await {
                if entry.is_dir() && !self.list(id).await?.is_empty() {
                    return Err(VfsError::Io(format!(
                        "directory not empty (pass recursive=true): {path}"
                    )));
                }
            }
        }
        let arg = json!({ "path": path });
        self.rpc(&format!("{RPC_BASE}/files/delete_v2"), arg)
            .await?;
        Ok(())
    }

    async fn rename(&self, id: &str, new_name: &str) -> Result<Entry> {
        validate_name(new_name)?;
        let from = self.path_of(id)?;
        if from.is_empty() {
            return Err(VfsError::PermissionDenied(
                "cannot rename the mount root".into(),
            ));
        }
        let parent = parent_path(&from);
        let to = join_path(&parent, new_name);
        let arg = json!({ "from_path": from, "to_path": to, "autorename": false });
        let v = self.rpc(&format!("{RPC_BASE}/files/move_v2"), arg).await?;
        let meta = v
            .get("metadata")
            .cloned()
            .unwrap_or(serde_json::Value::Null);
        let entry: DbxEntry = serde_json::from_value(meta)
            .map_err(|e| VfsError::Network(format!("invalid move response: {e}")))?;
        Ok(self.entry_of(entry))
    }

    async fn read_range(&self, id: &str, offset: u64, len: usize) -> Result<Vec<u8>> {
        if len == 0 {
            return Ok(Vec::new());
        }
        let path = self.path_of(id)?;
        let end = offset.saturating_add(len as u64).saturating_sub(1);
        let arg = json!({ "path": path });
        let resp = self
            .content(
                &format!("{CONTENT_BASE}/files/download"),
                arg,
                Some(format!("bytes={offset}-{end}")),
                None,
            )
            .await?;
        let status = resp.status().as_u16();
        match status {
            206 => {
                let mut bytes = resp.bytes().await.map_err(net_err)?.to_vec();
                bytes.truncate(len);
                Ok(bytes)
            }
            // Server ignored Range (unlikely for Dropbox): take the head.
            200 => {
                let mut bytes = resp.bytes().await.map_err(net_err)?.to_vec();
                bytes.truncate(len);
                Ok(bytes)
            }
            416 => Ok(Vec::new()),
            _ => Err(self.map_error(resp, &path).await),
        }
    }

    async fn write_range(&self, id: &str, offset: u64, data: &[u8]) -> Result<()> {
        let path = self.path_of(id)?;
        let (parent, name) = match path.rsplit_once('/') {
            Some((parent, name)) => (parent.to_string(), name.to_string()),
            None => {
                return Err(VfsError::Unsupported(
                    "cannot write at the mount root".into(),
                ))
            }
        };
        self.spool.write(id, offset, data, parent, name)
    }

    async fn truncate(&self, id: &str, size: u64) -> Result<()> {
        match self.spool.take(id) {
            Some(spool) => {
                let result = self.upload_spool(&spool, size).await;
                let _ = std::fs::remove_file(&spool.path);
                result
            }
            None => {
                let path = self.path_of(id)?;
                if path.is_empty() {
                    return Err(VfsError::PermissionDenied(
                        "cannot truncate the mount root".into(),
                    ));
                }
                Err(VfsError::Unsupported(format!(
                    "Dropbox has no in-place truncate: {path}"
                )))
            }
        }
    }

    async fn read_to_fd(
        &self,
        id: &str,
        fd: i32,
        offset: u64,
        cancel: &crate::cancel::CancelToken,
    ) -> Result<u64> {
        let path = self.path_of(id)?;
        let arg = json!({ "path": path });
        let range = if offset > 0 {
            Some(format!("bytes={offset}-"))
        } else {
            None
        };
        let mut resp = self
            .content(&format!("{CONTENT_BASE}/files/download"), arg, range, None)
            .await?;
        let mut skip = match resp.status().as_u16() {
            206 => 0,
            200 => offset,
            416 => return Ok(0),
            _ => return Ok(0),
        };
        let mut total = 0u64;
        while let Some(chunk) = resp.chunk().await.map_err(net_err)? {
            if cancel.is_cancelled() {
                return Err(VfsError::Cancelled);
            }
            let mut bytes: &[u8] = &chunk;
            while skip > 0 && !bytes.is_empty() {
                let n = (skip as usize).min(bytes.len());
                skip -= n as u64;
                bytes = &bytes[n..];
            }
            if bytes.is_empty() {
                continue;
            }
            crate::fd::write_all(fd, bytes).map_err(VfsError::io)?;
            total += bytes.len() as u64;
        }
        Ok(total)
    }
}

fn make_id(path: &str) -> String {
    if path.is_empty() {
        format!("{SCHEME}://root")
    } else {
        format!("{SCHEME}://root{path}")
    }
}

/// Dropbox path for a parent id ("" = root, else "/a").
fn parent_id(path: &str) -> Option<String> {
    if path.is_empty() {
        return None;
    }
    Some(make_id(&parent_path(path)))
}

fn parent_path(path: &str) -> String {
    match path.rfind('/') {
        Some(0) | None => String::new(),
        Some(idx) => path[..idx].to_string(),
    }
}

fn join_path(parent: &str, name: &str) -> String {
    if parent.is_empty() {
        format!("/{name}")
    } else {
        format!("{parent}/{name}")
    }
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

fn net_err(err: reqwest::Error) -> VfsError {
    VfsError::Network(err.to_string())
}

fn sort_entries(entries: &mut Vec<Entry>) {
    entries.sort_by(|a, b| {
        let a_dir = a.kind == EntryKind::Directory;
        let b_dir = b.kind == EntryKind::Directory;
        b_dir
            .cmp(&a_dir)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
}
