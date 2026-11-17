//! Google Drive backend (Drive API v3), file-id based namespace.
//!
//! Protocol notes:
//!
//! * Drive addresses files by opaque ids, not paths, so an entry id is
//!   `gdrive://<fileId>` (the "My Drive" root is the pseudo-id `root`).
//! * Because the transfer engine builds *target* ids with [`crate::Vfs::join`],
//!   a not-yet-created file is spelled `gdrive://<parentFileId>/<name>`; the
//!   write path recognises the trailing `/` and resolves (parent, name).
//! * Downloads (`files.get?alt=media`) support `Range` (206). Random writes do
//!   not exist: `write_range` spools to a local temp file and `truncate`
//!   uploads it whole through a resumable upload session.

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

pub const SCHEME: &str = "gdrive";
pub const ROOT_ID: &str = "root";

const API_BASE: &str = "https://www.googleapis.com/drive/v3";
const UPLOAD_BASE: &str = "https://www.googleapis.com/upload/drive/v3";

const FOLDER_MIME: &str = "application/vnd.google-apps.folder";

#[derive(Debug, serde::Deserialize)]
struct DriveFile {
    id: String,
    name: String,
    #[serde(default)]
    mime_type: Option<String>,
    #[serde(default)]
    size: Option<String>,
    #[serde(default)]
    modified_time: Option<String>,
    #[serde(default)]
    parents: Option<Vec<String>>,
}

#[derive(Debug, serde::Deserialize)]
struct DriveList {
    #[serde(default)]
    next_page_token: Option<String>,
    #[serde(default)]
    files: Vec<DriveFile>,
}

/// A single Google Drive mount (one account). Mount it via [`crate::Vfs::mount_at`].
pub struct GoogleDriveBackend {
    client: reqwest::Client,
    auth: CloudAuth,
    spool: Arc<SpoolPool>,
}

impl GoogleDriveBackend {
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
            "https://oauth2.googleapis.com/token".to_string(),
        );
        Self {
            client,
            auth,
            spool: SpoolPool::new(),
        }
    }

    /// Canonical id of the mount root: `gdrive://root`.
    pub fn root_id(&self) -> String {
        make_id(ROOT_ID)
    }

    /// Raw file id (or `root`, or a synthetic `parent/name`) for a backend id.
    fn file_id_of(&self, id: &str) -> Result<String> {
        let (scheme, rest) = split_id(id);
        if scheme != SCHEME {
            return Err(VfsError::Unsupported(format!(
                "gdrive backend cannot handle {id}"
            )));
        }
        Ok(rest.to_string())
    }

    fn entry_of(&self, file: DriveFile) -> Entry {
        let is_dir = file.mime_type.as_deref() == Some(FOLDER_MIME);
        let is_native = file
            .mime_type
            .as_deref()
            .map(|m| m.starts_with("application/vnd.google-apps") && !is_dir)
            .unwrap_or(false);
        let kind = if is_dir {
            EntryKind::Directory
        } else {
            EntryKind::File
        };
        let mime = if kind == EntryKind::File && !is_native {
            guess_mime(&file.name)
        } else {
            None
        };
        Entry {
            id: make_id(&file.id),
            parent: file
                .parents
                .as_ref()
                .and_then(|p| p.first())
                .map(|p| make_id(p)),
            name: file.name,
            kind,
            size: if is_dir {
                0
            } else {
                file.size.and_then(|s| s.parse().ok()).unwrap_or(0)
            },
            modified_ms: file.modified_time.as_deref().and_then(parse_rfc3339_ms),
            mime,
            hidden: false,
            readonly: is_native,
        }
    }

    async fn send(
        &self,
        retry: bool,
        build: impl Fn(&reqwest::Client) -> reqwest::RequestBuilder,
    ) -> Result<reqwest::Response> {
        cloud::send_with_auth(&self.client, &self.auth, retry, build).await
    }

    fn map_status(&self, status: reqwest::StatusCode, id: &str) -> VfsError {
        match status.as_u16() {
            401 | 403 => VfsError::PermissionDenied(format!("{id} (HTTP {status})")),
            404 => VfsError::NotFound(id.to_string()),
            409 => VfsError::AlreadyExists(id.to_string()),
            s if s >= 500 => VfsError::Network(format!("{id}: HTTP {s}")),
            s => VfsError::Io(format!("{id}: HTTP {s}")),
        }
    }

    fn list_query(parent: &str, page_token: Option<&str>) -> String {
        let q = format!("'{parent}' in parents and trashed=false");
        let q = percent_encoding::utf8_percent_encode(&q, percent_encoding::NON_ALPHANUMERIC);
        let mut url = format!(
            "{API_BASE}/files?q={q}&fields=nextPageToken,files(id,name,mimeType,size,modifiedTime,trashed,parents)&pageSize=1000&includeItemsFromAllDrives=true&supportsAllDrives=true"
        );
        if let Some(token) = page_token {
            url.push_str("&pageToken=");
            url.push_str(token);
        }
        url
    }

    async fn find_by_name(&self, parent: &str, name: &str) -> Result<Option<String>> {
        let escaped = name.replace('\\', "\\\\").replace('\'', "\\'");
        let q = format!("'{parent}' in parents and name='{escaped}' and trashed=false");
        let q = percent_encoding::utf8_percent_encode(&q, percent_encoding::NON_ALPHANUMERIC);
        let url = format!(
            "{API_BASE}/files?q={q}&fields=files(id)&pageSize=2&includeItemsFromAllDrives=true&supportsAllDrives=true"
        );
        let resp = self.send(true, |c| c.get(&url)).await?;
        if !resp.status().is_success() {
            return Err(self.map_status(resp.status(), name));
        }
        let list: DriveList = serde_json::from_str(&resp.text().await.map_err(net_err)?)
            .map_err(|e| VfsError::Network(format!("invalid Drive JSON: {e}")))?;
        Ok(list.files.into_iter().next().map(|f| f.id))
    }

    async fn upload_spool(&self, spool: &super::cloud::Spool, size: u64) -> Result<()> {
        let existing = self.find_by_name(&spool.parent, &spool.name).await?;
        let session = match &existing {
            Some(file_id) => {
                // Replace content of an existing file.
                let url =
                    format!("{UPLOAD_BASE}/{file_id}?uploadType=resumable&supportsAllDrives=true");
                let resp = self
                    .send(true, |c| {
                        c.post(&url)
                            .header("X-Upload-Content-Type", "application/octet-stream")
                            .header("X-Upload-Content-Length", size.to_string())
                    })
                    .await?;
                if !resp.status().is_success() {
                    return Err(self.map_status(resp.status(), &spool.name));
                }
                self.session_url(resp)?
            }
            None => {
                let url = format!("{UPLOAD_BASE}?uploadType=resumable&supportsAllDrives=true");
                let metadata = json!({
                    "name": spool.name,
                    "parents": [spool.parent]
                });
                let resp = self
                    .send(true, |c| {
                        c.post(&url)
                            .header(reqwest::header::CONTENT_TYPE, "application/json")
                            .header("X-Upload-Content-Type", "application/octet-stream")
                            .header("X-Upload-Content-Length", size.to_string())
                            .body(metadata.to_string())
                    })
                    .await?;
                if !resp.status().is_success() {
                    return Err(self.map_status(resp.status(), &spool.name));
                }
                self.session_url(resp)?
            }
        };
        self.resumable_upload(&session, &spool.path, size).await
    }

    fn session_url(&self, resp: reqwest::Response) -> Result<String> {
        resp.headers()
            .get(reqwest::header::LOCATION)
            .and_then(|v| v.to_str().ok())
            .map(String::from)
            .ok_or_else(|| VfsError::Network("resumable upload missing Location".into()))
    }

    async fn resumable_upload(&self, session: &str, path: &Path, size: u64) -> Result<()> {
        use tokio::io::AsyncReadExt;
        if size == 0 {
            let resp = self
                .send(false, |c| {
                    c.request(reqwest::Method::PUT, session).body(Vec::new())
                })
                .await?;
            if !resp.status().is_success() {
                return Err(self.map_status(resp.status(), session));
            }
            return Ok(());
        }
        let mut file = tokio::fs::File::open(path).await.map_err(VfsError::io)?;
        let mut offset = 0u64;
        let mut buf = vec![0u8; cloud::UPLOAD_CHUNK];
        while offset < size {
            let want = ((size - offset) as usize).min(buf.len());
            let n = file.read(&mut buf[..want]).await.map_err(VfsError::io)?;
            if n == 0 {
                break;
            }
            let end = offset + n as u64 - 1;
            let resp = self
                .send(false, |c| {
                    c.request(reqwest::Method::PUT, session)
                        .header("Content-Range", format!("bytes {offset}-{end}/{size}"))
                        .body(buf[..n].to_vec())
                })
                .await?;
            let status = resp.status();
            // 308 = resume incomplete; 200/201 = finished. A single chunk may
            // carry the whole file, so a 200 here is expected.
            if !(status.is_success() || status.as_u16() == 308) {
                return Err(self.map_status(status, session));
            }
            offset += n as u64;
        }
        Ok(())
    }
}

#[async_trait]
impl Backend for GoogleDriveBackend {
    fn scheme(&self) -> &'static str {
        SCHEME
    }

    fn display_name(&self) -> String {
        "google drive".to_string()
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
        let file_id = self.file_id_of(id)?;
        let url = format!(
            "{API_BASE}/files/{file_id}?fields=id,name,mimeType,size,modifiedTime,trashed,parents&supportsAllDrives=true"
        );
        let resp = self.send(true, |c| c.get(&url)).await?;
        if !resp.status().is_success() {
            return Err(self.map_status(resp.status(), id));
        }
        let file: DriveFile = serde_json::from_str(&resp.text().await.map_err(net_err)?)
            .map_err(|e| VfsError::Network(format!("invalid Drive JSON: {e}")))?;
        Ok(self.entry_of(file))
    }

    async fn list(&self, id: &str) -> Result<Vec<Entry>> {
        let file_id = self.file_id_of(id)?;
        let mut out = Vec::new();
        let mut page_token: Option<String> = None;
        loop {
            let url = Self::list_query(&file_id, page_token.as_deref());
            let resp = self.send(true, |c| c.get(&url)).await?;
            if !resp.status().is_success() {
                return Err(self.map_status(resp.status(), id));
            }
            let list: DriveList = serde_json::from_str(&resp.text().await.map_err(net_err)?)
                .map_err(|e| VfsError::Network(format!("invalid Drive JSON: {e}")))?;
            for file in list.files {
                out.push(self.entry_of(file));
            }
            match list.next_page_token {
                Some(token) if !token.is_empty() => page_token = Some(token),
                _ => break,
            }
        }
        sort_entries(&mut out);
        Ok(out)
    }

    async fn create_dir(&self, parent: &str, name: &str) -> Result<Entry> {
        validate_name(name)?;
        let parent_id = self.file_id_of(parent)?;
        let metadata = json!({
            "name": name,
            "mimeType": FOLDER_MIME,
            "parents": [parent_id]
        });
        let url = format!("{API_BASE}/files?supportsAllDrives=true");
        let resp = self
            .send(true, |c| {
                c.post(&url)
                    .header(reqwest::header::CONTENT_TYPE, "application/json")
                    .body(metadata.to_string())
            })
            .await?;
        if !resp.status().is_success() {
            return Err(self.map_status(resp.status(), name));
        }
        let file: DriveFile = serde_json::from_str(&resp.text().await.map_err(net_err)?)
            .map_err(|e| VfsError::Network(format!("invalid Drive JSON: {e}")))?;
        Ok(self.entry_of(file))
    }

    async fn create_file(&self, parent: &str, name: &str) -> Result<Entry> {
        validate_name(name)?;
        let parent_id = self.file_id_of(parent)?;
        let metadata = json!({
            "name": name,
            "parents": [parent_id]
        });
        let url = format!("{API_BASE}/files?supportsAllDrives=true");
        let resp = self
            .send(true, |c| {
                c.post(&url)
                    .header(reqwest::header::CONTENT_TYPE, "application/json")
                    .body(metadata.to_string())
            })
            .await?;
        if !resp.status().is_success() {
            return Err(self.map_status(resp.status(), name));
        }
        let file: DriveFile = serde_json::from_str(&resp.text().await.map_err(net_err)?)
            .map_err(|e| VfsError::Network(format!("invalid Drive JSON: {e}")))?;
        Ok(self.entry_of(file))
    }

    async fn remove(&self, id: &str, recursive: bool) -> Result<()> {
        let file_id = self.file_id_of(id)?;
        if file_id == ROOT_ID {
            return Err(VfsError::PermissionDenied(
                "cannot delete the mount root".into(),
            ));
        }
        if !recursive {
            if let Ok(entry) = self.stat(id).await {
                if entry.is_dir() && !self.list(id).await?.is_empty() {
                    return Err(VfsError::Io(format!(
                        "directory not empty (pass recursive=true): {file_id}"
                    )));
                }
            }
        }
        let url = format!("{API_BASE}/files/{file_id}?supportsAllDrives=true");
        let resp = self.send(true, |c| c.delete(&url)).await?;
        if !resp.status().is_success() && resp.status().as_u16() != 204 {
            return Err(self.map_status(resp.status(), id));
        }
        Ok(())
    }

    async fn rename(&self, id: &str, new_name: &str) -> Result<Entry> {
        validate_name(new_name)?;
        let file_id = self.file_id_of(id)?;
        if file_id == ROOT_ID {
            return Err(VfsError::PermissionDenied(
                "cannot rename the mount root".into(),
            ));
        }
        let url = format!("{API_BASE}/files/{file_id}?supportsAllDrives=true");
        let metadata = json!({ "name": new_name });
        let resp = self
            .send(true, |c| {
                c.request(reqwest::Method::PATCH, &url)
                    .header(reqwest::header::CONTENT_TYPE, "application/json")
                    .body(metadata.to_string())
            })
            .await?;
        if !resp.status().is_success() {
            return Err(self.map_status(resp.status(), id));
        }
        let file: DriveFile = serde_json::from_str(&resp.text().await.map_err(net_err)?)
            .map_err(|e| VfsError::Network(format!("invalid Drive JSON: {e}")))?;
        Ok(self.entry_of(file))
    }

    async fn read_range(&self, id: &str, offset: u64, len: usize) -> Result<Vec<u8>> {
        if len == 0 {
            return Ok(Vec::new());
        }
        let file_id = self.file_id_of(id)?;
        let end = offset.saturating_add(len as u64).saturating_sub(1);
        let url = format!("{API_BASE}/files/{file_id}?alt=media&supportsAllDrives=true");
        let resp = self
            .send(true, |c| {
                c.get(&url)
                    .header(reqwest::header::RANGE, format!("bytes={offset}-{end}"))
            })
            .await?;
        let status = resp.status().as_u16();
        match status {
            206 => {
                let mut bytes = resp.bytes().await.map_err(net_err)?.to_vec();
                bytes.truncate(len);
                Ok(bytes)
            }
            200 => {
                let mut bytes = resp.bytes().await.map_err(net_err)?.to_vec();
                bytes.truncate(len);
                Ok(bytes)
            }
            416 => Ok(Vec::new()),
            _ => Err(self.map_status(resp.status(), id)),
        }
    }

    async fn write_range(&self, id: &str, offset: u64, data: &[u8]) -> Result<()> {
        let rest = self.file_id_of(id)?;
        let (parent, name) = match rest.rsplit_once('/') {
            Some((parent, name)) => (parent.to_string(), name.to_string()),
            None => {
                // A real file id: resolve its parent + name for overwrite.
                let entry = self.stat(id).await?;
                let parent = entry
                    .parent
                    .and_then(|p| self.file_id_of(&p).ok())
                    .unwrap_or_else(|| ROOT_ID.to_string());
                (parent, entry.name)
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
            None => Err(VfsError::Unsupported(format!(
                "Google Drive has no in-place truncate: {id}"
            ))),
        }
    }

    async fn read_to_fd(
        &self,
        id: &str,
        fd: i32,
        offset: u64,
        cancel: &crate::cancel::CancelToken,
    ) -> Result<u64> {
        let file_id = self.file_id_of(id)?;
        let url = format!("{API_BASE}/files/{file_id}?alt=media&supportsAllDrives=true");
        let mut resp = self
            .send(true, |c| {
                let req = c.get(&url);
                if offset > 0 {
                    req.header(reqwest::header::RANGE, format!("bytes={offset}-"))
                } else {
                    req
                }
            })
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

fn make_id(file_id: &str) -> String {
    format!("{SCHEME}://{file_id}")
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
