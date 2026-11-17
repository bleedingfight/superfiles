//! OneDrive backend (Microsoft Graph v1.0), path-based namespace.
//!
//! Protocol notes:
//!
//! * Graph is path-addressable: `/me/drive/root:/a/b` for items and
//!   `/me/drive/root:/a/b:/children` for listings, so an entry id maps 1:1 to
//!   a path (`onedrive://root/a/b`).
//! * Downloads accept `Range`; random writes do not exist, so `write_range`
//!   spools to a local temp file and `truncate` uploads it (simple PUT under
//!   4 MiB, resumable upload session above that).
//! * OAuth uses the Microsoft identity platform (`common` tenant); the caller
//!   passes client_id/client_secret + refresh_token, and [`CloudAuth`] mints
//!   new access tokens on 401.

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

pub const SCHEME: &str = "onedrive";
pub const ROOT_ID: &str = "root";

const GRAPH: &str = "https://graph.microsoft.com/v1.0";
/// Graph simple upload ceiling; above this we open an upload session.
const SIMPLE_UPLOAD_LIMIT: u64 = 4 * 1024 * 1024;
const UPLOAD_CHUNK: usize = 8 * 1024 * 1024;

const SELECT: &str = "$select=id,name,size,lastModifiedDateTime,folder,file,parentReference";

#[derive(Debug, serde::Deserialize)]
struct OdFile {
    #[serde(default, rename = "mimeType")]
    mime_type: Option<String>,
}

#[derive(Debug, serde::Deserialize)]
struct OdItem {
    id: String,
    name: String,
    #[serde(default)]
    size: Option<u64>,
    #[serde(default, rename = "lastModifiedDateTime")]
    modified: Option<String>,
    /// Present on folders; value unused.
    #[serde(default)]
    folder: Option<serde_json::Value>,
    #[serde(default)]
    file: Option<OdFile>,
}

#[derive(Debug, serde::Deserialize)]
struct OdList {
    #[serde(default)]
    value: Vec<OdItem>,
    #[serde(default, rename = "@odata.nextLink")]
    next: Option<String>,
}

/// One OneDrive mount (single account). Mount via [`crate::Vfs::mount_at`].
pub struct OneDriveBackend {
    client: reqwest::Client,
    auth: CloudAuth,
    spool: Arc<SpoolPool>,
}

impl OneDriveBackend {
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
            "https://login.microsoftonline.com/common/oauth2/v2.0/token".to_string(),
        );
        Self {
            client,
            auth,
            spool: SpoolPool::new(),
        }
    }

    pub fn root_id(&self) -> String {
        make_id("")
    }

    fn path_of(&self, id: &str) -> Result<String> {
        let (scheme, rest) = split_id(id);
        if scheme != SCHEME {
            return Err(VfsError::Unsupported(format!(
                "onedrive backend cannot handle {id}"
            )));
        }
        if rest == ROOT_ID {
            return Ok(String::new());
        }
        match rest.strip_prefix("root/") {
            Some(path) if !path.is_empty() => Ok(path.to_string()),
            _ => Err(VfsError::Unsupported(format!("bad onedrive id: {id}"))),
        }
    }

    fn entry_of(&self, path: &str, item: OdItem) -> Entry {
        let is_dir = item.folder.is_some();
        let mime = if is_dir {
            None
        } else {
            item.file
                .as_ref()
                .and_then(|f| f.mime_type.clone())
                .or_else(|| guess_mime(&item.name))
        };
        Entry {
            id: make_id(path),
            parent: Some(make_id(parent_path(path))),
            name: item.name,
            kind: if is_dir {
                EntryKind::Directory
            } else {
                EntryKind::File
            },
            size: if is_dir { 0 } else { item.size.unwrap_or(0) },
            modified_ms: item.modified.as_deref().and_then(parse_rfc3339_ms),
            mime,
            hidden: false,
            readonly: false,
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

    async fn get_item(&self, path: &str) -> Result<OdItem> {
        let url = format!("{}?{SELECT}", item_url(path));
        let resp = self.send(true, |c| c.get(&url)).await?;
        if !resp.status().is_success() {
            return Err(self.map_status(resp.status(), path));
        }
        serde_json::from_str(&resp.text().await.map_err(net_err)?)
            .map_err(|e| VfsError::Network(format!("invalid Graph JSON: {e}")))
    }

    /// Upload a spool file to `path` (creating or replacing the item there).
    async fn upload_path(&self, path: &str, file: &Path, size: u64) -> Result<()> {
        let base = item_url(path);
        if size <= SIMPLE_UPLOAD_LIMIT {
            let body = tokio::fs::read(file).await.map_err(VfsError::io)?;
            let url = format!("{base}:/content");
            let resp = self.send(true, |c| c.put(&url).body(body.clone())).await?;
            if !resp.status().is_success() {
                return Err(self.map_status(resp.status(), path));
            }
            return Ok(());
        }

        // Resumable upload session: create, then PUT sequential chunks.
        let url = format!("{base}:/createUploadSession");
        let resp = self
            .send(true, |c| {
                c.post(&url)
                    .header(reqwest::header::CONTENT_TYPE, "application/json")
                    .body(
                        json!({"item": {"@microsoft.graph.conflictBehavior": "replace"}})
                            .to_string(),
                    )
            })
            .await?;
        if !resp.status().is_success() {
            return Err(self.map_status(resp.status(), path));
        }
        let v: serde_json::Value = serde_json::from_str(&resp.text().await.map_err(net_err)?)
            .map_err(|e| VfsError::Network(format!("invalid upload session: {e}")))?;
        let upload_url = v
            .get("uploadUrl")
            .and_then(|u| u.as_str())
            .ok_or_else(|| VfsError::Network("upload session missing uploadUrl".into()))?
            .to_string();

        use tokio::io::AsyncReadExt;
        let mut fh = tokio::fs::File::open(file).await.map_err(VfsError::io)?;
        let mut offset = 0u64;
        let mut buf = vec![0u8; UPLOAD_CHUNK];
        while offset < size {
            let want = ((size - offset) as usize).min(buf.len());
            let n = fh.read(&mut buf[..want]).await.map_err(VfsError::io)?;
            if n == 0 {
                break;
            }
            let end = offset + n as u64 - 1;
            // The session URL is pre-authenticated; do not attach the bearer.
            let resp = self
                .client
                .put(&upload_url)
                .header("Content-Range", format!("bytes {offset}-{end}/{size}"))
                .body(buf[..n].to_vec())
                .send()
                .await
                .map_err(net_err)?;
            let status = resp.status();
            if !(status.is_success() || status.as_u16() == 202) {
                return Err(self.map_status(status, path));
            }
            offset += n as u64;
        }
        Ok(())
    }

    async fn find_upload_target(&self, id: &str) -> Result<(String, String)> {
        // `parent/name` = a not-yet-created item; otherwise resolve the item.
        let rest = self.path_of(id)?;
        if let Some((parent, name)) = rest.rsplit_once('/') {
            if !name.is_empty() {
                return Ok((format!("{parent}/{name}"), name.to_string()));
            }
        }
        let item = self.get_item(&rest).await?;
        Ok((rest, item.name))
    }
}

#[async_trait]
impl Backend for OneDriveBackend {
    fn scheme(&self) -> &'static str {
        SCHEME
    }

    fn display_name(&self) -> String {
        "onedrive".to_string()
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
        let item = self.get_item(&path).await?;
        Ok(self.entry_of(&path, item))
    }

    async fn list(&self, id: &str) -> Result<Vec<Entry>> {
        let path = self.path_of(id)?;
        let mut url = format!("{}?{SELECT}&$top=200", children_url(&path));
        let mut out = Vec::new();
        loop {
            let resp = self.send(true, |c| c.get(&url)).await?;
            if !resp.status().is_success() {
                return Err(self.map_status(resp.status(), id));
            }
            let page: OdList = serde_json::from_str(&resp.text().await.map_err(net_err)?)
                .map_err(|e| VfsError::Network(format!("invalid Graph JSON: {e}")))?;
            for item in page.value {
                out.push(self.entry_of(&join_path(&path, &item.name), item));
            }
            match page.next {
                Some(next) if !next.is_empty() => url = next,
                _ => break,
            }
        }
        sort_entries(&mut out);
        Ok(out)
    }

    async fn create_dir(&self, parent: &str, name: &str) -> Result<Entry> {
        validate_name(name)?;
        let parent_path = self.path_of(parent)?;
        let url = children_url(&parent_path);
        let resp = self
            .send(true, |c| {
                c.post(&url)
                    .header(reqwest::header::CONTENT_TYPE, "application/json")
                    .body(
                        json!({
                            "name": name,
                            "folder": {},
                            "@microsoft.graph.conflictBehavior": "rename"
                        })
                        .to_string(),
                    )
            })
            .await?;
        if !resp.status().is_success() {
            return Err(self.map_status(resp.status(), name));
        }
        let item: OdItem = serde_json::from_str(&resp.text().await.map_err(net_err)?)
            .map_err(|e| VfsError::Network(format!("invalid Graph JSON: {e}")))?;
        let path = join_path(&parent_path, &item.name);
        Ok(self.entry_of(&path, item))
    }

    async fn create_file(&self, parent: &str, name: &str) -> Result<Entry> {
        validate_name(name)?;
        let parent_path = self.path_of(parent)?;
        let path = join_path(&parent_path, name);
        let url = format!("{}:/content", item_url(&path));
        let resp = self.send(true, |c| c.put(&url).body(Vec::new())).await?;
        if !resp.status().is_success() {
            return Err(self.map_status(resp.status(), name));
        }
        let item: OdItem = serde_json::from_str(&resp.text().await.map_err(net_err)?)
            .map_err(|e| VfsError::Network(format!("invalid Graph JSON: {e}")))?;
        Ok(self.entry_of(&path, item))
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
        let item = self.get_item(&path).await?;
        let url = format!("{GRAPH}/me/drive/items/{}", item.id);
        let resp = self.send(true, |c| c.delete(&url)).await?;
        if !resp.status().is_success() && resp.status().as_u16() != 204 {
            return Err(self.map_status(resp.status(), id));
        }
        Ok(())
    }

    async fn rename(&self, id: &str, new_name: &str) -> Result<Entry> {
        validate_name(new_name)?;
        let path = self.path_of(id)?;
        if path.is_empty() {
            return Err(VfsError::PermissionDenied(
                "cannot rename the mount root".into(),
            ));
        }
        let item = self.get_item(&path).await?;
        let url = format!("{GRAPH}/me/drive/items/{}", item.id);
        let resp = self
            .send(true, |c| {
                c.patch(&url)
                    .header(reqwest::header::CONTENT_TYPE, "application/json")
                    .body(json!({ "name": new_name }).to_string())
            })
            .await?;
        if !resp.status().is_success() {
            return Err(self.map_status(resp.status(), id));
        }
        let item: OdItem = serde_json::from_str(&resp.text().await.map_err(net_err)?)
            .map_err(|e| VfsError::Network(format!("invalid Graph JSON: {e}")))?;
        let new_path = join_path(parent_path(&path), &item.name);
        Ok(self.entry_of(&new_path, item))
    }

    async fn read_range(&self, id: &str, offset: u64, len: usize) -> Result<Vec<u8>> {
        if len == 0 {
            return Ok(Vec::new());
        }
        let path = self.path_of(id)?;
        if path.is_empty() {
            return Err(VfsError::Unsupported("onedrive root has no content".into()));
        }
        let end = offset.saturating_add(len as u64).saturating_sub(1);
        let url = format!("{}:/content", item_url(&path));
        let resp = self
            .send(true, |c| {
                c.get(&url)
                    .header(reqwest::header::RANGE, format!("bytes={offset}-{end}"))
            })
            .await?;
        match resp.status().as_u16() {
            200 | 206 => {
                let mut bytes = resp.bytes().await.map_err(net_err)?.to_vec();
                bytes.truncate(len);
                Ok(bytes)
            }
            416 => Ok(Vec::new()),
            _ => Err(self.map_status(resp.status(), id)),
        }
    }

    async fn write_range(&self, id: &str, offset: u64, data: &[u8]) -> Result<()> {
        let (path, name) = self.find_upload_target(id).await?;
        self.spool
            .write(id, offset, data, make_id(parent_path(&path)), name)
    }

    async fn truncate(&self, id: &str, size: u64) -> Result<()> {
        match self.spool.take(id) {
            Some(spool) => {
                let parent_path = self.path_of(&spool.parent)?;
                let path = join_path(&parent_path, &spool.name);
                let result = self.upload_path(&path, &spool.path, size).await;
                let _ = std::fs::remove_file(&spool.path);
                result
            }
            None => Err(VfsError::Unsupported(format!(
                "OneDrive has no in-place truncate: {id}"
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
        let path = self.path_of(id)?;
        if path.is_empty() {
            return Ok(0);
        }
        let url = format!("{}:/content", item_url(&path));
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

// ---------------------------------------------------------------- helpers

fn make_id(path: &str) -> String {
    if path.is_empty() {
        format!("{SCHEME}://{ROOT_ID}")
    } else {
        format!("{SCHEME}://{ROOT_ID}/{path}")
    }
}

fn parent_path(path: &str) -> &str {
    path.rsplit_once('/').map(|(p, _)| p).unwrap_or("")
}

fn join_path(parent: &str, name: &str) -> String {
    if parent.is_empty() {
        name.to_string()
    } else {
        format!("{parent}/{name}")
    }
}

fn encode_path(path: &str) -> String {
    path.split('/')
        .map(|seg| {
            percent_encoding::utf8_percent_encode(seg, percent_encoding::NON_ALPHANUMERIC)
                .to_string()
        })
        .collect::<Vec<_>>()
        .join("/")
}

fn item_url(path: &str) -> String {
    if path.is_empty() {
        format!("{GRAPH}/me/drive/root")
    } else {
        format!("{GRAPH}/me/drive/root:/{}", encode_path(path))
    }
}

fn children_url(path: &str) -> String {
    if path.is_empty() {
        format!("{GRAPH}/me/drive/root/children")
    } else {
        format!("{}:/children", item_url(path))
    }
}

fn validate_name(name: &str) -> Result<()> {
    let invalid = name.is_empty()
        || name == "."
        || name == ".."
        || name.contains('/')
        || name.contains('\\')
        || name.contains('\0')
        || name.contains(':')
        || name.contains('*')
        || name.contains('?')
        || name.contains('"')
        || name.contains('<')
        || name.contains('>')
        || name.contains('|');
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
