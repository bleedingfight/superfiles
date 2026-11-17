//! Shared plumbing for OAuth2 cloud backends (Google Drive, Dropbox, ...).
//!
//! Two concerns repeat across every HTTP cloud API:
//!
//! * **OAuth2 bearer auth with in-place refresh** ([`CloudAuth`]). The durable
//!   token lives in the platform keychain (`CloudAuthManager` on Android); this
//!   is the runtime mirror a mount holds. On a 401 the backend refreshes once
//!   and retries.
//! * **Upload spooling** ([`SpoolPool`]). Cloud APIs offer no random write, so
//!   the transfer engine's sequential `write_range` calls are staged into a
//!   local temp file and pushed up whole on `truncate` (the engine's terminal
//!   call) — the same "temp file + whole upload" strategy the roadmap assigns
//!   to `can_random_write = false` targets.

use std::collections::HashMap;
use std::io::{Seek, SeekFrom, Write};
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::error::{Result, VfsError};

pub const USER_AGENT: &str = concat!("SuperFiles/", env!("CARGO_PKG_VERSION"));

/// Chunk size for resumable/session uploads (8 MiB).
pub const UPLOAD_CHUNK: usize = 8 * 1024 * 1024;

/// Shared HTTP client for cloud backends.
pub fn http_client() -> reqwest::Client {
    reqwest::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(20))
        .user_agent(USER_AGENT)
        .build()
        .expect("cloud http client init")
}

/// Send a request with bearer auth, bounded retries and a single 401-refresh.
///
/// Transport errors are retried for every method; server errors (5xx) only
/// when the caller marks the request safely repeatable (`retry_server_errors`).
pub async fn send_with_auth(
    client: &reqwest::Client,
    auth: &CloudAuth,
    retry_server_errors: bool,
    build: impl Fn(&reqwest::Client) -> reqwest::RequestBuilder,
) -> Result<reqwest::Response> {
    const MAX_ATTEMPTS: u32 = 3;
    let mut delay = std::time::Duration::from_millis(200);
    let mut attempt = 0u32;
    let mut refreshed = false;
    loop {
        let req = build(client).bearer_auth(&auth.bearer());
        match req.send().await {
            Ok(resp) => {
                if resp.status() == reqwest::StatusCode::UNAUTHORIZED && !refreshed {
                    auth.refresh().await?;
                    refreshed = true;
                    continue;
                }
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

/// OAuth2 bearer credentials with in-place refresh.
pub struct CloudAuth {
    state: Mutex<AuthState>,
    client: reqwest::Client,
}

struct AuthState {
    access_token: String,
    refresh_token: Option<String>,
    client_id: String,
    client_secret: Option<String>,
    token_url: String,
}

impl CloudAuth {
    pub fn new(
        client: reqwest::Client,
        access_token: String,
        refresh_token: Option<String>,
        client_id: String,
        client_secret: Option<String>,
        token_url: String,
    ) -> Self {
        Self {
            state: Mutex::new(AuthState {
                access_token,
                refresh_token,
                client_id,
                client_secret,
                token_url,
            }),
            client,
        }
    }

    pub fn bearer(&self) -> String {
        self.state.lock().unwrap().access_token.clone()
    }

    /// Mint a fresh access token via the refresh-token grant.
    pub async fn refresh(&self) -> Result<()> {
        let (refresh_token, client_id, client_secret, token_url) = {
            let s = self.state.lock().unwrap();
            (
                s.refresh_token.clone(),
                s.client_id.clone(),
                s.client_secret.clone(),
                s.token_url.clone(),
            )
        };
        let refresh_token = refresh_token
            .ok_or_else(|| VfsError::PermissionDenied("no refresh token available".into()))?;
        let mut form = format!(
            "grant_type=refresh_token&refresh_token={}&client_id={}",
            form_encode(&refresh_token),
            form_encode(&client_id)
        );
        if let Some(secret) = client_secret {
            form.push_str("&client_secret=");
            form.push_str(&form_encode(&secret));
        }
        let resp = self
            .client
            .post(&token_url)
            .header(
                reqwest::header::CONTENT_TYPE,
                "application/x-www-form-urlencoded",
            )
            .body(form)
            .send()
            .await
            .map_err(|e| VfsError::Network(format!("token refresh request failed: {e}")))?;
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        if !status.is_success() {
            return Err(VfsError::PermissionDenied(format!(
                "token refresh rejected (HTTP {status}): {body}"
            )));
        }
        let json: serde_json::Value = serde_json::from_str(&body)
            .map_err(|e| VfsError::Network(format!("invalid token response: {e}")))?;
        let access = json
            .get("access_token")
            .and_then(|v| v.as_str())
            .ok_or_else(|| VfsError::Network("token response missing access_token".into()))?;
        {
            let mut st = self.state.lock().unwrap();
            st.access_token = access.to_string();
            // Microsoft / Box rotate the refresh token on every refresh: the
            // old one is invalidated, so keep the new value in memory.
            if let Some(next) = json.get("refresh_token").and_then(|v| v.as_str()) {
                if !next.is_empty() {
                    st.refresh_token = Some(next.to_string());
                }
            }
        }
        Ok(())
    }
}

fn form_encode(value: &str) -> String {
    percent_encoding::utf8_percent_encode(value, percent_encoding::NON_ALPHANUMERIC).to_string()
}

/// Stage a not-yet-uploaded file on local disk. Cloud APIs cannot write at an
/// arbitrary offset, so sequential `write_range` calls are buffered here and
/// pushed up whole by the backend's `truncate` implementation.
pub struct Spool {
    pub path: PathBuf,
    /// Remote parent id/path (backend-specific encoding).
    pub parent: String,
    /// Remote file name.
    pub name: String,
}

pub struct SpoolPool {
    entries: Mutex<HashMap<String, Spool>>,
    dir: PathBuf,
}

impl SpoolPool {
    pub fn new() -> std::sync::Arc<Self> {
        let dir = std::env::temp_dir().join(format!(
            "superfiles-cloud-{}-{}",
            std::process::id(),
            now_nanos()
        ));
        let _ = std::fs::create_dir_all(&dir);
        std::sync::Arc::new(Self {
            entries: Mutex::new(HashMap::new()),
            dir,
        })
    }

    pub fn write(
        &self,
        id: &str,
        offset: u64,
        data: &[u8],
        parent: String,
        name: String,
    ) -> Result<()> {
        let path = {
            let mut entries = self.entries.lock().unwrap();
            if let Some(spool) = entries.get(id) {
                spool.path.clone()
            } else {
                let path = self.dir.join(format!("{}.bin", entries.len()));
                entries.insert(
                    id.to_string(),
                    Spool {
                        path: path.clone(),
                        parent,
                        name,
                    },
                );
                path
            }
        };
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .write(true)
            .open(&path)
            .map_err(VfsError::io)?;
        file.seek(SeekFrom::Start(offset)).map_err(VfsError::io)?;
        file.write_all(data).map_err(VfsError::io)?;
        Ok(())
    }

    pub fn take(&self, id: &str) -> Option<Spool> {
        self.entries.lock().unwrap().remove(id)
    }
}

impl Drop for SpoolPool {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn now_nanos() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0)
}

/// Parse an RFC 3339 timestamp (`2024-03-05T12:34:56.789Z`) to epoch
/// milliseconds. Assumes UTC; offsets are tolerated but ignored.
pub fn parse_rfc3339_ms(s: &str) -> Option<i64> {
    let s = s.trim();
    let (date, rest) = s.split_once('T')?;

    let mut date_it = date.split('-');
    let year: i64 = date_it.next()?.parse().ok()?;
    let month: u32 = date_it.next()?.parse().ok()?;
    let day: u32 = date_it.next()?.parse().ok()?;

    let rest = rest.trim_end_matches(['Z', 'z']);
    // Strip a trailing numeric offset (+08:00 / -05:00) if present.
    let rest = match rest.find(['+', '-']) {
        Some(idx) if idx > 0 => &rest[..idx],
        _ => rest,
    };

    let mut time_it = rest.split(':');
    let hour: i64 = time_it.next()?.parse().ok()?;
    let minute: i64 = time_it.next()?.parse().ok()?;
    let sec_str = time_it.next()?;
    let (sec, millis) = match sec_str.split_once('.') {
        Some((whole, frac)) => {
            let sec: i64 = whole.parse().ok()?;
            let bytes = frac.as_bytes();
            let mut ms = 0i64;
            for &b in bytes.iter().take(3) {
                ms = ms * 10 + (b as i64 - b'0' as i64);
            }
            ms *= 10i64.pow((3usize.saturating_sub(bytes.len().min(3))) as u32);
            (sec, ms)
        }
        None => (sec_str.parse().ok()?, 0),
    };

    let days = days_from_civil(year, month, day);
    let total_secs = days * 86_400 + hour * 3_600 + minute * 60 + sec;
    Some(total_secs * 1000 + millis)
}

/// Days since 1970-01-01 for a civil date (Howard Hinnant's algorithm).
fn days_from_civil(y: i64, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = ((m + 9) % 12) as i64;
    let doy = (153 * mp + 2) / 5 + (d as i64) - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_rfc3339() {
        assert_eq!(
            parse_rfc3339_ms("2024-03-05T12:34:56.789Z"),
            Some(1_709_642_096_789)
        );
        assert_eq!(
            parse_rfc3339_ms("2015-05-12T15:50:38Z"),
            Some(1_431_445_838_000)
        );
        assert_eq!(parse_rfc3339_ms("1970-01-01T00:00:00Z"), Some(0));
    }
}
