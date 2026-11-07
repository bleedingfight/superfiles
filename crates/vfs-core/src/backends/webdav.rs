//! WebDAV backend (RFC 4918), targeting SabreDAV style servers: Nextcloud,
//! ownCloud, Synology WebDAV Server, QNAP.
//!
//! Protocol notes:
//!
//! * Browsing is `PROPFIND` (depth 0 / 1), content transfer is ranged `GET`
//!   and `PUT`.
//! * Random writes have no standard verb. SabreDAV implements `PATCH` with
//!   `X-Update-Range` (sabredav-partialupdate) and/or `PUT` with
//!   `Content-Range`; the backend probes both once, remembers the winner, and
//!   reports [`VfsError::Unsupported`] on servers that have neither (plain
//!   Apache mod_dav / nginx) instead of silently corrupting files.
//! * There is no truncate verb. Shrinking falls back to re-PUT of the head;
//!   with the transfer engine's sequential writes the final `truncate` call is
//!   always a no-op because each chunk already replaced/extended the file.

mod url;
mod xml;

use std::sync::atomic::{AtomicU8, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use reqwest::header;
use reqwest::{Method, RequestBuilder, Response, StatusCode};

use crate::backend::Backend;
use crate::capabilities::Capabilities;
use crate::entry::{guess_mime, Entry, EntryKind};
use crate::error::{Result, VfsError};

use self::url::{dav_parent, make_id, resolve_id, RootUrl};
use self::xml::{parse_multistatus, DavResponse};

pub const SCHEME: &str = "webdav";

const PROPFIND_BODY: &str = r#"<?xml version="1.0" encoding="utf-8"?>
<D:propfind xmlns:D="DAV:">
  <D:prop>
    <D:resourcetype/>
    <D:getcontentlength/>
    <D:getlastmodified/>
    <D:getcontenttype/>
  </D:prop>
</D:propfind>"#;

const MAX_ATTEMPTS: u32 = 3;

/// How to authenticate against the server.
#[derive(Debug, Clone)]
pub enum WebdavAuth {
    None,
    Basic { username: String, password: String },
    Bearer(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PartialMode {
    /// Not probed yet.
    Unknown = 0,
    /// SabreDAV partial update: PATCH + `X-Update-Range`.
    Patch = 1,
    /// PUT with `Content-Range`.
    ContentRangePut = 2,
}

impl PartialMode {
    fn from_u8(v: u8) -> Self {
        match v {
            1 => PartialMode::Patch,
            2 => PartialMode::ContentRangePut,
            _ => PartialMode::Unknown,
        }
    }
}

/// A single WebDAV mount (server + credentials). Mount it via [`crate::Vfs::mount`].
pub struct WebdavBackend {
    client: reqwest::Client,
    auth: WebdavAuth,
    root: RootUrl,
    /// Negotiated partial-write mode; probed lazily on the first ranged write.
    partial_mode: AtomicU8,
}

impl WebdavBackend {
    /// `base_url` points at the collection to mount, e.g.
    /// `https://nas:5006` or `https://cloud.example.com/remote.php/dav/files/alice`.
    pub fn new(base_url: &str, auth: WebdavAuth) -> Result<Self> {
        let root = RootUrl::parse(base_url)?;
        let client = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(15))
            .user_agent(concat!("SuperFiles/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|e| VfsError::Io(format!("http client init failed: {e}")))?;
        Ok(Self {
            client,
            auth,
            root,
            partial_mode: AtomicU8::new(PartialMode::Unknown as u8),
        })
    }

    /// Canonical id of the mount root: `webdav://<authority>/`.
    pub fn root_id(&self) -> String {
        make_id(&self.root, "/")
    }

    fn request(&self, method: Method, url: String) -> RequestBuilder {
        let req = self.client.request(method, url);
        match &self.auth {
            WebdavAuth::None => req,
            WebdavAuth::Basic { username, password } => req.basic_auth(username, Some(password)),
            WebdavAuth::Bearer(token) => req.bearer_auth(token),
        }
    }

    /// Send with bounded retries (contract §4): transport errors are retried
    /// for every method, server errors (5xx) only when the caller marks the
    /// request safely repeatable. The final failure becomes `Network`.
    async fn send(
        &self,
        retry_server_errors: bool,
        build: impl Fn() -> RequestBuilder,
    ) -> Result<Response> {
        let mut delay = Duration::from_millis(200);
        let mut attempt = 0u32;
        loop {
            match build().send().await {
                Ok(resp) => {
                    if retry_server_errors
                        && resp.status().is_server_error()
                        && attempt + 1 < MAX_ATTEMPTS
                    {
                        tokio::time::sleep(delay).await;
                        delay *= 4;
                        attempt += 1;
                        continue;
                    }
                    return Ok(resp);
                }
                Err(err) => {
                    if attempt + 1 < MAX_ATTEMPTS {
                        tokio::time::sleep(delay).await;
                        delay *= 4;
                        attempt += 1;
                        continue;
                    }
                    return Err(VfsError::Network(err.to_string()));
                }
            }
        }
    }

    async fn propfind(&self, dav_path: &str, depth: u8) -> Result<Vec<DavResponse>> {
        let method = method(b"PROPFIND");
        let resp = self
            .send(true, || {
                self.request(method.clone(), self.root.url_for(dav_path))
                    .header("Depth", depth.to_string())
                    .header(header::CONTENT_TYPE, "application/xml")
                    .body(PROPFIND_BODY)
            })
            .await?;
        if resp.status() != StatusCode::from_u16(207).unwrap() {
            return Err(map_status(resp.status(), dav_path));
        }
        let body = resp.text().await.map_err(net_err)?;
        parse_multistatus(&body)
            .map_err(|e| VfsError::Network(format!("invalid PROPFIND response: {e}")))
    }

    /// Single entry at a dav path; `NotFound` when absent.
    async fn entry_at(&self, dav_path: &str) -> Result<Entry> {
        let mut responses = self.propfind(dav_path, 0).await?;
        let Some(first) = responses.pop() else {
            return Err(VfsError::NotFound(dav_path.to_string()));
        };
        self.entry_of(first)
    }

    fn entry_of(&self, res: DavResponse) -> Result<Entry> {
        let dav = self
            .root
            .dav_path_for_href(&res.href)?
            .ok_or_else(|| VfsError::Io(format!("href outside mount root: {}", res.href)))?;
        let kind = if res.is_collection {
            EntryKind::Directory
        } else {
            EntryKind::File
        };
        let name = if dav == "/" {
            self.root.authority().to_string()
        } else {
            dav.rsplit('/').next().unwrap_or(&dav).to_string()
        };
        let parent = if dav == "/" {
            None
        } else {
            Some(make_id(&self.root, &dav_parent(&dav)))
        };
        let mime = if kind == EntryKind::File {
            res.content_type
                .filter(|t| t != "application/octet-stream")
                .or_else(|| guess_mime(&name))
        } else {
            None
        };
        Ok(Entry {
            id: make_id(&self.root, &dav),
            parent,
            name,
            kind,
            size: if kind == EntryKind::Directory {
                0
            } else {
                res.content_length.unwrap_or(0)
            },
            modified_ms: res.last_modified_ms,
            mime,
            hidden: dav.rsplit('/').next().unwrap_or("").starts_with('.'),
            readonly: false,
        })
    }

    fn mode(&self) -> PartialMode {
        PartialMode::from_u8(self.partial_mode.load(Ordering::SeqCst))
    }

    /// Full replace (or create) of a resource. `create_only` turns on
    /// `If-None-Match: *` so an existing resource yields `AlreadyExists`.
    async fn put_full(&self, url: &str, body: Vec<u8>, create_only: bool) -> Result<()> {
        let resp = self
            .send(true, || {
                let req = self
                    .request(Method::PUT, url.to_string())
                    .body(body.clone());
                if create_only {
                    req.header(header::IF_NONE_MATCH, "*")
                } else {
                    req
                }
            })
            .await?;
        match resp.status().as_u16() {
            200..=299 => Ok(()),
            _ => Err(map_status(resp.status(), url)),
        }
    }

    /// SabreDAV partial update. `Unsupported` is the probe signal meaning
    /// "this server does not know PATCH", not a caller-facing failure.
    async fn partial_patch(&self, url: &str, dav: &str, offset: u64, data: &[u8]) -> Result<()> {
        let end = offset + data.len() as u64 - 1;
        let resp = self
            .send(true, || {
                self.request(method(b"PATCH"), url.to_string())
                    .header("X-Update-Range", format!("bytes={offset}-{end}"))
                    .header(header::CONTENT_TYPE, "application/octet-stream")
                    .body(data.to_vec())
            })
            .await?;
        match resp.status().as_u16() {
            200..=299 => Ok(()),
            400 | 405 | 501 => Err(VfsError::Unsupported("PATCH not supported".into())),
            404 => self.create_with_gap(url, dav, offset, data).await,
            other => Err(map_status(StatusCode::from_u16(other).unwrap(), dav)),
        }
    }

    /// `PUT` + `Content-Range`, the other dialect SabreDAV understands.
    async fn partial_cr_put(&self, url: &str, dav: &str, offset: u64, data: &[u8]) -> Result<()> {
        let end = offset + data.len() as u64 - 1;
        let resp = self
            .send(true, || {
                self.request(Method::PUT, url.to_string())
                    .header("Content-Range", format!("bytes {offset}-{end}/*"))
                    .body(data.to_vec())
            })
            .await?;
        match resp.status().as_u16() {
            200..=299 => Ok(()),
            400 | 405 | 501 => Err(VfsError::Unsupported(
                "Content-Range PUT not supported".into(),
            )),
            404 => self.create_with_gap(url, dav, offset, data).await,
            other => Err(map_status(StatusCode::from_u16(other).unwrap(), dav)),
        }
    }

    /// A ranged write hit a missing file: create it, honoring the POSIX
    /// zero-gap rule when `offset > 0`. The gap is capped so a hostile id
    /// cannot force a giant allocation.
    async fn create_with_gap(&self, url: &str, dav: &str, offset: u64, data: &[u8]) -> Result<()> {
        const MAX_GAP: u64 = 64 * 1024 * 1024;
        if offset > 0 {
            if offset > MAX_GAP {
                return Err(VfsError::Unsupported(format!(
                    "writing {dav} at offset {offset} would create a sparse gap"
                )));
            }
            let mut padded = vec![0u8; offset as usize];
            padded.extend_from_slice(data);
            self.put_full(url, padded, false).await
        } else {
            self.put_full(url, data.to_vec(), false).await
        }
    }

    async fn partial_write(&self, url: &str, dav: &str, offset: u64, data: &[u8]) -> Result<()> {
        match self.mode() {
            PartialMode::Patch => self.partial_patch(url, dav, offset, data).await,
            PartialMode::ContentRangePut => self.partial_cr_put(url, dav, offset, data).await,
            PartialMode::Unknown => match self.partial_patch(url, dav, offset, data).await {
                Ok(()) => {
                    self.partial_mode
                        .store(PartialMode::Patch as u8, Ordering::SeqCst);
                    Ok(())
                }
                Err(VfsError::Unsupported(_)) => {
                    match self.partial_cr_put(url, dav, offset, data).await {
                        Ok(()) => {
                            self.partial_mode
                                .store(PartialMode::ContentRangePut as u8, Ordering::SeqCst);
                            Ok(())
                        }
                        Err(VfsError::Unsupported(_)) => Err(VfsError::Unsupported(format!(
                            "server supports neither PATCH nor Content-Range PUT; \
                             partial writes are impossible: {dav}"
                        ))),
                        Err(other) => Err(other),
                    }
                }
                Err(other) => Err(other),
            },
        }
    }
}

#[async_trait]
impl Backend for WebdavBackend {
    fn scheme(&self) -> &'static str {
        SCHEME
    }

    fn display_name(&self) -> String {
        format!("webdav ({})", self.root.authority())
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
            // Partial writes are negotiated per server; until M2 grows a
            // temp-file fallback in the engine, advertise the safe bound.
            can_random_write: false,
            can_watch: false,
            native_thumbnails: false,
        }
    }

    async fn stat(&self, id: &str) -> Result<Entry> {
        self.entry_at(&resolve_id(&self.root, id)?).await
    }

    async fn list(&self, id: &str) -> Result<Vec<Entry>> {
        let dav = resolve_id(&self.root, id)?;
        let responses = self.propfind(&dav, 1).await?;
        let mut entries = Vec::new();
        let mut self_kind = EntryKind::Directory;
        for res in responses {
            let entry = self.entry_of(res)?;
            // Depth-1 answers start with the requested collection itself.
            if resolve_id(&self.root, &entry.id).ok() == Some(dav.clone()) {
                self_kind = entry.kind;
                continue;
            }
            entries.push(entry);
        }
        if self_kind != EntryKind::Directory {
            return Err(VfsError::Io(format!("not a directory: {dav}")));
        }
        entries.sort_by(|a, b| {
            let a_dir = a.kind == EntryKind::Directory;
            let b_dir = b.kind == EntryKind::Directory;
            b_dir
                .cmp(&a_dir)
                .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
        });
        Ok(entries)
    }

    async fn create_dir(&self, parent: &str, name: &str) -> Result<Entry> {
        validate_name(name)?;
        let parent_dav = resolve_id(&self.root, parent)?;
        let dav = format!(
            "{}{name}",
            if parent_dav == "/" {
                "/".into()
            } else {
                format!("{parent_dav}/")
            }
        );
        let resp = self
            .send(true, || {
                self.request(method(b"MKCOL"), self.root.url_for(&dav))
            })
            .await?;
        match resp.status().as_u16() {
            201 => self.entry_at(&dav).await,
            // RFC 4918: MKCOL on an existing collection is 405.
            405 => Err(VfsError::AlreadyExists(dav)),
            other => Err(map_status(StatusCode::from_u16(other).unwrap(), &dav)),
        }
    }

    async fn create_file(&self, parent: &str, name: &str) -> Result<Entry> {
        validate_name(name)?;
        let parent_dav = resolve_id(&self.root, parent)?;
        let dav = format!(
            "{}{name}",
            if parent_dav == "/" {
                "/".into()
            } else {
                format!("{parent_dav}/")
            }
        );
        self.put_full(&self.root.url_for(&dav), Vec::new(), true)
            .await?;
        self.entry_at(&dav).await
    }

    async fn remove(&self, id: &str, recursive: bool) -> Result<()> {
        let dav = resolve_id(&self.root, id)?;
        let entry = self.entry_at(&dav).await?;
        if entry.is_dir() && !recursive {
            // WebDAV DELETE is always recursive (RFC 4918 §9.6.1), so the
            // non-recursive guard must be enforced client side.
            if !self.list(id).await?.is_empty() {
                return Err(VfsError::Io(format!(
                    "directory not empty (pass recursive=true): {dav}"
                )));
            }
        }
        let resp = self
            .send(true, || {
                self.request(Method::DELETE, self.root.url_for(&dav))
            })
            .await?;
        match resp.status().as_u16() {
            200..=299 => Ok(()),
            _ => Err(map_status(resp.status(), &dav)),
        }
    }

    async fn rename(&self, id: &str, new_name: &str) -> Result<Entry> {
        validate_name(new_name)?;
        let dav = resolve_id(&self.root, id)?;
        if dav == "/" {
            return Err(VfsError::PermissionDenied(
                "cannot rename the mount root".into(),
            ));
        }
        let new_dav = format!("{}{new_name}", parent_prefix(&dav));
        let destination = self.root.url_for(&new_dav);
        let resp = self
            .send(true, || {
                self.request(method(b"MOVE"), self.root.url_for(&dav))
                    .header("Destination", destination.clone())
                    .header("Overwrite", "T")
            })
            .await?;
        match resp.status().as_u16() {
            200..=299 => self.entry_at(&new_dav).await,
            _ => Err(map_status(resp.status(), &dav)),
        }
    }

    async fn read_range(&self, id: &str, offset: u64, len: usize) -> Result<Vec<u8>> {
        if len == 0 {
            return Ok(Vec::new());
        }
        let dav = resolve_id(&self.root, id)?;
        let end = offset.saturating_add(len as u64).saturating_sub(1);
        let resp = self
            .send(true, || {
                self.request(Method::GET, self.root.url_for(&dav))
                    .header(header::RANGE, format!("bytes={offset}-{end}"))
            })
            .await?;
        let status = resp.status();
        match status.as_u16() {
            // Range satisfiable; server may still give a short tail read.
            206 => {
                let mut bytes = resp.bytes().await.map_err(net_err)?.to_vec();
                bytes.truncate(len);
                Ok(bytes)
            }
            // Server ignored the Range header: slice client side.
            200 => {
                let bytes = resp.bytes().await.map_err(net_err)?;
                if offset >= bytes.len() as u64 {
                    return Ok(Vec::new());
                }
                let from = offset as usize;
                let to = ((offset + len as u64) as usize).min(bytes.len());
                Ok(bytes[from..to].to_vec())
            }
            // Contract §2: out-of-range offset yields an empty read.
            416 => Ok(Vec::new()),
            _ => Err(map_status(status, &dav)),
        }
    }

    async fn write_range(&self, id: &str, offset: u64, data: &[u8]) -> Result<()> {
        let dav = resolve_id(&self.root, id)?;
        let url = self.root.url_for(&dav);
        let existing = match self.entry_at(&dav).await {
            Ok(entry) => Some(entry.size),
            Err(VfsError::NotFound(_)) => None,
            Err(other) => return Err(other),
        };
        match existing {
            None if offset == 0 => self.put_full(&url, data.to_vec(), false).await,
            Some(_) if data.is_empty() => {
                // POSIX: writing zero bytes changes nothing.
                Ok(())
            }
            Some(size) if offset == 0 && data.len() as u64 >= size => {
                // New data covers the old file entirely: plain PUT is exact.
                self.put_full(&url, data.to_vec(), false).await
            }
            _ => self.partial_write(&url, &dav, offset, data).await,
        }
    }

    async fn truncate(&self, id: &str, size: u64) -> Result<()> {
        let dav = resolve_id(&self.root, id)?;
        let current = self.entry_at(&dav).await?.size;
        if current == size {
            return Ok(());
        }
        let url = self.root.url_for(&dav);
        if size == 0 {
            return self.put_full(&url, Vec::new(), false).await;
        }
        if size < current {
            // No shrink verb exists: re-PUT the head. The transfer engine's
            // overwrite flow never reaches this branch (chunks already built
            // the final file), it only serves explicit truncate calls.
            let head = self
                .read_range(
                    id,
                    0,
                    usize::try_from(size)
                        .map_err(|_| VfsError::Unsupported("truncate size too large".into()))?,
                )
                .await?;
            return self.put_full(&url, head, false).await;
        }
        // Extend with zero padding through partial writes.
        let mut offset = current;
        let zeros = vec![0u8; crate::DEFAULT_CHUNK_SIZE];
        while offset < size {
            let n = ((size - offset) as usize).min(zeros.len());
            self.partial_write(&url, &dav, offset, &zeros[..n]).await?;
            offset += n as u64;
        }
        Ok(())
    }

    /// Streamed download with cancel polling per chunk. Overriding the default
    /// keeps a 20 GB export from piling up in memory.
    async fn read_to_fd(
        &self,
        id: &str,
        fd: i32,
        offset: u64,
        cancel: &crate::cancel::CancelToken,
    ) -> Result<u64> {
        let dav = resolve_id(&self.root, id)?;
        let mut resp = self
            .send(true, || {
                let req = self.request(Method::GET, self.root.url_for(&dav));
                if offset > 0 {
                    req.header(header::RANGE, format!("bytes={offset}-"))
                } else {
                    req
                }
            })
            .await?;
        let mut skip = match resp.status().as_u16() {
            206 => 0,
            200 => offset, // Server ignored Range: skip client side.
            416 => return Ok(0),
            _ => return Err(map_status(resp.status(), &dav)),
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

fn method(verb: &'static [u8]) -> Method {
    Method::from_bytes(verb).expect("valid HTTP method")
}

/// `/a/b` -> `/a/` (root stays `/`). Used to build sibling destinations.
fn parent_prefix(dav: &str) -> String {
    match dav.rfind('/') {
        Some(0) | None => "/".to_string(),
        Some(idx) => format!("{}/", &dav[..idx]),
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

/// Protocol errors by contract §4 semantics. Callers special-case the few
/// op-specific codes first (405 for MKCOL, 416 for GET, ...).
fn map_status(status: StatusCode, dav_path: &str) -> VfsError {
    match status.as_u16() {
        401 | 403 => VfsError::PermissionDenied(format!("{dav_path} (HTTP {status})")),
        404 => VfsError::NotFound(dav_path.to_string()),
        // 409 Conflict = the parent collection does not exist.
        409 => VfsError::NotFound(format!("parent of {dav_path}")),
        412 => VfsError::AlreadyExists(dav_path.to_string()),
        423 => VfsError::PermissionDenied(format!("locked: {dav_path}")),
        507 => VfsError::Io(format!("insufficient storage: {dav_path}")),
        s if s >= 500 => VfsError::Network(format!("{dav_path}: HTTP {s}")),
        s => VfsError::Io(format!("{dav_path}: HTTP {s}")),
    }
}

#[cfg(test)]
mod tests;
