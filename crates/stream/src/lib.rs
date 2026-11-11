//! Loopback media streaming: expose any [`Vfs`] entry as an
//! `http://127.0.0.1` URL that native players (AVPlayer, ExoPlayer, mpv,
//! VLC) can open directly, seek included.
//!
//! The server translates `Range` requests into `Vfs::read_range` calls, so
//! any backend with `can_seek = true` is playable without the app writing a
//! single line of per-platform code. URLs carry a per-instance random token
//! so other local processes cannot enumerate or read the user's files.

mod http;
mod range;
mod share;

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use tokio::net::TcpListener;
use tokio::sync::watch;

use vfs_core::Vfs;

use http::{decode_id, encode_id, read_request, respond, status_for};
use range::parse as parse_range;

pub use share::ShareServer;

/// One running server instance. Cheap to keep alive: the accept loop is a
/// single task and idle servers own nothing but a socket.
pub struct StreamServer {
    token: String,
    addr: SocketAddr,
    stop: watch::Sender<bool>,
    task: tokio::task::JoinHandle<()>,
}

impl StreamServer {
    /// Bind on `127.0.0.1:0` (OS-assigned port) and start serving.
    pub async fn start(vfs: Arc<Vfs>) -> std::io::Result<Self> {
        let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0)).await?;
        let addr = listener.local_addr()?;
        let (stop, mut stopped) = watch::channel(false);
        let task_vfs = vfs.clone();
        let token = make_token();
        let task_token = token.clone();
        let task = tokio::spawn(async move {
            loop {
                tokio::select! {
                    _ = stopped.changed() => break,
                    accept = listener.accept() => {
                        match accept {
                            Ok((socket, _peer)) => {
                                let vfs = task_vfs.clone();
                                let token = task_token.clone();
                                tokio::spawn(async move {
                                    let _ = serve_one(vfs, token, socket).await;
                                });
                            }
                            Err(_) => tokio::task::yield_now().await,
                        }
                    }
                }
            }
        });
        Ok(Self {
            token,
            addr,
            stop,
            task,
        })
    }

    /// `http://127.0.0.1:PORT/<token>/<encoded id>` — hand this to the player.
    pub fn url_for(&self, id: &str) -> String {
        format!("http://{}/{}/{}", self.addr, self.token, encode_id(id))
    }

    pub fn port(&self) -> u16 {
        self.addr.port()
    }

    pub async fn shutdown(self) {
        let _ = self.stop.send(true);
        let _ = self.task.await;
    }
}

pub(crate) fn make_token() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let mixed = nanos as u64 ^ (nanos >> 64) as u64 ^ (std::process::id() as u64) << 32;
    format!("sf{mixed:016x}{:08x}", nanos as u32)
}

/// One request per connection; playback workloads open many small
/// connections on loopback, which is cheaper than implementing keep-alive.
async fn serve_one(
    vfs: Arc<Vfs>,
    token: String,
    mut socket: tokio::net::TcpStream,
) -> std::io::Result<()> {
    let Some(req) = read_request(&mut socket).await? else {
        return Ok(());
    };
    if req.method != "GET" && req.method != "HEAD" {
        respond(&mut socket, 405, "Method Not Allowed", &[]).await?;
        return Ok(());
    }
    let Some(rest) = req
        .path
        .strip_prefix('/')
        .and_then(|p| p.strip_prefix(&format!("{token}/")))
    else {
        respond(&mut socket, 404, "Not Found", &[]).await?;
        return Ok(());
    };
    let Some(id) = decode_id(rest) else {
        respond(&mut socket, 404, "Not Found", &[]).await?;
        return Ok(());
    };

    serve_entry(&vfs, &mut socket, &id, &req.method, req.range.as_deref()).await
}

/// Stat + range semantics + body streaming shared by the playback server
/// and the LAN [`ShareServer`] (ADR 0005).
pub(crate) async fn serve_entry(
    vfs: &Vfs,
    socket: &mut tokio::net::TcpStream,
    id: &str,
    method: &str,
    range: Option<&str>,
) -> std::io::Result<()> {
    let entry = match vfs.stat(id).await {
        Ok(entry) => entry,
        Err(err) => {
            let (code, text) = status_for(&err);
            respond(&mut *socket, code, text, &[]).await?;
            return Ok(());
        }
    };
    if entry.is_dir() {
        respond(&mut *socket, 404, "Not Found", &[]).await?;
        return Ok(());
    }

    let size = entry.size;
    let mime = entry.mime.as_deref().unwrap_or("application/octet-stream");
    let mut headers = vec![
        ("Accept-Ranges", "bytes".to_string()),
        ("Content-Type", mime.to_string()),
        ("Cache-Control", "no-store".to_string()),
    ];

    let body_range = match parse_range(range, size) {
        None => None,
        Some(Some(r)) => Some(r),
        Some(None) => {
            headers.push(("Content-Range", format!("bytes */{size}")));
            respond(&mut *socket, 416, "Range Not Satisfiable", &refs(&headers)).await?;
            return Ok(());
        }
    };

    let (status, text, start, end) = match body_range {
        Some(r) => {
            headers.push((
                "Content-Range",
                format!("bytes {}-{}/{size}", r.start, r.end),
            ));
            (206, "Partial Content", r.start, r.end)
        }
        None => (200, "OK", 0, size.saturating_sub(1)),
    };
    let body_len = if size == 0 { 0 } else { end - start + 1 };
    headers.push(("Content-Length", body_len.to_string()));
    respond(&mut *socket, status, text, &refs(&headers)).await?;

    if method == "HEAD" || body_len == 0 {
        return Ok(());
    }

    let mut offset = start;
    while offset <= end {
        let want = ((end - offset + 1) as usize).min(vfs_core::DEFAULT_CHUNK_SIZE);
        let chunk = match vfs.read_range(id, offset, want).await {
            Ok(c) if !c.is_empty() => c,
            Ok(_) => break,  // file shrank mid-stream
            Err(_) => break, // socket is our only error channel at this point
        };
        let written = chunk.len() as u64;
        if tokio::io::AsyncWriteExt::write_all(socket, &chunk)
            .await
            .is_err()
        {
            break; // player cancelled the seek/read
        }
        offset += written;
        if written < want as u64 {
            break; // short read hit EOF
        }
    }
    Ok(())
}

fn refs<'a>(headers: &'a [(&'a str, String)]) -> Vec<(&'a str, &'a str)> {
    headers.iter().map(|(k, v)| (*k, v.as_str())).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_root(tag: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "sfiles-stream-{tag}-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

    async fn fixture() -> (StreamServer, String, std::path::PathBuf) {
        let root = temp_root("srv");
        let vfs = Arc::new(Vfs::with_local_root(&root).unwrap());
        let file_id = format!("{}/movie 片段.mp4", vfs.local_root());
        let payload: Vec<u8> = (0..100_000u32).map(|i| (i % 251) as u8).collect();
        vfs.write_range(&file_id, 0, &payload).await.unwrap();
        let server = StreamServer::start(vfs).await.unwrap();
        (server, file_id, root)
    }

    #[tokio::test]
    async fn full_get_and_head() {
        let (server, file_id, root) = fixture().await;
        let client = reqwest::Client::new();
        let url = server.url_for(&file_id);

        let resp = client.get(&url).send().await.unwrap();
        assert_eq!(resp.status(), 200);
        assert_eq!(resp.headers()["content-type"], "video/mp4");
        assert_eq!(resp.headers()["accept-ranges"], "bytes");
        let body = resp.bytes().await.unwrap();
        assert_eq!(body.len(), 100_000);
        assert_eq!(&body[250..254], &[250, 0, 1, 2]);

        let resp = client.head(&url).send().await.unwrap();
        assert_eq!(resp.status(), 200);
        assert_eq!(resp.headers()["content-length"], "100000");
        assert!(resp.bytes().await.unwrap().is_empty());

        server.shutdown().await;
        std::fs::remove_dir_all(&root).ok();
    }

    #[tokio::test]
    async fn range_forms() {
        let (server, file_id, root) = fixture().await;
        let client = reqwest::Client::new();
        let url = server.url_for(&file_id);

        let resp = client
            .get(&url)
            .header("Range", "bytes=1000-1999")
            .send()
            .await
            .unwrap();
        assert_eq!(resp.status(), 206);
        assert_eq!(resp.headers()["content-range"], "bytes 1000-1999/100000");
        let body = resp.bytes().await.unwrap();
        assert_eq!(body.len(), 1000);
        assert_eq!(body[0], (1000 % 251) as u8);

        // Open-ended
        let resp = client
            .get(&url)
            .header("Range", "bytes=99990-")
            .send()
            .await
            .unwrap();
        assert_eq!(resp.bytes().await.unwrap().len(), 10);

        // Suffix
        let resp = client
            .get(&url)
            .header("Range", "bytes=-16")
            .send()
            .await
            .unwrap();
        let body = resp.bytes().await.unwrap();
        assert_eq!(body.len(), 16);

        // Beyond EOF -> 416 with size hint
        let resp = client
            .get(&url)
            .header("Range", "bytes=200000-")
            .send()
            .await
            .unwrap();
        assert_eq!(resp.status(), 416);
        assert_eq!(resp.headers()["content-range"], "bytes */100000");

        server.shutdown().await;
        std::fs::remove_dir_all(&root).ok();
    }

    #[tokio::test]
    async fn guards_token_and_missing_targets() {
        let (server, _file_id, root) = fixture().await;
        let client = reqwest::Client::new();
        let base = format!("http://127.0.0.1:{}", server.port());

        let resp = client
            .get(format!("{base}/wrongtoken/anything"))
            .send()
            .await
            .unwrap();
        assert_eq!(resp.status(), 404);

        let resp = client
            .get(server.url_for(&format!("{}/nope.mp4", root.to_string_lossy())))
            .send()
            .await
            .unwrap();
        assert_eq!(resp.status(), 404);

        server.shutdown().await;
        std::fs::remove_dir_all(&root).ok();
    }

    #[tokio::test]
    async fn concurrent_seek_storm() {
        let (server, file_id, root) = fixture().await;
        let client = reqwest::Client::new();
        let mut joins = Vec::new();
        for n in 0..32u64 {
            let url = server.url_for(&file_id);
            let client = client.clone();
            joins.push(tokio::spawn(async move {
                let start = n * 3000;
                let resp = client
                    .get(&url)
                    .header("Range", format!("bytes={start}-{}", start + 511))
                    .send()
                    .await
                    .unwrap();
                assert_eq!(resp.status(), 206);
                let body = resp.bytes().await.unwrap();
                assert_eq!(body.len(), 512);
                assert_eq!(body[0], (start % 251) as u8);
            }));
        }
        for j in joins {
            j.await.unwrap();
        }
        server.shutdown().await;
        std::fs::remove_dir_all(&root).ok();
    }
}
