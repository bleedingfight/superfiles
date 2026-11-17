//! Box backend (Box Content API v2), file/folder-id based namespace.
//!
//! Protocol notes:
//!
//! * Box addresses items by opaque ids: an entry id is `box://<id>` and the
//!   account root is `box://0`.
//! * New files are spelled `box://<parentId>/<name>` (the transfer engine's
//!   `join(parent, name)`), recognised by the trailing `/`.
//! * Downloads accept `Range`. Writes spool locally and upload in `truncate`:
//!   new files use an upload session (streamed parts), overwrites use
//!   `POST /files/{id}/content` multipart with a known Content-Length.

use std::path::Path;
use std::sync::Arc;

use async_trait::async_trait;
use base64::Engine;
use futures_util::stream::{self, StreamExt};
use serde_json::json;
use sha1::{Digest, Sha1};

use crate::backend::Backend;
use crate::capabilities::Capabilities;
use crate::entry::{guess_mime, Entry, EntryKind};
use crate::error::{Result, VfsError};
use crate::uri::split_id;

use super::cloud::{self, parse_rfc3339_ms, CloudAuth, SpoolPool};

pub const SCHEME: &str = "box";
pub const ROOT_ID: &str = "0";

const API: &str = "https://api.box.com/2.0";
const UPLOAD: &str = "https://upload.box.com/api/2.0";
const FIELDS: &str = "id,type,name,size,modified_at,parent";

#[derive(Debug, serde::Deserialize)]
struct BoxParent {
    id: String,
}

#[derive(Debug, serde::Deserialize)]
struct BoxItem {
    id: String,
    #[serde(rename = "type")]
    kind: String,
    name: String,
    #[serde(default)]
    size: Option<u64>,
    #[serde(default)]
    modified_at: Option<String>,
    #[serde(default)]
    parent: Option<BoxParent>,
}

#[derive(Debug, serde::Deserialize)]
struct BoxList {
    #[serde(default)]
    entries: Vec<BoxItem>,
    #[serde(default)]
    limit: u64,
    #[serde(default)]
    total_count: u64,
}

#[derive(Debug, serde::Deserialize)]
struct BoxSessionEndpoints {
    upload_part: String,
    commit: String,
}

#[derive(Debug, serde::Deserialize)]
struct BoxSession {
    part_size: u64,
    total_parts: u64,
    session_endpoints: BoxSessionEndpoints,
}

#[derive(Debug, serde::Deserialize)]
struct BoxPartResponse {
    part: BoxPart,
}

#[derive(Debug, serde::Deserialize, serde::Serialize)]
struct BoxPart {
    part_id: String,
    offset: u64,
    size: u64,
}

pub struct BoxBackend {
    client: reqwest::Client,
    auth: CloudAuth,
    spool: Arc<SpoolPool>,
}

impl BoxBackend {
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
            "https://api.box.com/oauth2/token".to_string(),
        );
        Self {
            client,
            auth,
            spool: SpoolPool::new(),
        }
    }

    pub fn root_id(&self) -> String {
        make_id(ROOT_ID)
    }

    fn id_of(&self, id: &str) -> Result<String> {
        let (scheme, rest) = split_id(id);
        if scheme != SCHEME || rest.is_empty() {
            return Err(VfsError::Unsupported(format!(
                "box backend cannot handle {id}"
            )));
        }
        match rest.rsplit_once('/') {
            Some((parent, _)) => Ok(parent.to_string()),
            None => Ok(rest.to_string()),
        }
    }

    fn entry_of(&self, item: BoxItem) -> Entry {
        let is_dir = item.kind == "folder";
        let mime = if is_dir { None } else { guess_mime(&item.name) };
        Entry {
            id: make_id(&item.id),
            parent: item.parent.as_ref().map(|p| make_id(&p.id)),
            name: item.name,
            kind: if is_dir {
                EntryKind::Directory
            } else {
                EntryKind::File
            },
            size: if is_dir { 0 } else { item.size.unwrap_or(0) },
            modified_ms: item.modified_at.as_deref().and_then(parse_rfc3339_ms),
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

    async fn get_item(&self, id: &str) -> Result<BoxItem> {
        let raw = self.id_of(id)?;
        // Box has no polymorphic item endpoint; try file, then folder.
        let file_url = format!("{API}/files/{raw}?fields={FIELDS}");
        let resp = self.send(true, |c| c.get(&file_url)).await?;
        if resp.status().is_success() {
            return serde_json::from_str(&resp.text().await.map_err(net_err)?)
                .map_err(|e| VfsError::Network(format!("invalid Box JSON: {e}")));
        }
        let folder_url = format!("{API}/folders/{raw}?fields={FIELDS}");
        let resp = self.send(true, |c| c.get(&folder_url)).await?;
        if !resp.status().is_success() {
            return Err(self.map_status(resp.status(), id));
        }
        serde_json::from_str(&resp.text().await.map_err(net_err)?)
            .map_err(|e| VfsError::Network(format!("invalid Box JSON: {e}")))
    }

    /// Upload a brand-new file through an upload session (streams parts).
    async fn upload_new(&self, parent_id: &str, name: &str, file: &Path, size: u64) -> Result<()> {
        let resp = self
            .send(true, |c| {
                c.post(format!("{UPLOAD}/files/upload_sessions"))
                    .header(reqwest::header::CONTENT_TYPE, "application/json")
                    .body(
                        json!({
                            "folder_id": parent_id,
                            "file_size": size,
                            "file_name": name
                        })
                        .to_string(),
                    )
            })
            .await?;
        if !resp.status().is_success() {
            return Err(self.map_status(resp.status(), name));
        }
        let session: BoxSession = serde_json::from_str(&resp.text().await.map_err(net_err)?)
            .map_err(|e| VfsError::Network(format!("invalid Box session: {e}")))?;

        let part_size = session.part_size.max(1);
        use tokio::io::AsyncReadExt;
        let mut fh = tokio::fs::File::open(file).await.map_err(VfsError::io)?;
        let mut offset = 0u64;
        let mut parts: Vec<BoxPart> = Vec::new();
        let mut whole = Sha1::new();

        for _ in 0..session.total_parts.max(1) {
            if offset >= size {
                break;
            }
            let want = ((size - offset).min(part_size)) as usize;
            let mut buf = vec![0u8; want];
            let mut read = 0usize;
            while read < want {
                let n = fh.read(&mut buf[read..]).await.map_err(VfsError::io)?;
                if n == 0 {
                    break;
                }
                read += n;
            }
            if read == 0 {
                break;
            }
            whole.update(&buf[..read]);
            let end = offset + read as u64 - 1;
            let digest = b64_sha1(&buf[..read]);
            let resp = self
                .send(false, |c| {
                    c.put(&session.session_endpoints.upload_part)
                        .header("Digest", format!("sha={digest}"))
                        .header("Content-Range", format!("bytes {offset}-{end}/{size}"))
                        .body(buf[..read].to_vec())
                })
                .await?;
            if !resp.status().is_success() {
                return Err(self.map_status(resp.status(), name));
            }
            let part: BoxPartResponse = serde_json::from_str(&resp.text().await.map_err(net_err)?)
                .map_err(|e| VfsError::Network(format!("invalid Box part: {e}")))?;
            parts.push(part.part);
            offset += read as u64;
        }

        let digest = base64::engine::general_purpose::STANDARD.encode(whole.finalize());
        let resp = self
            .send(true, |c| {
                c.post(&session.session_endpoints.commit)
                    .header("Digest", format!("sha={digest}"))
                    .header(reqwest::header::CONTENT_TYPE, "application/json")
                    .body(
                        json!({
                            "parts": &parts,
                            "attributes": { "name": name }
                        })
                        .to_string(),
                    )
            })
            .await?;
        if !resp.status().is_success() {
            return Err(self.map_status(resp.status(), name));
        }
        Ok(())
    }

    /// Overwrite an existing file via the multipart "upload version" endpoint.
    async fn upload_version(
        &self,
        file_id: &str,
        name: &str,
        file: &Path,
        size: u64,
    ) -> Result<()> {
        let url = format!("{UPLOAD}/files/{file_id}/content");
        // The streamed body is consumed by reqwest, so the retry loop rebuilds
        // it instead of going through `send_with_auth`'s `Fn` closure.
        for attempt in 0..2 {
            let boundary = format!("----superfiles{}", std::process::id());
            let attrs = json!({ "name": name }).to_string();
            let head = format!(
                "--{boundary}\r\nContent-Disposition: form-data; name=\"attributes\"\r\nContent-Type: application/json\r\n\r\n{attrs}\r\n--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{name}\"\r\nContent-Type: application/octet-stream\r\n\r\n"
            );
            let tail = format!("\r\n--{boundary}--\r\n");
            let total = head.len() as u64 + size + tail.len() as u64;

            let fh = tokio::fs::File::open(file).await.map_err(VfsError::io)?;
            let body = reqwest::Body::wrap_stream(
                stream::iter(vec![Ok::<_, std::io::Error>(bytes::Bytes::from(head))])
                    .chain(tokio_util::io::ReaderStream::new(fh))
                    .chain(stream::iter(vec![Ok(bytes::Bytes::from(tail))])),
            );
            let resp = self
                .client
                .post(&url)
                .bearer_auth(self.auth.bearer())
                .header(
                    reqwest::header::CONTENT_TYPE,
                    format!("multipart/form-data; boundary={boundary}"),
                )
                .header(reqwest::header::CONTENT_LENGTH, total.to_string())
                .body(body)
                .send()
                .await
                .map_err(net_err)?;
            if resp.status().as_u16() == 401 && attempt == 0 {
                self.auth.refresh().await?;
                continue;
            }
            if !resp.status().is_success() {
                return Err(self.map_status(resp.status(), name));
            }
            return Ok(());
        }
        Err(VfsError::Network("Box upload failed after refresh".into()))
    }
}

#[async_trait]
impl Backend for BoxBackend {
    fn scheme(&self) -> &'static str {
        SCHEME
    }

    fn display_name(&self) -> String {
        "box".to_string()
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
        Ok(self.entry_of(self.get_item(id).await?))
    }

    async fn list(&self, id: &str) -> Result<Vec<Entry>> {
        let raw = self.id_of(id)?;
        let mut out = Vec::new();
        let mut offset = 0u64;
        loop {
            let url =
                format!("{API}/folders/{raw}/items?limit=1000&offset={offset}&fields={FIELDS}");
            let resp = self.send(true, |c| c.get(&url)).await?;
            if !resp.status().is_success() {
                return Err(self.map_status(resp.status(), id));
            }
            let page: BoxList = serde_json::from_str(&resp.text().await.map_err(net_err)?)
                .map_err(|e| VfsError::Network(format!("invalid Box JSON: {e}")))?;
            let count = page.entries.len() as u64;
            for item in page.entries {
                out.push(self.entry_of(item));
            }
            offset += count;
            if count == 0 || offset >= page.total_count {
                break;
            }
            let _ = page.limit;
        }
        sort_entries(&mut out);
        Ok(out)
    }

    async fn create_dir(&self, parent: &str, name: &str) -> Result<Entry> {
        validate_name(name)?;
        let parent_id = self.id_of(parent)?;
        let resp = self
            .send(true, |c| {
                c.post(format!("{API}/folders"))
                    .header(reqwest::header::CONTENT_TYPE, "application/json")
                    .body(json!({ "name": name, "parent": { "id": parent_id } }).to_string())
            })
            .await?;
        if !resp.status().is_success() {
            return Err(self.map_status(resp.status(), name));
        }
        let item: BoxItem = serde_json::from_str(&resp.text().await.map_err(net_err)?)
            .map_err(|e| VfsError::Network(format!("invalid Box JSON: {e}")))?;
        Ok(self.entry_of(item))
    }

    async fn create_file(&self, parent: &str, name: &str) -> Result<Entry> {
        validate_name(name)?;
        let parent_id = self.id_of(parent)?;
        // Box creates a zero-byte file through a multipart upload with no body.
        let boundary = format!("----superfiles{}", std::process::id());
        let attrs = json!({ "name": name, "parent": { "id": parent_id } }).to_string();
        let body = format!(
            "--{boundary}\r\nContent-Disposition: form-data; name=\"attributes\"\r\nContent-Type: application/json\r\n\r\n{attrs}\r\n--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{name}\"\r\nContent-Type: application/octet-stream\r\n\r\n\r\n--{boundary}--\r\n"
        );
        let resp = self
            .send(true, |c| {
                c.post(format!("{UPLOAD}/files/content"))
                    .header(
                        reqwest::header::CONTENT_TYPE,
                        format!("multipart/form-data; boundary={boundary}"),
                    )
                    .body(body.clone())
            })
            .await?;
        if !resp.status().is_success() {
            return Err(self.map_status(resp.status(), name));
        }
        let list: serde_json::Value = serde_json::from_str(&resp.text().await.map_err(net_err)?)
            .map_err(|e| VfsError::Network(format!("invalid Box JSON: {e}")))?;
        let item: BoxItem = serde_json::from_value(
            list.get("entries")
                .and_then(|e| e.get(0))
                .cloned()
                .ok_or_else(|| VfsError::Network("Box upload returned no entry".into()))?,
        )
        .map_err(|e| VfsError::Network(format!("invalid Box JSON: {e}")))?;
        Ok(self.entry_of(item))
    }

    async fn remove(&self, id: &str, recursive: bool) -> Result<()> {
        let raw = self.id_of(id)?;
        if raw == ROOT_ID {
            return Err(VfsError::PermissionDenied(
                "cannot delete the mount root".into(),
            ));
        }
        let item = self.get_item(id).await?;
        let url = if item.kind == "folder" {
            format!("{API}/folders/{raw}?recursive={}", recursive)
        } else {
            format!("{API}/files/{raw}")
        };
        let resp = self.send(true, |c| c.delete(&url)).await?;
        if !resp.status().is_success() && resp.status().as_u16() != 204 {
            return Err(self.map_status(resp.status(), id));
        }
        Ok(())
    }

    async fn rename(&self, id: &str, new_name: &str) -> Result<Entry> {
        validate_name(new_name)?;
        let raw = self.id_of(id)?;
        if raw == ROOT_ID {
            return Err(VfsError::PermissionDenied(
                "cannot rename the mount root".into(),
            ));
        }
        let item = self.get_item(id).await?;
        let path = if item.kind == "folder" {
            "folders"
        } else {
            "files"
        };
        let url = format!("{API}/{path}/{raw}");
        let resp = self
            .send(true, |c| {
                c.put(&url)
                    .header(reqwest::header::CONTENT_TYPE, "application/json")
                    .body(json!({ "name": new_name }).to_string())
            })
            .await?;
        if !resp.status().is_success() {
            return Err(self.map_status(resp.status(), id));
        }
        let item: BoxItem = serde_json::from_str(&resp.text().await.map_err(net_err)?)
            .map_err(|e| VfsError::Network(format!("invalid Box JSON: {e}")))?;
        Ok(self.entry_of(item))
    }

    async fn read_range(&self, id: &str, offset: u64, len: usize) -> Result<Vec<u8>> {
        if len == 0 {
            return Ok(Vec::new());
        }
        let raw = self.id_of(id)?;
        let end = offset.saturating_add(len as u64).saturating_sub(1);
        let url = format!("{API}/files/{raw}/content");
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
        let (scheme, rest) = split_id(id);
        if scheme != SCHEME {
            return Err(VfsError::Unsupported(format!(
                "box backend cannot handle {id}"
            )));
        }
        match rest.rsplit_once('/') {
            Some((parent, name)) if !name.is_empty() => {
                self.spool
                    .write(id, offset, data, parent.to_string(), name.to_string())
            }
            _ => {
                // Existing file id: resolve its parent + name for overwrite.
                let entry = self.stat(id).await?;
                let parent = entry
                    .parent
                    .as_deref()
                    .and_then(|p| self.id_of(p).ok())
                    .unwrap_or_else(|| ROOT_ID.to_string());
                self.spool.write(id, offset, data, parent, entry.name)
            }
        }
    }

    async fn truncate(&self, id: &str, size: u64) -> Result<()> {
        match self.spool.take(id) {
            Some(spool) => {
                let (scheme, rest) = split_id(id);
                let _ = scheme;
                let result = match rest.rsplit_once('/') {
                    Some((parent, name)) if !name.is_empty() => {
                        self.upload_new(parent, name, &spool.path, size).await
                    }
                    _ => {
                        let file_id = self.id_of(id)?;
                        self.upload_version(&file_id, &spool.name, &spool.path, size)
                            .await
                    }
                };
                let _ = std::fs::remove_file(&spool.path);
                result
            }
            None => Err(VfsError::Unsupported(format!(
                "Box has no in-place truncate: {id}"
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
        let raw = self.id_of(id)?;
        let url = format!("{API}/files/{raw}/content");
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

fn make_id(id: &str) -> String {
    format!("{SCHEME}://{id}")
}

fn b64_sha1(data: &[u8]) -> String {
    let digest = Sha1::digest(data);
    base64::engine::general_purpose::STANDARD.encode(digest)
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
