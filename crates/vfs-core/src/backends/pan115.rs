//! 115 cloud drive backend (115 开放平台 v2), file-id based namespace.
//!
//! Protocol notes:
//!
//! * Auth uses the device-code + PKCE flow (no redirect URI, no AppSecret):
//!   `POST /open/authDeviceCode` → poll `qrcodeapi.115.com/get/status/` →
//!   `POST /open/deviceCodeToToken`. Refresh tokens live one year and rotate.
//! * Items are addressed by numeric ids: `pan115://<fid>`; root is `pan115://0`.
//!   A not-yet-created item is spelled `pan115://<parentCid>/<name>`.
//! * Downloads need a `pick_code` → `POST /open/ufile/downurl` → signed URL,
//!   which is then fetched with `Range`.
//! * Uploads go through 115's object storage (SigV4) and are not implemented
//!   yet; `can_write` is false while folder/rename/delete work.

use std::collections::HashMap;
use std::sync::Mutex;

use async_trait::async_trait;
use serde_json::Value;

use crate::backend::Backend;
use crate::capabilities::Capabilities;
use crate::entry::{guess_mime, Entry, EntryKind};
use crate::error::{Result, VfsError};
use crate::uri::split_id;

use super::cloud::{self, CloudAuth};

pub const SCHEME: &str = "pan115";
pub const ROOT_ID: &str = "0";

const API: &str = "https://proapi.115.com";
const UA: &str = "115Browser/27.0.0.2";

pub struct Pan115Backend {
    client: reqwest::Client,
    auth: CloudAuth,
    /// fid → (pick_code, size) learned from list/stat, so downloads skip a stat.
    pick: Mutex<HashMap<String, (String, u64)>>,
}

impl Pan115Backend {
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
            "https://passportapi.115.com/open/refreshToken".to_string(),
        );
        Self {
            client,
            auth,
            pick: Mutex::new(HashMap::new()),
        }
    }

    pub fn root_id(&self) -> String {
        make_id(ROOT_ID)
    }

    fn id_of(&self, id: &str) -> Result<String> {
        let (scheme, rest) = split_id(id);
        if scheme != SCHEME || rest.is_empty() {
            return Err(VfsError::Unsupported(format!(
                "115 backend cannot handle {id}"
            )));
        }
        match rest.rsplit_once('/') {
            Some((parent, _)) => Ok(parent.to_string()),
            None => Ok(rest.to_string()),
        }
    }

    async fn send(
        &self,
        retry: bool,
        build: impl Fn(&reqwest::Client) -> reqwest::RequestBuilder,
    ) -> Result<reqwest::Response> {
        cloud::send_with_auth(&self.client, &self.auth, retry, |c| {
            build(c).header(reqwest::header::USER_AGENT, UA)
        })
        .await
    }

    async fn api(
        &self,
        method: reqwest::Method,
        path: &str,
        form: &[(&str, String)],
    ) -> Result<Value> {
        let url = format!("{API}{path}");
        let mut fields: HashMap<&str, String> = HashMap::new();
        for (k, v) in form {
            fields.insert(*k, v.clone());
        }
        let resp = self
            .send(true, |c| {
                let rb = c.request(method.clone(), &url);
                if fields.is_empty() {
                    rb
                } else {
                    rb.form(&fields)
                }
            })
            .await?;
        let status = resp.status();
        let text = resp.text().await.map_err(net_err)?;
        if !status.is_success() {
            return Err(VfsError::Network(format!(
                "115 {path}: HTTP {status} {text}"
            )));
        }
        let v: Value = serde_json::from_str(&text)
            .map_err(|e| VfsError::Network(format!("invalid 115 JSON: {e}")))?;
        if v.get("state").and_then(|s| s.as_bool()) == Some(false) {
            let msg = v
                .get("message")
                .and_then(|s| s.as_str())
                .unwrap_or("request failed");
            let code = v.get("code").and_then(|c| c.as_i64()).unwrap_or(0);
            return Err(match code {
                40140125 | 40140126 => VfsError::PermissionDenied(msg.to_string()),
                50004 => VfsError::NotFound(msg.to_string()),
                _ => VfsError::Io(format!("115 {path}: {msg} ({code})")),
            });
        }
        Ok(v)
    }

    fn item_of(&self, it: &Value, parent: &str) -> Option<Entry> {
        let fid = it.get("fid").and_then(|v| v.as_str())?;
        let name = it.get("fn").and_then(|v| v.as_str())?.to_string();
        let is_dir = str_of(it.get("fc")).as_deref() == Some("0");
        let size = it.get("fs").and_then(|v| v.as_u64()).unwrap_or(0);
        let modified = it.get("upt").and_then(|v| v.as_i64()).map(|s| s * 1000);
        if let Some(pc) = it.get("pc").and_then(|v| v.as_str()) {
            if !pc.is_empty() {
                self.pick
                    .lock()
                    .unwrap()
                    .insert(fid.to_string(), (pc.to_string(), size));
            }
        }
        Some(Entry {
            id: make_id(fid),
            parent: Some(make_id(parent)),
            name,
            kind: if is_dir {
                EntryKind::Directory
            } else {
                EntryKind::File
            },
            size: if is_dir { 0 } else { size },
            modified_ms: modified,
            mime: if is_dir {
                None
            } else {
                guess_mime(it.get("fn").and_then(|v| v.as_str()).unwrap_or(""))
            },
            hidden: false,
            readonly: false,
        })
    }

    async fn pick_code(&self, fid: &str) -> Result<String> {
        if let Some((pc, _)) = self.pick.lock().unwrap().get(fid) {
            return Ok(pc.clone());
        }
        let v = self
            .api(
                reqwest::Method::GET,
                &format!("/open/folder/get_info?file_id={fid}"),
                &[],
            )
            .await?;
        let pc = v
            .pointer("/data/pick_code")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        if pc.is_empty() {
            return Err(VfsError::Unsupported(format!(
                "115 item has no pick_code: {fid}"
            )));
        }
        let size = v
            .pointer("/data/size_byte")
            .and_then(|v| v.as_u64())
            .unwrap_or(0);
        self.pick
            .lock()
            .unwrap()
            .insert(fid.to_string(), (pc.clone(), size));
        Ok(pc)
    }

    async fn download_url(&self, fid: &str) -> Result<String> {
        let pc = self.pick_code(fid).await?;
        let v = self
            .api(
                reqwest::Method::POST,
                "/open/ufile/downurl",
                &[("pick_code", pc)],
            )
            .await?;
        let data = v
            .get("data")
            .and_then(|d| d.as_object())
            .ok_or_else(|| VfsError::Network("115 downurl: empty data".into()))?;
        for (_, item) in data {
            if let Some(url) = item.pointer("/url/url").and_then(|u| u.as_str()) {
                return Ok(url.to_string());
            }
        }
        Err(VfsError::Network("115 downurl: no url".into()))
    }
}

#[async_trait]
impl Backend for Pan115Backend {
    fn scheme(&self) -> &'static str {
        SCHEME
    }

    fn display_name(&self) -> String {
        "115".to_string()
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities {
            can_list: true,
            can_read: true,
            // Upload goes through 115 object storage (SigV4) and is not wired
            // yet; folder/rename/delete are available.
            can_write: false,
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
        let fid = self.id_of(id)?;
        if fid == ROOT_ID {
            return Ok(Entry {
                id: make_id(ROOT_ID),
                parent: None,
                name: "115".to_string(),
                kind: EntryKind::Directory,
                size: 0,
                modified_ms: None,
                mime: None,
                hidden: false,
                readonly: false,
            });
        }
        let v = self
            .api(
                reqwest::Method::GET,
                &format!("/open/folder/get_info?file_id={fid}"),
                &[],
            )
            .await?;
        let d = v
            .get("data")
            .ok_or_else(|| VfsError::NotFound(id.to_string()))?;
        let name = d
            .get("file_name")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let is_dir = str_of(d.get("file_category")).as_deref() == Some("0");
        let size = d.get("size_byte").and_then(|v| v.as_u64()).unwrap_or(0);
        let modified = d.get("utime").and_then(|v| v.as_i64()).map(|s| s * 1000);
        if let Some(pc) = d.get("pick_code").and_then(|v| v.as_str()) {
            if !pc.is_empty() {
                self.pick
                    .lock()
                    .unwrap()
                    .insert(fid.clone(), (pc.to_string(), size));
            }
        }
        let parent = d
            .pointer("/paths/-1/file_id")
            .and_then(|v| v.as_str())
            .map(make_id);
        Ok(Entry {
            id: make_id(&fid),
            parent,
            name: name.clone(),
            kind: if is_dir {
                EntryKind::Directory
            } else {
                EntryKind::File
            },
            size: if is_dir { 0 } else { size },
            modified_ms: modified,
            mime: if is_dir { None } else { guess_mime(&name) },
            hidden: false,
            readonly: false,
        })
    }

    async fn list(&self, id: &str) -> Result<Vec<Entry>> {
        let cid = self.id_of(id)?;
        let mut out = Vec::new();
        let mut offset = 0u64;
        loop {
            let url = format!(
                "/open/ufile/files?cid={cid}&limit=1150&offset={offset}&show_dir=1&o=file_name&asc=1"
            );
            let v = self.api(reqwest::Method::GET, &url, &[]).await?;
            let arr = match v.get("data").and_then(|d| d.as_array()) {
                Some(a) => a.clone(),
                None => break,
            };
            let n = arr.len() as u64;
            for it in &arr {
                if let Some(e) = self.item_of(it, &cid) {
                    out.push(e);
                }
            }
            let total = v.get("count").and_then(|c| c.as_u64()).unwrap_or(0);
            offset += n;
            if n == 0 || offset >= total {
                break;
            }
        }
        sort_entries(&mut out);
        Ok(out)
    }

    async fn create_dir(&self, parent: &str, name: &str) -> Result<Entry> {
        validate_name(name)?;
        let pid = self.id_of(parent)?;
        let v = self
            .api(
                reqwest::Method::POST,
                "/open/folder/add",
                &[("pid", pid.clone()), ("file_name", name.to_string())],
            )
            .await?;
        let fid = v
            .pointer("/data/file_id")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        Ok(Entry {
            id: make_id(&fid),
            parent: Some(make_id(&pid)),
            name: name.to_string(),
            kind: EntryKind::Directory,
            size: 0,
            modified_ms: None,
            mime: None,
            hidden: false,
            readonly: false,
        })
    }

    async fn create_file(&self, _parent: &str, _name: &str) -> Result<Entry> {
        Err(VfsError::Unsupported(
            "115 upload is not implemented yet (object storage SigV4)".into(),
        ))
    }

    async fn remove(&self, id: &str, _recursive: bool) -> Result<()> {
        let fid = self.id_of(id)?;
        if fid == ROOT_ID {
            return Err(VfsError::PermissionDenied(
                "cannot delete the mount root".into(),
            ));
        }
        self.api(
            reqwest::Method::POST,
            "/open/ufile/delete",
            &[("file_ids", fid)],
        )
        .await?;
        Ok(())
    }

    async fn rename(&self, id: &str, new_name: &str) -> Result<Entry> {
        validate_name(new_name)?;
        let fid = self.id_of(id)?;
        if fid == ROOT_ID {
            return Err(VfsError::PermissionDenied(
                "cannot rename the mount root".into(),
            ));
        }
        let old = self.stat(id).await?;
        self.api(
            reqwest::Method::POST,
            "/open/ufile/update",
            &[
                ("file_id", fid.clone()),
                ("file_name", new_name.to_string()),
            ],
        )
        .await?;
        Ok(Entry {
            name: new_name.to_string(),
            ..old
        })
    }

    async fn read_range(&self, id: &str, offset: u64, len: usize) -> Result<Vec<u8>> {
        if len == 0 {
            return Ok(Vec::new());
        }
        let fid = self.id_of(id)?;
        let url = self.download_url(&fid).await?;
        let end = offset.saturating_add(len as u64).saturating_sub(1);
        let resp = self
            .client
            .get(&url)
            .header(reqwest::header::USER_AGENT, UA)
            .header(reqwest::header::RANGE, format!("bytes={offset}-{end}"))
            .send()
            .await
            .map_err(net_err)?;
        match resp.status().as_u16() {
            200 | 206 => {
                let mut bytes = resp.bytes().await.map_err(net_err)?.to_vec();
                bytes.truncate(len);
                Ok(bytes)
            }
            416 => Ok(Vec::new()),
            s => Err(VfsError::Io(format!("115 download: HTTP {s}"))),
        }
    }

    async fn write_range(&self, _id: &str, _offset: u64, _data: &[u8]) -> Result<()> {
        Err(VfsError::Unsupported(
            "115 upload is not implemented yet".into(),
        ))
    }

    async fn truncate(&self, _id: &str, _size: u64) -> Result<()> {
        Err(VfsError::Unsupported(
            "115 upload is not implemented yet".into(),
        ))
    }

    async fn read_to_fd(
        &self,
        id: &str,
        fd: i32,
        offset: u64,
        cancel: &crate::cancel::CancelToken,
    ) -> Result<u64> {
        let fid = self.id_of(id)?;
        let url = self.download_url(&fid).await?;
        let mut resp = self
            .client
            .get(&url)
            .header(reqwest::header::USER_AGENT, UA)
            .header(reqwest::header::RANGE, format!("bytes={offset}-"))
            .send()
            .await
            .map_err(net_err)?;
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

fn make_id(id: &str) -> String {
    format!("{SCHEME}://{id}")
}

fn str_of(v: Option<&Value>) -> Option<String> {
    match v {
        Some(Value::String(s)) => Some(s.clone()),
        Some(Value::Number(n)) => Some(n.to_string()),
        _ => None,
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
