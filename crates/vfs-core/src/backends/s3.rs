//! S3-compatible object storage backend (AWS S3 / MinIO / R2 / OSS-S3).
//!
//! * Addresses objects by key: `s3://a/b/c.txt` (root is `s3://`).
//! * SigV4 signing with optional path-style addressing (`endpoint/bucket/key`)
//!   for MinIO/R2; virtual-host style is `bucket.endpoint/key`.
//! * Objects have no directories: `create_dir` writes a zero-byte `<prefix>/`
//!   marker, listing uses `delimiter=/` so prefixes appear as folders.
//! * Uploads stream the spool file with `UNSIGNED-PAYLOAD` (HTTPS only), so
//!   large files never sit in memory.

use std::path::Path;
use std::sync::Arc;

use async_trait::async_trait;
use hmac::{Hmac, Mac};
use serde::Deserialize;
use sha2::{Digest, Sha256};

use crate::backend::Backend;
use crate::capabilities::Capabilities;
use crate::entry::{guess_mime, Entry, EntryKind};
use crate::error::{Result, VfsError};
use crate::uri::split_id;

use super::cloud::SpoolPool;

pub const SCHEME: &str = "s3";
const EMPTY_SHA256: &str = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

type HmacSha256 = Hmac<Sha256>;

pub struct S3Backend {
    client: reqwest::Client,
    endpoint: String,
    region: String,
    bucket: String,
    access_key: String,
    secret_key: String,
    session_token: Option<String>,
    path_style: bool,
    spool: Arc<SpoolPool>,
}

#[derive(Debug, Deserialize)]
struct ListBucketResult {
    #[serde(default, rename = "Contents")]
    contents: Vec<ListObject>,
    #[serde(default, rename = "CommonPrefixes")]
    prefixes: Vec<CommonPrefix>,
    #[serde(default, rename = "IsTruncated")]
    truncated: Option<bool>,
    #[serde(default, rename = "NextContinuationToken")]
    next_token: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ListObject {
    #[serde(rename = "Key")]
    key: String,
    #[serde(default, rename = "Size")]
    size: Option<u64>,
    #[serde(default, rename = "LastModified")]
    modified: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CommonPrefix {
    #[serde(rename = "Prefix")]
    prefix: String,
}

impl S3Backend {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        endpoint: String,
        region: String,
        bucket: String,
        access_key: String,
        secret_key: String,
        session_token: Option<String>,
        path_style: bool,
    ) -> Self {
        let endpoint = endpoint.trim_end_matches('/').to_string();
        Self {
            client: super::cloud::http_client(),
            endpoint,
            region: if region.is_empty() {
                "us-east-1".into()
            } else {
                region
            },
            bucket,
            access_key,
            secret_key,
            session_token,
            path_style,
            spool: SpoolPool::new(),
        }
    }

    pub fn root_id(&self) -> String {
        make_id("")
    }

    fn key_of(&self, id: &str) -> Result<String> {
        let (scheme, rest) = split_id(id);
        if scheme != SCHEME {
            return Err(VfsError::Unsupported(format!(
                "s3 backend cannot handle {id}"
            )));
        }
        Ok(rest.to_string())
    }

    fn host_and_path(&self, key: &str) -> (String, String) {
        let host = self
            .endpoint
            .split("://")
            .nth(1)
            .unwrap_or(&self.endpoint)
            .trim_end_matches('/')
            .to_string();
        let encoded = encode_key(key);
        if self.path_style {
            let path = if encoded.is_empty() {
                format!("/{}", self.bucket)
            } else {
                format!("/{}/{}", self.bucket, encoded)
            };
            (host, path)
        } else {
            let path = format!("/{}", encoded);
            (format!("{}.{}", self.bucket, host), path)
        }
    }

    /// Signed request builder for `method` + `key` (+ optional query pairs).
    fn request(
        &self,
        method: reqwest::Method,
        key: &str,
        query: &[(&str, String)],
        payload_hash: &str,
    ) -> reqwest::RequestBuilder {
        let (host, path) = self.host_and_path(key);
        let mut q: Vec<(String, String)> = query
            .iter()
            .map(|(k, v)| (encode_query(k), encode_query(v)))
            .collect();
        q.sort();
        let canonical_query = q
            .iter()
            .map(|(k, v)| format!("{k}={v}"))
            .collect::<Vec<_>>()
            .join("&");

        let now = chrono_like_now();
        let (amz_date, date) = now;
        let mut headers: Vec<(String, String)> = vec![
            ("host".into(), host.clone()),
            ("x-amz-content-sha256".into(), payload_hash.to_string()),
            ("x-amz-date".into(), amz_date.clone()),
        ];
        if let Some(token) = &self.session_token {
            if !token.is_empty() {
                headers.push(("x-amz-security-token".into(), token.clone()));
            }
        }
        headers.sort();
        let canonical_headers: String = headers
            .iter()
            .map(|(k, v)| format!("{k}:{}\n", v.trim()))
            .collect();
        let signed_headers = headers
            .iter()
            .map(|(k, _)| k.as_str())
            .collect::<Vec<_>>()
            .join(";");

        let canonical_request = format!(
            "{}\n{}\n{}\n{}\n{}\n{}",
            method.as_str(),
            path,
            canonical_query,
            canonical_headers,
            signed_headers,
            payload_hash
        );
        let scope = format!("{}/{}/s3/aws4_request", date, self.region);
        let string_to_sign = format!(
            "AWS4-HMAC-SHA256\n{}\n{}\n{}",
            amz_date,
            scope,
            hex::encode(Sha256::digest(canonical_request.as_bytes()))
        );
        let signing_key = signing_key(&self.secret_key, &date, &self.region, "s3");
        let signature = hex::encode(hmac(&signing_key, string_to_sign.as_bytes()));

        let authorization = format!(
            "AWS4-HMAC-SHA256 Credential={}/{}, SignedHeaders={}, Signature={}",
            self.access_key, scope, signed_headers, signature
        );

        let url = if canonical_query.is_empty() {
            format!("{}://{}{}", self.scheme(), host, path)
        } else {
            format!("{}://{}{}?{}", self.scheme(), host, path, canonical_query)
        };
        let mut rb = self
            .client
            .request(method, url)
            .header(reqwest::header::HOST, host)
            .header("x-amz-content-sha256", payload_hash)
            .header("x-amz-date", amz_date)
            .header(reqwest::header::AUTHORIZATION, authorization);
        if let Some(token) = &self.session_token {
            if !token.is_empty() {
                rb = rb.header("x-amz-security-token", token);
            }
        }
        rb
    }

    fn scheme(&self) -> &str {
        self.endpoint.split("://").next().unwrap_or("https")
    }

    async fn list_page(&self, prefix: &str, token: Option<&str>) -> Result<ListBucketResult> {
        let mut query = vec![
            ("list-type", "2".to_string()),
            ("prefix", prefix.to_string()),
            ("delimiter", "/".to_string()),
            ("max-keys", "1000".to_string()),
        ];
        if let Some(t) = token {
            query.push(("continuation-token", t.to_string()));
        }
        let resp = self
            .request(reqwest::Method::GET, "", &query, EMPTY_SHA256)
            .send()
            .await
            .map_err(net_err)?;
        if !resp.status().is_success() {
            return Err(map_status(resp.status(), prefix));
        }
        let text = resp.text().await.map_err(net_err)?;
        quick_xml::de::from_str(&text)
            .map_err(|e| VfsError::Network(format!("invalid S3 XML: {e}")))
    }

    async fn put_empty(&self, key: &str) -> Result<()> {
        let resp = self
            .request(reqwest::Method::PUT, key, &[], EMPTY_SHA256)
            .header(reqwest::header::CONTENT_LENGTH, "0")
            .body(Vec::new())
            .send()
            .await
            .map_err(net_err)?;
        if !resp.status().is_success() {
            return Err(map_status(resp.status(), key));
        }
        Ok(())
    }

    async fn copy_object(&self, from: &str, to: &str) -> Result<()> {
        let source = encode_key(&format!("/{}/{}", self.bucket, from));
        let resp = self
            .request(reqwest::Method::PUT, to, &[], EMPTY_SHA256)
            .header("x-amz-copy-source", source)
            .send()
            .await
            .map_err(net_err)?;
        if !resp.status().is_success() {
            return Err(map_status(resp.status(), to));
        }
        Ok(())
    }

    async fn delete_key(&self, key: &str) -> Result<()> {
        let resp = self
            .request(reqwest::Method::DELETE, key, &[], EMPTY_SHA256)
            .header(reqwest::header::CONTENT_LENGTH, "0")
            .send()
            .await
            .map_err(net_err)?;
        if resp.status().as_u16() == 404 {
            return Ok(());
        }
        if !resp.status().is_success() && resp.status().as_u16() != 204 {
            return Err(map_status(resp.status(), key));
        }
        Ok(())
    }

    async fn all_keys(&self, prefix: &str) -> Result<Vec<String>> {
        let mut out = Vec::new();
        let mut token: Option<String> = None;
        loop {
            let page = self.list_page(prefix, token.as_deref()).await?;
            for obj in page.contents {
                out.push(obj.key);
            }
            if page.truncated == Some(true) {
                token = page.next_token;
                if token.is_none() {
                    break;
                }
            } else {
                break;
            }
        }
        Ok(out)
    }

    fn entry_of(&self, key: &str, is_dir: bool, size: u64, modified: Option<String>) -> Entry {
        let name = if is_dir {
            key.trim_end_matches('/')
                .rsplit('/')
                .next()
                .unwrap_or(key)
                .to_string()
        } else {
            key.rsplit('/').next().unwrap_or(key).to_string()
        };
        Entry {
            id: make_id(key),
            parent: Some(make_id(&parent_key(key))),
            name: name.clone(),
            kind: if is_dir {
                EntryKind::Directory
            } else {
                EntryKind::File
            },
            size: if is_dir { 0 } else { size },
            modified_ms: modified.as_deref().and_then(parse_iso8601_ms),
            mime: if is_dir { None } else { guess_mime(&name) },
            hidden: false,
            readonly: false,
        }
    }
}

#[async_trait]
impl Backend for S3Backend {
    fn scheme(&self) -> &'static str {
        SCHEME
    }

    fn display_name(&self) -> String {
        "s3".to_string()
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
        let key = self.key_of(id)?;
        if key.is_empty() {
            return Ok(self.entry_of("", true, 0, None));
        }
        let resp = self
            .request(reqwest::Method::HEAD, &key, &[], EMPTY_SHA256)
            .send()
            .await
            .map_err(net_err)?;
        if resp.status().as_u16() == 404 {
            return Err(VfsError::NotFound(id.to_string()));
        }
        if !resp.status().is_success() {
            return Err(map_status(resp.status(), id));
        }
        let size = resp
            .headers()
            .get(reqwest::header::CONTENT_LENGTH)
            .and_then(|v| v.to_str().ok())
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);
        let modified = resp
            .headers()
            .get(reqwest::header::LAST_MODIFIED)
            .and_then(|v| v.to_str().ok())
            .map(String::from);
        Ok(self.entry_of(&key, key.ends_with('/'), size, modified))
    }

    async fn list(&self, id: &str) -> Result<Vec<Entry>> {
        let base = self.key_of(id)?;
        let prefix = if base.is_empty() || base.ends_with('/') {
            base
        } else {
            format!("{base}/")
        };
        let mut out = Vec::new();
        let mut token: Option<String> = None;
        loop {
            let page = self.list_page(&prefix, token.as_deref()).await?;
            for p in page.prefixes {
                if p.prefix != prefix {
                    out.push(self.entry_of(&p.prefix, true, 0, None));
                }
            }
            for obj in page.contents {
                if obj.key == prefix || obj.key.ends_with('/') {
                    continue;
                }
                out.push(self.entry_of(&obj.key, false, obj.size.unwrap_or(0), obj.modified));
            }
            if page.truncated == Some(true) {
                token = page.next_token;
                if token.is_none() {
                    break;
                }
            } else {
                break;
            }
        }
        sort_entries(&mut out);
        Ok(out)
    }

    async fn create_dir(&self, parent: &str, name: &str) -> Result<Entry> {
        let parent_key = self.key_of(parent)?;
        let key = join_key(&parent_key, name);
        let marker = format!("{key}/");
        self.put_empty(&marker).await?;
        Ok(self.entry_of(&marker, true, 0, None))
    }

    async fn create_file(&self, parent: &str, name: &str) -> Result<Entry> {
        let parent_key = self.key_of(parent)?;
        let key = join_key(&parent_key, name);
        self.put_empty(&key).await?;
        Ok(self.entry_of(&key, false, 0, None))
    }

    async fn remove(&self, id: &str, recursive: bool) -> Result<()> {
        let key = self.key_of(id)?;
        if key.is_empty() {
            return Err(VfsError::PermissionDenied(
                "cannot delete the bucket root".into(),
            ));
        }
        // 目录可能以 `dir/`（marker）或 `dir` 传入，两种都要处理。
        let prefix = if key.ends_with('/') {
            key.clone()
        } else {
            format!("{key}/")
        };
        let mut nested = self.all_keys(&prefix).await?;
        if !nested.is_empty() {
            let has_children = nested.iter().any(|k| k != &prefix);
            if !recursive && (has_children || nested.len() > 1) {
                return Err(VfsError::Io(format!(
                    "directory not empty (pass recursive=true): {key}"
                )));
            }
            for k in nested.drain(..) {
                self.delete_key(&k).await?;
            }
        }
        self.delete_key(&key).await?;
        if !key.ends_with('/') {
            self.delete_key(&prefix).await?;
        }
        Ok(())
    }

    async fn rename(&self, id: &str, new_name: &str) -> Result<Entry> {
        let key = self.key_of(id)?;
        if key.is_empty() {
            return Err(VfsError::PermissionDenied(
                "cannot rename the bucket root".into(),
            ));
        }
        let parent = parent_key(&key);
        let new_key = join_key(&parent, new_name);
        if key.ends_with('/') {
            let keys = self.all_keys(&key).await?;
            for k in &keys {
                let suffix = k.strip_prefix(&key).unwrap_or("");
                self.copy_object(k, &format!("{new_key}/{suffix}")).await?;
            }
            for k in keys {
                self.delete_key(&k).await?;
            }
            Ok(self.entry_of(&format!("{new_key}/"), true, 0, None))
        } else {
            self.copy_object(&key, &new_key).await?;
            self.delete_key(&key).await?;
            Ok(self.entry_of(&new_key, false, 0, None))
        }
    }

    async fn read_range(&self, id: &str, offset: u64, len: usize) -> Result<Vec<u8>> {
        if len == 0 {
            return Ok(Vec::new());
        }
        let key = self.key_of(id)?;
        let end = offset.saturating_add(len as u64).saturating_sub(1);
        let resp = self
            .request(reqwest::Method::GET, &key, &[], EMPTY_SHA256)
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
            s => Err(map_status(reqwest::StatusCode::from_u16(s).unwrap(), id)),
        }
    }

    async fn write_range(&self, id: &str, offset: u64, data: &[u8]) -> Result<()> {
        let key = self.key_of(id)?;
        let name = key.rsplit('/').next().unwrap_or(&key).to_string();
        self.spool.write(id, offset, data, parent_key(&key), name)
    }

    async fn truncate(&self, id: &str, size: u64) -> Result<()> {
        let Some(spool) = self.spool.take(id) else {
            return Err(VfsError::Unsupported(format!(
                "s3 has no in-place truncate: {id}"
            )));
        };
        let key = join_key(&spool.parent, &spool.name);
        let result = self.upload_stream(&key, &spool.path, size).await;
        let _ = std::fs::remove_file(&spool.path);
        result
    }

    async fn read_to_fd(
        &self,
        id: &str,
        fd: i32,
        offset: u64,
        cancel: &crate::cancel::CancelToken,
    ) -> Result<u64> {
        let key = self.key_of(id)?;
        let mut resp = self
            .request(reqwest::Method::GET, &key, &[], EMPTY_SHA256)
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

impl S3Backend {
    async fn upload_stream(&self, key: &str, file: &Path, size: u64) -> Result<()> {
        let fh = tokio::fs::File::open(file).await.map_err(VfsError::io)?;
        let body = reqwest::Body::wrap_stream(tokio_util::io::ReaderStream::new(fh));
        let resp = self
            .request(reqwest::Method::PUT, key, &[], "UNSIGNED-PAYLOAD")
            .header(reqwest::header::CONTENT_LENGTH, size.to_string())
            .body(body)
            .send()
            .await
            .map_err(net_err)?;
        if !resp.status().is_success() {
            return Err(map_status(resp.status(), key));
        }
        Ok(())
    }
}

// ---------------------------------------------------------------- helpers

fn make_id(key: &str) -> String {
    format!("{SCHEME}://{key}")
}

fn parent_key(key: &str) -> String {
    let trimmed = key.trim_end_matches('/');
    match trimmed.rsplit_once('/') {
        Some((parent, _)) => parent.to_string(),
        None => String::new(),
    }
}

fn join_key(parent: &str, name: &str) -> String {
    if parent.is_empty() {
        name.to_string()
    } else {
        format!("{}/{}", parent.trim_end_matches('/'), name)
    }
}

/// RFC 3986 unreserved set (`A-Z a-z 0-9 - . _ ~`) — SigV4 requires these
/// characters to stay literal, otherwise the signature will not match.
const AWS_ENCODE_SET: &percent_encoding::AsciiSet = &percent_encoding::NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'.')
    .remove(b'_')
    .remove(b'~');

fn encode_key(key: &str) -> String {
    key.split('/')
        .map(|seg| percent_encoding::utf8_percent_encode(seg, AWS_ENCODE_SET).to_string())
        .collect::<Vec<_>>()
        .join("/")
}

fn encode_query(value: &str) -> String {
    percent_encoding::utf8_percent_encode(value, AWS_ENCODE_SET).to_string()
}

fn hmac(key: &[u8], data: &[u8]) -> Vec<u8> {
    let mut mac = HmacSha256::new_from_slice(key).expect("hmac key");
    mac.update(data);
    mac.finalize().into_bytes().to_vec()
}

fn signing_key(secret: &str, date: &str, region: &str, service: &str) -> Vec<u8> {
    let k_date = hmac(format!("AWS4{secret}").as_bytes(), date.as_bytes());
    let k_region = hmac(&k_date, region.as_bytes());
    let k_service = hmac(&k_region, service.as_bytes());
    hmac(&k_service, b"aws4_request")
}

/// `YYYYMMDDTHHMMSSZ` + `YYYYMMDD` in UTC (no chrono dependency).
fn chrono_like_now() -> (String, String) {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let days = secs / 86_400;
    let rem = secs % 86_400;
    let (y, m, d) = civil_from_days(days as i64);
    let hh = rem / 3600;
    let mm = (rem % 3600) / 60;
    let ss = rem % 60;
    (
        format!("{y:04}{m:02}{d:02}T{hh:02}{mm:02}{ss:02}Z"),
        format!("{y:04}{m:02}{d:02}"),
    )
}

/// Howard Hinnant's days-from-civil inverse.
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

fn parse_iso8601_ms(s: &str) -> Option<i64> {
    // 2024-01-01T00:00:00.000Z
    let bytes = s.as_bytes();
    if bytes.len() < 19 {
        return None;
    }
    let num = |a: usize, b: usize| -> Option<i64> { s.get(a..b)?.parse().ok() };
    let (y, mo, d) = (num(0, 4)?, num(5, 7)?, num(8, 10)?);
    let (h, mi, se) = (num(11, 13)?, num(14, 16)?, num(17, 19)?);
    let days = days_from_civil(y, mo as u32, d as u32);
    Some(((days * 86_400 + h * 3600 + mi * 60 + se) as i64) * 1000)
}

fn days_from_civil(y: i64, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = (y - era * 400) as u64;
    let mp = if m > 2 { m - 3 } else { m + 9 } as u64;
    let doy = (153 * mp + 2) / 5 + d as u64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe as i64 - 719_468
}

fn map_status(status: reqwest::StatusCode, id: &str) -> VfsError {
    match status.as_u16() {
        401 | 403 => VfsError::PermissionDenied(format!("{id} (HTTP {status})")),
        404 => VfsError::NotFound(id.to_string()),
        409 => VfsError::AlreadyExists(id.to_string()),
        s if s >= 500 => VfsError::Network(format!("{id}: HTTP {s}")),
        s => VfsError::Io(format!("{id}: HTTP {s}")),
    }
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
