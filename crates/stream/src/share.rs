//! LAN nearby-share server (ADR 0005): serve a fixed selection of VFS files
//! at `http://<lan-ip>:PORT/<token>/` —
//!
//! * `GET /`            → HTML 索引页（浏览器免安装直接收）
//! * `GET /manifest.json` → JSON 清单（App 接收流程用）
//! * `GET|HEAD /f/<idx>/<name>` → 文件内容，Range 分块语义与播放服务一致
//!
//! 安全边界与播放服务相同：随机 token 防枚举；URL 不含 VFS id，仅暴露
//! 本次入选文件；会话随 UI 生命周期关闭（`shutdown` / `Drop`）。

use std::net::{Ipv4Addr, SocketAddr};
use std::sync::Arc;

use tokio::net::{TcpListener, TcpStream};
use tokio::sync::watch;

use vfs_core::{Entry, Vfs};

use crate::http::{encode_id, read_request, respond};
use crate::{make_token, serve_entry};

/// Files fixed at share-creation time (names/sizes/mimes don't re-stat per
/// request; content is always read live from the backend).
#[derive(Debug, Clone)]
pub struct ShareEntry {
    pub id: String,
    pub name: String,
    pub size: u64,
    pub mime: Option<String>,
}

impl From<Entry> for ShareEntry {
    fn from(entry: Entry) -> Self {
        Self {
            id: entry.id,
            name: entry.name,
            size: entry.size,
            mime: entry.mime,
        }
    }
}

/// One running share session. Cheap: no IO until a client connects.
pub struct ShareServer {
    token: String,
    addr: SocketAddr,
    lan_ip: Ipv4Addr,
    count: usize,
    stop: watch::Sender<bool>,
    task: Option<tokio::task::JoinHandle<()>>,
}

impl ShareServer {
    /// Bind a LAN-reachable port and start serving `entries`.
    pub async fn start(vfs: Arc<Vfs>, entries: Vec<Entry>) -> std::io::Result<Self> {
        let listener = TcpListener::bind((Ipv4Addr::UNSPECIFIED, 0)).await?;
        let addr = listener.local_addr()?;
        let lan_ip = detect_lan_ipv4().unwrap_or(Ipv4Addr::LOCALHOST);
        let token = make_token();
        let files: Arc<Vec<ShareEntry>> =
            Arc::new(entries.into_iter().map(ShareEntry::from).collect());
        let count = files.len();

        let (stop, mut stopped) = watch::channel(false);
        let task_token = token.clone();
        let task = tokio::spawn(async move {
            loop {
                tokio::select! {
                    _ = stopped.changed() => break,
                    accept = listener.accept() => {
                        match accept {
                            Ok((socket, _peer)) => {
                                let vfs = vfs.clone();
                                let token = task_token.clone();
                                let files = files.clone();
                                tokio::spawn(async move {
                                    let _ = serve_one(vfs, token, files, socket).await;
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
            lan_ip,
            count,
            stop,
            task: Some(task),
        })
    }

    /// 二维码/链接内容（含索引页路径）。
    pub fn url(&self) -> String {
        format!(
            "http://{}:{}/{}/",
            self.lan_ip,
            self.addr.port(),
            self.token
        )
    }

    /// 与该 share 同根 URL 拼相对地址（manifest 里的 `f/…` 交给客户端拼）。
    pub fn base_url(&self) -> String {
        self.url()
    }

    pub fn port(&self) -> u16 {
        self.addr.port()
    }

    pub fn file_count(&self) -> usize {
        self.count
    }

    pub async fn shutdown(mut self) {
        let _ = self.stop.send(true);
        if let Some(task) = self.task.take() {
            let _ = task.await;
        }
    }
}

impl Drop for ShareServer {
    fn drop(&mut self) {
        // 立刻放行 accept 循环；端口随任务退出释放（不等 JoinHandle）。
        let _ = self.stop.send(true);
    }
}

/// UDP connect 只做路由选择、不发包：拿本机出网卡的 LAN IPv4。
/// 无网卡/飞行模式时回落 127.0.0.1（链接打不开的提示交给 UI 文案兜底）。
fn detect_lan_ipv4() -> std::io::Result<Ipv4Addr> {
    let socket = std::net::UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0))?;
    // TEST-NET-1（RFC 5737 保留段）：永远不可达，所以绝不会真发包
    socket.connect((Ipv4Addr::new(192, 0, 2, 1), 80))?;
    match socket.local_addr()?.ip() {
        std::net::IpAddr::V4(v4) => Ok(v4),
        v6 => Err(std::io::Error::new(
            std::io::ErrorKind::AddrNotAvailable,
            format!("no LAN IPv4 (got {v6})"),
        )),
    }
}

async fn serve_one(
    vfs: Arc<Vfs>,
    token: String,
    files: Arc<Vec<ShareEntry>>,
    mut socket: TcpStream,
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
    let rest = rest.trim_matches('/');
    match rest {
        // 索引页（浏览器接收）
        "" => {
            serve_bytes(
                &mut socket,
                &req.method,
                "text/html; charset=utf-8",
                index_html(&files).as_bytes(),
            )
            .await?
        }
        // App 接收清单
        "manifest.json" => {
            serve_bytes(
                &mut socket,
                &req.method,
                "application/json",
                manifest_json(&files).as_bytes(),
            )
            .await?
        }
        _ => {
            // /f/<idx>/<display-name>（name 段仅展示用，路由只看 idx）
            let idx = rest
                .strip_prefix("f/")
                .and_then(|tail| tail.split('/').next())
                .and_then(|n| n.parse::<usize>().ok());
            match idx.and_then(|i| files.get(i)) {
                None => respond(&mut socket, 404, "Not Found", &[]).await?,
                Some(file) => {
                    serve_entry(
                        &vfs,
                        &mut socket,
                        &file.id,
                        &req.method,
                        req.range.as_deref(),
                    )
                    .await?
                }
            }
        }
    }
    Ok(())
}

/// 小体量静态响应（索引页/manifest）：respond 只写头，这里补 body。
async fn serve_bytes(
    socket: &mut TcpStream,
    method: &str,
    content_type: &str,
    body: &[u8],
) -> std::io::Result<()> {
    respond(
        socket,
        200,
        "OK",
        &[
            ("Content-Type", content_type),
            ("Cache-Control", "no-store"),
            ("Content-Length", &body.len().to_string()),
        ],
    )
    .await?;
    if method != "HEAD" {
        tokio::io::AsyncWriteExt::write_all(socket, body).await?;
    }
    Ok(())
}

/// 发送端与接收端共用一套视觉语言：暖米白底 + 白色圆角卡 + 发丝分隔线 +
/// 品牌蓝/暖棕点缀；无外部资源（局域网离线也能正常渲染），深色跟随系统。
fn index_html(files: &[ShareEntry]) -> String {
    let total: u64 = files.iter().map(|f| f.size).sum();
    let mut out = String::with_capacity(4096 + files.len() * 320);
    out.push_str(
        r#"<!doctype html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>superfiles · 文件分享</title>
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'%3E%3Crect width='64' height='64' rx='16' fill='%23F0EBE3'/%3E%3Ctext x='32' y='42' font-size='28' font-family='system-ui' font-weight='700' text-anchor='middle' fill='%23A18460'%3Esf%3C/text%3E%3C/svg%3E">
<style>
:root{
  --bg:#F8F7F4; --card:#FFFFFF; --ink:#292E35; --muted:#777D86; --line:rgba(41,46,53,.08);
  --primary:#466DA6; --primary-soft:#EAF0F8; --warm:#A18460; --warm-soft:#F0EBE3;
  --green:#6F8D7D; --green-soft:#EDF2ED; --pdf-bg:#F6ECE8; --pdf-fg:#B7796E;
  --shadow:0 12px 32px rgba(41,46,53,.06);
}
@media (prefers-color-scheme: dark){
  :root{
    --bg:#1A1916; --card:#26231F; --ink:#E7E5E1; --muted:#A0A5AD; --line:rgba(255,255,255,.08);
    --primary:#A9C3E6; --primary-soft:#22324A; --warm:#C7A87F; --warm-soft:#33291F;
    --green:#9CB8A9; --green-soft:#26332A; --pdf-bg:#3B2925; --pdf-fg:#D9A198;
    --shadow:0 12px 32px rgba(0,0,0,.28);
  }
}
*{box-sizing:border-box}
body{
  margin:0; min-height:100vh; background:var(--bg); color:var(--ink);
  font-family:"Noto Sans SC","PingFang SC","Microsoft YaHei",system-ui,-apple-system,sans-serif;
  -webkit-font-smoothing:antialiased;
}
.wrap{max-width:720px;margin:0 auto;padding:48px 20px 64px}
.card{
  background:linear-gradient(165deg,var(--card) 0%,var(--card) 68%,var(--warm-soft) 165%);
  border:1px solid var(--line);border-radius:26px;box-shadow:var(--shadow);overflow:hidden;
}
.head{padding:30px 30px 18px}
.brand{display:flex;align-items:center;gap:12px;margin-bottom:24px}
.logo{
  width:44px;height:44px;border-radius:13px;background:var(--warm-soft);color:var(--warm);
  display:grid;place-items:center;font-weight:700;font-size:17px;letter-spacing:.5px;
}
.wordmark{font-size:24px;font-weight:700;line-height:1.1;letter-spacing:.2px}
.tagline{font-size:10px;letter-spacing:2.4px;color:var(--muted);margin-top:3px}
h1{font-size:26px;line-height:1.25;font-weight:700;margin:0 0 10px}
.lead{display:flex;flex-wrap:wrap;align-items:center;gap:8px;margin:0;color:var(--muted);font-size:13px}
.pill{
  display:inline-flex;align-items:center;gap:5px;padding:3px 9px;border-radius:999px;
  background:var(--green-soft);color:var(--green);font-size:11px;font-weight:500;
}
.pill::before{content:"";width:6px;height:6px;border-radius:50%;background:var(--green)}
.hint{margin:18px 0 0;color:var(--muted);font-size:12px;line-height:1.7}
.list{border-top:1px solid var(--line);margin-top:20px}
.file{
  display:flex;align-items:center;gap:14px;padding:15px 30px;
  color:var(--ink);text-decoration:none;transition:background .16s ease;
}
.file + .file{border-top:1px solid var(--line)}
.file:hover{background:var(--primary-soft)}
.badge{
  flex:none;width:44px;height:48px;border-radius:10px;display:grid;place-items:center;
  font-size:10px;font-weight:700;letter-spacing:.4px;
}
.badge.pdf{background:var(--pdf-bg);color:var(--pdf-fg)}
.badge.doc{background:var(--primary-soft);color:var(--primary)}
.badge.sheet{background:var(--green-soft);color:var(--green)}
.badge.other{background:var(--warm-soft);color:var(--warm)}
.meta{display:flex;flex-direction:column;gap:3px;min-width:0;flex:1}
.name{font-size:14px;font-weight:500;line-height:1.35;overflow-wrap:anywhere;word-break:normal}
.size{font-size:11px;color:var(--muted)}
.dl{
  flex:none;width:32px;height:32px;border-radius:50%;background:var(--primary-soft);color:var(--primary);
  display:grid;place-items:center;font-size:15px;font-weight:700;transition:background .16s ease,color .16s ease;
}
.file:hover .dl{background:var(--primary);color:#fff}
.foot{padding:18px 30px 26px;text-align:center}
.cta{
  display:block;padding:12px 16px;border-radius:12px;background:var(--primary-soft);
  color:var(--primary);font-size:13px;font-weight:600;letter-spacing:.2px;
}
.fine{margin-top:10px;color:var(--muted);font-size:11px;line-height:1.7}
@media (max-width:420px){
  .wrap{padding:20px 12px 40px}
  .card{border-radius:22px}
  .head{padding:22px 18px 14px}
  .brand{margin-bottom:20px;gap:10px}
  .logo{width:40px;height:40px;border-radius:12px}
  .wordmark{font-size:21px}
  h1{font-size:22px}
  .file{padding:14px 18px;gap:12px}
  .foot{padding:16px 18px 22px}
}
</style>
</head>
<body>
<div class="wrap">
<div class="card">
  <div class="head">
    <div class="brand">
      <span class="logo">sf</span>
      <div><div class="wordmark">superfiles</div><div class="tagline">FILE SHARING</div></div>
    </div>
    <h1>文件分享</h1>
    <p class="lead"><span class="pill">局域网直连</span><span>__SUMMARY__</span></p>
    <p class="hint">接收方无需安装 App，点击文件即可下载；请保持与发送方连接同一 Wi-Fi。</p>
  </div>
  <div class="list">
"#,
    );
    for (idx, file) in files.iter().enumerate() {
        let (label, class) = file_badge(&file.name);
        out.push_str(&format!(
            "<a class=\"file\" href=\"f/{idx}/{}\" download=\"{}\">\
             <span class=\"badge {class}\">{label}</span>\
             <span class=\"meta\"><span class=\"name\">{}</span>\
             <span class=\"size\">{}</span></span>\
             <span class=\"dl\">&#8595;</span></a>",
            encode_id(&file.name),
            html_escape(&file.name),
            html_escape(&file.name),
            human_size(file.size),
        ));
    }
    out.push_str(
        "</div>\
         <div class=\"foot\">\
         <div class=\"cta\">点击任意文件即可下载</div>\
         <div class=\"fine\">由 superfiles 就近分享提供 · 发送方关闭后立即失效</div>\
         </div>\
         </div>\
         </div>\
         </body></html>",
    );
    out.replace(
        "__SUMMARY__",
        &format!("{} 个文件 · {}", files.len(), human_size(total)),
    )
}

/// 文件徽章：扩展名 / 配色与 App 内 fileBadgeOf 同一套语义。
fn file_badge(name: &str) -> (String, &'static str) {
    let ext = name
        .rsplit_once('.')
        .map(|(_, e)| e.to_ascii_lowercase())
        .filter(|e| !e.is_empty() && e.len() <= 5)
        .unwrap_or_default();
    let class = match ext.as_str() {
        "pdf" => "pdf",
        "doc" | "docx" | "txt" | "md" => "doc",
        "xls" | "xlsx" | "csv" => "sheet",
        _ => "other",
    };
    let label = if ext.is_empty() {
        "FILE".to_string()
    } else {
        ext.to_uppercase()
    };
    (label, class)
}

fn manifest_json(files: &[ShareEntry]) -> String {
    let mut out = String::from("{\"files\":[");
    for (idx, file) in files.iter().enumerate() {
        if idx > 0 {
            out.push(',');
        }
        let mime = file
            .mime
            .as_deref()
            .map(json_escape)
            .map(|m| format!("\"{m}\""))
            .unwrap_or_else(|| "null".into());
        out.push_str(&format!(
            "{{\"name\":\"{}\",\"size\":{},\"mime\":{},\"url\":\"f/{idx}/{}\"}}",
            json_escape(&file.name),
            file.size,
            mime,
            encode_id(&file.name),
        ));
    }
    out.push_str("]}");
    out
}

fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

fn human_size(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1024.0 && unit < UNITS.len() - 1 {
        value /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{bytes} B")
    } else {
        format!("{value:.1} {}", UNITS[unit])
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_root(tag: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "sfiles-share-{tag}-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

    async fn fixture() -> (ShareServer, std::path::PathBuf) {
        let root = temp_root("srv");
        let vfs = Arc::new(Vfs::with_local_root(&root).unwrap());
        let video = format!("{}/demo 视频.mp4", vfs.local_root());
        let doc = format!("{}/说明\"文档.txt", vfs.local_root());
        let payload: Vec<u8> = (0..50_000u32).map(|i| (i % 251) as u8).collect();
        vfs.write_range(&video, 0, &payload).await.unwrap();
        vfs.write_range(&doc, 0, b"hello share").await.unwrap();
        let entries = vec![
            vfs.stat(&video).await.unwrap(),
            vfs.stat(&doc).await.unwrap(),
        ];
        let server = ShareServer::start(vfs, entries).await.unwrap();
        (server, root)
    }

    #[tokio::test]
    async fn serves_index_manifest_and_files() {
        let (server, root) = fixture().await;
        let client = reqwest::Client::new();
        let base = server.base_url();

        // 索引页：中文名 + 大小可读
        let html = client
            .get(&base)
            .send()
            .await
            .unwrap()
            .text()
            .await
            .unwrap();
        assert!(html.contains("demo 视频.mp4"));
        assert!(html.contains("48.8 KB"));
        // 与 App 同源的视觉语言：品牌、汇总、文件徽章
        assert!(html.contains("superfiles"));
        assert!(html.contains("局域网直连"));
        assert!(html.contains("2 个文件"));
        assert!(html.contains("badge other"));
        assert!(html.contains("badge doc"));
        // HTML 转义：带引号的文件名不能破结构
        assert!(html.contains("说明&quot;文档.txt"));
        assert!(!html.contains("\"文档.txt\"</a>"));

        // manifest：name/size/mime/url 齐全且 JSON 转义安全
        let manifest = client
            .get(format!("{base}manifest.json"))
            .send()
            .await
            .unwrap()
            .text()
            .await
            .unwrap();
        assert!(manifest.contains("\"name\":\"demo 视频.mp4\""));
        assert!(manifest.contains("\"size\":50000"));
        assert!(manifest.contains("\"mime\":\"video/mp4\""));
        assert!(manifest.contains("说明\\\"文档.txt")); // 引号已转义（\"说明\"文档..." 不会原样出现）
        assert!(manifest.contains("\"url\":\"f/0/"));

        // 文件内容（经索引 idx 路由；URL 不含 VFS id）
        let body = client
            .get(format!("{base}f/0/demo%20%E8%A7%86%E9%A2%91.mp4"))
            .send()
            .await
            .unwrap()
            .bytes()
            .await
            .unwrap();
        assert_eq!(body.len(), 50_000);
        assert_eq!(body[1000], (1000 % 251) as u8);

        // Range 语义与播放服务一致（接收方断点续传/边下边播的基础）
        let resp = client
            .get(format!("{base}f/1/x.txt"))
            .header("Range", "bytes=6-10")
            .send()
            .await
            .unwrap();
        assert_eq!(resp.status(), 206);
        assert_eq!(resp.bytes().await.unwrap().as_ref(), b"share");

        // 越界 idx / 错误 token → 404
        assert_eq!(
            client
                .get(format!("{base}f/9/ghost"))
                .send()
                .await
                .unwrap()
                .status(),
            404
        );
        let port = server.port();
        assert_eq!(
            client
                .get(format!("http://127.0.0.1:{port}/wrongtoken/manifest.json"))
                .send()
                .await
                .unwrap()
                .status(),
            404
        );

        server.shutdown().await;
        std::fs::remove_dir_all(&root).ok();
    }

    #[tokio::test]
    async fn replaces_handle_cleanly_on_shutdown() {
        let (server, root) = fixture().await;
        let port = server.port();
        server.shutdown().await;
        // 关机后端口无残留监听
        assert!(std::net::TcpStream::connect((std::net::Ipv4Addr::LOCALHOST, port)).is_err());
        std::fs::remove_dir_all(&root).ok();
    }
}
