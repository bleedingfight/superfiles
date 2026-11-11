use std::collections::{HashMap, VecDeque};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use rand::RngCore;
use sha2::{Digest, Sha256};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream, UdpSocket};
use tokio::sync::{watch, Mutex, Notify};
use tokio::task::JoinHandle;
use tokio_rustls::TlsAcceptor;
use vfs_core::Vfs;

use crate::cert::Identity;
use crate::client;
use crate::error::{Error, Result};
use crate::http::{self, query_param};
use crate::protocol::{
    DeviceInfo, DeviceType, PrepareUpload, PrepareUploadResponse,
};
use crate::{DEFAULT_PORT, MULTICAST_GROUP};

/// Runtime configuration. `dest_dir` is a VFS id (local absolute path or a
/// mounted NAS root); received files are placed there directly.
#[derive(Debug, Clone)]
pub struct LocalSendConfig {
    pub alias: String,
    pub device_model: String,
    pub device_type: DeviceType,
    pub port: u16,
    /// Directory for the persistent certificate/private key.
    pub store_dir: PathBuf,
    /// VFS id of the receive destination.
    pub dest_dir: String,
    /// Optional 6-digit PIN forwarded as `?pin=`.
    pub pin: Option<String>,
    pub enable_discovery: bool,
    /// Security: stop the HTTPS server after this many seconds with no
    /// transfer session/upload activity. `0` disables the idle shutdown.
    pub idle_timeout_secs: u64,
}

impl Default for LocalSendConfig {
    fn default() -> Self {
        Self {
            alias: "superfiles".into(),
            device_model: String::new(),
            device_type: DeviceType::Mobile,
            port: DEFAULT_PORT,
            store_dir: PathBuf::from("."),
            dest_dir: String::new(),
            pin: None,
            enable_discovery: true,
            idle_timeout_secs: 300,
        }
    }
}

struct Session {
    peer_ip: IpAddr,
    files: HashMap<String, SessionFile>,
    created: Instant,
}

struct SessionFile {
    token: String,
    name: String,
    size: u64,
    sha256: Option<String>,
    temp_name: Option<String>,
    temp_id: Option<String>,
    done: bool,
}

struct State {
    vfs: Arc<Vfs>,
    identity: Identity,
    info: DeviceInfo,
    dest_dir: String,
    pin: Option<String>,
    sessions: Mutex<HashMap<String, Session>>,
    peers: Mutex<HashMap<String, client::DiscoveredPeer>>,
    /// Fires an immediate multicast announcement (UI refresh).
    announce: Arc<Notify>,
    /// Last transfer-related activity (register alone does not count, or
    /// discovery chatter would keep the server alive forever).
    last_activity_ms: AtomicU64,
    /// Set when the idle watchdog or `stop()` shuts the server down.
    stopped: AtomicBool,
    shutdown: watch::Sender<bool>,
    idle_timeout: Duration,
    /// Recent protocol errors, surfaced in the UI to make interop failures
    /// actionable (e.g. which field a third-party client sent wrong).
    errors: Mutex<VecDeque<String>>,
}

pub struct LocalSendService {
    state: Arc<State>,
    port: u16,
    shutdown: watch::Sender<bool>,
    tasks: Mutex<Vec<JoinHandle<()>>>,
}

impl LocalSendService {
    pub async fn start(vfs: Arc<Vfs>, config: LocalSendConfig) -> Result<Self> {
        if config.dest_dir.is_empty() {
            return Err(Error::Protocol("receive destination is empty".into()));
        }
        if !config.port.eq(&0) && config.port < 1024 && config.port != DEFAULT_PORT {
            return Err(Error::Protocol("port must be >= 1024".into()));
        }
        let identity = Identity::load_or_create(&config.store_dir, &config.alias)?;

        let tcp = TcpListener::bind((Ipv4Addr::UNSPECIFIED, config.port)).await?;
        let port = tcp.local_addr()?.port();
        let info = DeviceInfo {
            alias: config.alias,
            version: "2.2".into(),
            device_model: Some(config.device_model),
            device_type: Some(config.device_type.as_str().into()),
            fingerprint: identity.fingerprint.clone(),
            port,
            protocol: "https".into(),
            download: false,
            announce: None,
        };
        let (shutdown, shutdown_rx) = watch::channel(false);
        let state = Arc::new(State {
            vfs,
            identity: identity.clone(),
            info: info.clone(),
            dest_dir: config.dest_dir,
            pin: config.pin,
            sessions: Mutex::new(HashMap::new()),
            peers: Mutex::new(HashMap::new()),
            announce: Arc::new(Notify::new()),
            last_activity_ms: AtomicU64::new(now_ms()),
            stopped: AtomicBool::new(false),
            shutdown: shutdown.clone(),
            idle_timeout: Duration::from_secs(config.idle_timeout_secs),
            errors: Mutex::new(VecDeque::with_capacity(20)),
        });

        let acceptor = TlsAcceptor::from(identity.server_config()?);
        let mut tasks = Vec::new();

        // TCP/TLS accept loop.
        {
            let state = state.clone();
            let mut stop = shutdown_rx.clone();
            tasks.push(tokio::spawn(async move {
                loop {
                    tokio::select! {
                        _ = stop.changed() => break,
                        accepted = tcp.accept() => {
                            let Ok((stream, peer)) = accepted else { continue };
                            let acceptor = acceptor.clone();
                            let state = state.clone();
                            tokio::spawn(async move {
                                match acceptor.accept(stream).await {
                                    Ok(tls) => {
                                        if let Err(err) = handle_connection(state, tls, peer).await {
                                            eprintln!("localsend: {err}");
                                        }
                                    }
                                    Err(err) => eprintln!("localsend: TLS handshake from {peer}: {err}"),
                                }
                            });
                        }
                    }
                }
            }));
        }

        // Session janitor: drop stale sessions and their `.part` files.
        {
            let state = state.clone();
            let mut stop = shutdown_rx.clone();
            tasks.push(tokio::spawn(async move {
                loop {
                    tokio::select! {
                        _ = stop.changed() => break,
                        _ = tokio::time::sleep(Duration::from_secs(60)) => state.expire_sessions().await,
                    }
                }
            }));
        }

        // Security: no transfer activity for `idle_timeout` → close the HTTPS
        // listener. Discovery chatter must not reset this timer.
        if config.idle_timeout_secs > 0 {
            let state = state.clone();
            let mut stop = shutdown_rx.clone();
            tasks.push(tokio::spawn(async move {
                loop {
                    tokio::select! {
                        _ = stop.changed() => break,
                        _ = tokio::time::sleep(Duration::from_secs(15)) => {
                            if state.stopped.load(Ordering::SeqCst) {
                                break;
                            }
                            let active = !state.sessions.lock().await.is_empty();
                            let idle = now_ms().saturating_sub(
                                state.last_activity_ms.load(Ordering::Relaxed),
                            );
                            if !active
                                && idle >= state.idle_timeout.as_millis() as u64
                            {
                                state.stopped.store(true, Ordering::SeqCst);
                                let _ = state.shutdown.send(true);
                                break;
                            }
                        }
                    }
                }
            }));
        }

        // Multicast discovery. Failure is non-fatal: `/register` and the
        // manual IP fallback still work.
        if config.enable_discovery {
            // The TCP port may be ephemeral in tests; LocalSend's UDP discovery
            // port is fixed (53317) so all peers share the multicast group.
            let udp_port = if config.port == 0 { DEFAULT_PORT } else { config.port };
            if let Ok(discovery) =
                Discovery::start(state.clone(), port, udp_port, shutdown_rx.clone()).await
            {
                tasks.extend(discovery);
            }
        }

        Ok(Self {
            state,
            port,
            shutdown,
            tasks: Mutex::new(tasks),
        })
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    pub fn info(&self) -> DeviceInfo {
        let mut info = self.state.info.clone();
        info.port = self.port;
        info
    }

    pub fn fingerprint(&self) -> String {
        self.state.identity.fingerprint.clone()
    }

    /// False after the idle watchdog or `stop()` closed the listener.
    pub fn is_running(&self) -> bool {
        !self.state.stopped.load(Ordering::SeqCst)
    }

    pub async fn errors(&self) -> Vec<String> {
        self.state.errors.lock().await.iter().cloned().collect()
    }

    pub async fn peers(&self) -> Vec<client::DiscoveredPeer> {
        let mut peers: Vec<_> = self.state.peers.lock().await.values().cloned().collect();
        peers.sort_by(|a, b| b.last_seen_ms.cmp(&a.last_seen_ms));
        peers
    }

    /// Send files to a discovered peer. `files` are VFS ids.
    pub async fn send(&self, peer: &client::DiscoveredPeer, files: Vec<String>) -> Result<()> {
        self.state.touch();
        client::send_files(
            &self.state.vfs,
            &self.state.info,
            &self.state.identity,
            peer,
            files,
            None,
        )
        .await
    }

    /// Manual fallback: POST `/register` to an IP and return the peer info.
    pub async fn register_at(
        &self,
        ip: IpAddr,
        port: u16,
        expected_fingerprint: Option<[u8; 32]>,
    ) -> Result<DeviceInfo> {
        let info =
            client::register_at(ip, port, &self.state.info, &self.state.identity, expected_fingerprint)
                .await?;
        self.state.record_peer(&info, ip).await;
        Ok(info)
    }

    /// Force an announcement without waiting for the periodic timer.
    pub async fn announce(&self) {
        self.state.announce.notify_one();
    }

    pub async fn stop(&self) {
        self.state.stopped.store(true, Ordering::SeqCst);
        let _ = self.shutdown.send(true);
        let mut tasks = self.tasks.lock().await;
        for task in tasks.drain(..) {
            task.abort();
        }
    }
}

impl Drop for LocalSendService {
    fn drop(&mut self) {
        self.state.stopped.store(true, Ordering::SeqCst);
        let _ = self.shutdown.send(true);
    }
}

struct Discovery;

impl Discovery {
    async fn start(
        state: Arc<State>,
        tcp_port: u16,
        udp_port: u16,
        stop: watch::Receiver<bool>,
    ) -> Result<Vec<JoinHandle<()>>> {
        // SO_REUSEADDR/PORT lets two local instances (and the integration test)
        // share the fixed discovery port while keeping distinct TCP ports.
        let raw = socket2::Socket::new(
            socket2::Domain::IPV4,
            socket2::Type::DGRAM,
            Some(socket2::Protocol::UDP),
        )?;
        raw.set_reuse_address(true)?;
        #[cfg(target_os = "linux")]
        raw.set_reuse_port(true)?;
        raw.bind(&SocketAddr::from((Ipv4Addr::UNSPECIFIED, udp_port)).into())?;
        raw.set_nonblocking(true)?;
        let socket = Arc::new(UdpSocket::from_std(raw.into())?);
        if let Err(err) = socket.join_multicast_v4(MULTICAST_GROUP, Ipv4Addr::UNSPECIFIED) {
            eprintln!("localsend: join multicast failed: {err}");
        }
        let _ = socket.set_multicast_loop_v4(true);

        let mut tasks = Vec::new();

        // Receive announcements and respond via HTTPS `/register`.
        {
            let state = state.clone();
            let socket = socket.clone();
            let mut stop = stop.clone();
            tasks.push(tokio::spawn(async move {
                let mut buf = vec![0u8; 64 * 1024];
                loop {
                    tokio::select! {
                        _ = stop.changed() => break,
                        recv = socket.recv_from(&mut buf) => {
                            let Ok((n, from)) = recv else { continue };
                            let Ok(peer) = serde_json::from_slice::<DeviceInfo>(&buf[..n]) else { continue };
                            if peer.fingerprint == state.info.fingerprint { continue; }
                            let peer_port = if peer.port == 0 { tcp_port } else { peer.port };
                            state.record_peer_with_port(&peer, from.ip(), peer_port).await;
                            if peer.announce == Some(true) {
                                let info = state.info.clone();
                                let identity = state.identity.clone();
                                let ip = from.ip();
                                tokio::spawn(async move {
                                    let _ = client::register_at(ip, peer_port, &info, &identity, None)
                                        .await;
                                });
                            }
                        }
                    }
                }
            }));
        }

        // Periodic announcement (and an immediate one on start / UI refresh).
        {
            let state = state.clone();
            let socket = socket.clone();
            let mut stop = stop.clone();
            let notify = state.announce.clone();
            tasks.push(tokio::spawn(async move {
                loop {
                    let mut info = state.info.clone();
                    info.announce = Some(true);
                    if let Ok(json) = serde_json::to_vec(&info) {
                        let _ = socket.send_to(&json, (MULTICAST_GROUP, udp_port)).await;
                    }
                    tokio::select! {
                        _ = stop.changed() => break,
                        _ = notify.notified() => {}
                        _ = tokio::time::sleep(Duration::from_secs(5)) => {}
                    }
                }
            }));
        }

        Ok(tasks)
    }
}

impl State {
    fn touch(&self) {
        self.last_activity_ms.store(now_ms(), Ordering::Relaxed);
    }

    async fn log_error(&self, msg: String) {
        eprintln!("localsend: {msg}");
        let mut errors = self.errors.lock().await;
        if errors.len() >= 20 {
            errors.pop_front();
        }
        errors.push_back(msg);
    }

    async fn record_peer(&self, info: &DeviceInfo, ip: IpAddr) {
        let port = if info.port == 0 { DEFAULT_PORT } else { info.port };
        self.record_peer_with_port(info, ip, port).await;
    }

    async fn record_peer_with_port(&self, info: &DeviceInfo, ip: IpAddr, port: u16) {
        if info.fingerprint == self.info.fingerprint {
            return;
        }
        let key = format!("{ip}:{port}");
        let peer = client::DiscoveredPeer {
            alias: info.alias.clone(),
            ip,
            port,
            fingerprint: info.fingerprint.clone(),
            device_type: info.device_type.clone().unwrap_or_else(|| "desktop".into()),
            last_seen_ms: now_ms(),
        };
        self.peers.lock().await.insert(key, peer);
    }

    async fn expire_sessions(&self) {
        let stale: Vec<(String, Vec<String>)> = {
            let sessions = self.sessions.lock().await;
            sessions
                .iter()
                .filter(|(_, s)| s.created.elapsed() > Duration::from_secs(600))
                .map(|(id, s)| {
                    (
                        id.clone(),
                        s.files
                            .values()
                            .filter_map(|f| f.temp_id.clone())
                            .collect::<Vec<_>>(),
                    )
                })
                .collect()
        };
        if stale.is_empty() {
            return;
        }
        for (id, temp_ids) in stale {
            for temp in temp_ids {
                let _ = self.vfs.remove(&temp, false).await;
            }
            self.sessions.lock().await.remove(&id);
        }
    }
}

async fn handle_connection(
    state: Arc<State>,
    tls: tokio_rustls::server::TlsStream<TcpStream>,
    peer: SocketAddr,
) -> Result<()> {
    let mut reader = BufReader::new(tls);
    let Some(head) = http::read_head(&mut reader).await? else {
        return Ok(());
    };
    let (path, _) = head
        .target
        .split_once('?')
        .unwrap_or((head.target.as_str(), ""));
    let body_len = head.content_length();

    if head.wants_continue() {
        reader
            .get_mut()
            .write_all(b"HTTP/1.1 100 Continue\r\n\r\n")
            .await?;
    }

    match (head.method.as_str(), path) {
        ("GET", "/api/localsend/v2/info") => {
            let body = serde_json::to_vec(&state.info)?;
            http::respond_bytes(reader.get_mut(), 200, "application/json", &body).await?;
        }
        ("POST", "/api/localsend/v2/register") => {
            let mut body = http::read_body(&mut reader, body_len, head.is_chunked(), 1024 * 1024).await?;
            if body.starts_with(&[0xEF, 0xBB, 0xBF]) {
                body.drain(..3);
            }
            if body.is_empty() {
                // Some clients probe `/register` without a body; answer anyway.
                let body = serde_json::to_vec(&state.info)?;
                http::respond_bytes(reader.get_mut(), 200, "application/json", &body).await?;
                return Ok(());
            }
            match serde_json::from_slice::<DeviceInfo>(&body) {
                Ok(peer_info) => {
                    state.record_peer(&peer_info, peer.ip()).await;
                    let body = serde_json::to_vec(&state.info)?;
                    http::respond_bytes(reader.get_mut(), 200, "application/json", &body).await?;
                }
                Err(err) => {
                    let detail = format!("register 400 from {peer}: {err}");
                    state.log_error(detail.clone()).await;
                    let msg = serde_json::json!({ "message": format!("invalid register body: {err}") });
                    http::respond_json(reader.get_mut(), 400, &msg).await?;
                }
            }
        }
        ("POST", "/api/localsend/v2/prepare-upload") => {
            state.touch();
            let pin = query_param(&head.target, "pin");
            if let Some(expected) = &state.pin {
                if pin.as_deref() != Some(expected.as_str()) {
                    http::respond_empty(reader.get_mut(), 401).await?;
                    return Ok(());
                }
            }
            let mut body = http::read_body(&mut reader, body_len, head.is_chunked(), 16 * 1024 * 1024).await?;
            if body.starts_with(&[0xEF, 0xBB, 0xBF]) {
                body.drain(..3);
            }
            let req = match serde_json::from_slice::<PrepareUpload>(&body) {
                Ok(req) => req,
                Err(err) => {
                    let detail = format!("prepare-upload 400 from {peer}: {err}");
                    state.log_error(detail.clone()).await;
                    let msg = serde_json::json!({ "message": format!("invalid prepare-upload body: {err}") });
                    http::respond_json(reader.get_mut(), 400, &msg).await?;
                    return Ok(());
                }
            };
            match state.create_session(peer.ip(), req).await {
                Ok(Some(response)) => {
                    http::respond_json(reader.get_mut(), 200, &response).await?;
                }
                Ok(None) => {
                    http::respond_empty(reader.get_mut(), 204).await?;
                }
                Err(_) => {
                    state.log_error(format!("prepare-upload 400 from {peer}: invalid file metadata")).await;
                    http::respond_empty(reader.get_mut(), 400).await?;
                }
            }
        }
        ("POST", "/api/localsend/v2/upload") => {
            state.touch();
            let session_id = query_param(&head.target, "sessionId");
            let file_id = query_param(&head.target, "fileId");
            let token = query_param(&head.target, "token");
            let (Some(session_id), Some(file_id), Some(token)) = (session_id, file_id, token)
            else {
                http::respond_empty(reader.get_mut(), 400).await?;
                return Ok(());
            };
            match state
                .receive_upload(
                    &mut reader,
                    peer.ip(),
                    &session_id,
                    &file_id,
                    &token,
                    body_len,
                    head.is_chunked(),
                )
                .await
            {
                Ok(()) => {
                    http::respond_empty(reader.get_mut(), 200).await?;
                }
                Err(UploadError::Forbidden) => {
                    state.log_error(format!("upload 403 from {peer}: session/file/token mismatch")).await;
                    http::respond_empty(reader.get_mut(), 403).await?;
                }
                Err(UploadError::Checksum) => {
                    state.log_error(format!("upload 422 from {peer}: sha256 mismatch")).await;
                    http::respond_empty(reader.get_mut(), 422).await?;
                }
                Err(UploadError::BadRequest) => {
                    state.log_error(format!("upload 400 from {peer}: malformed body")).await;
                    http::respond_empty(reader.get_mut(), 400).await?;
                }
                Err(UploadError::Internal) => {
                    state.log_error(format!("upload 500 from {peer}: vfs write failed")).await;
                    http::respond_empty(reader.get_mut(), 500).await?;
                }
            }
        }
        ("POST", "/api/localsend/v2/cancel") => {
            state.touch();
            if let Some(session_id) = query_param(&head.target, "sessionId") {
                state.cancel_session(&session_id).await;
            }
            http::respond_empty(reader.get_mut(), 200).await?;
        }
        _ => {
            http::respond_empty(reader.get_mut(), 404).await?;
        }
    }
    Ok(())
}

enum UploadError {
    Forbidden,
    BadRequest,
    Checksum,
    Internal,
}

impl State {
    async fn create_session(
        &self,
        peer_ip: IpAddr,
        req: PrepareUpload,
    ) -> std::result::Result<Option<PrepareUploadResponse>, ()> {
        let requested = match req.files {
            crate::protocol::Files::Map(map) => map,
            crate::protocol::Files::List(list) => list
                .into_iter()
                .enumerate()
                .map(|(index, file)| {
                    let key = if file.id.is_empty() {
                        index.to_string()
                    } else {
                        file.id.clone()
                    };
                    (key, file)
                })
                .collect(),
        };
        if requested.is_empty() {
            return Ok(None);
        }
        if requested.len() > 10_000 {
            return Err(());
        }
        let session_id = random_hex(16);
        let mut files = HashMap::new();
        let mut tokens = HashMap::new();
        for (file_id, file) in requested {
            // Some clients send relative paths ("DCIM/Camera/IMG.jpg") or
            // Windows separators. Flatten to the base name instead of rejecting
            // the whole session with a 400.
            let Some(safe_name) = sanitize_file_name(&file.file_name) else {
                return Err(());
            };
            if file.size > 100 * 1024 * 1024 * 1024 {
                return Err(());
            }
            let token = random_hex(16);
            tokens.insert(file_id.clone(), token.clone());
            files.insert(
                file_id,
                SessionFile {
                    token,
                    name: safe_name,
                    size: file.size,
                    sha256: normalize_sha256(file.sha256),
                    temp_name: None,
                    temp_id: None,
                    done: false,
                },
            );
        }
        self.sessions.lock().await.insert(
            session_id.clone(),
            Session {
                peer_ip,
                files,
                created: Instant::now(),
            },
        );
        Ok(Some(PrepareUploadResponse {
            session_id,
            files: tokens,
        }))
    }

    async fn receive_upload<R: AsyncBufRead + Unpin>(
        &self,
        reader: &mut R,
        peer_ip: IpAddr,
        session_id: &str,
        file_id: &str,
        token: &str,
        body_len: u64,
        chunked: bool,
    ) -> std::result::Result<(), UploadError> {
        let (name, size, expected_sha, temp_name) = {
            let sessions = self.sessions.lock().await;
            let session = sessions.get(session_id).ok_or(UploadError::Forbidden)?;
            if session.peer_ip != peer_ip {
                return Err(UploadError::Forbidden);
            }
            let file = session.files.get(file_id).ok_or(UploadError::Forbidden)?;
            if file.token != token || file.done {
                return Err(UploadError::Forbidden);
            }
            (
                file.name.clone(),
                file.size,
                file.sha256.clone(),
                file.temp_name.clone(),
            )
        };

        let temp_name = temp_name.unwrap_or_else(|| {
            format!(".localsend-{session_id}-{file_id}.part")
        });
        let temp = match self.vfs.stat(&vfs_core::Vfs::join(&self.dest_dir, &temp_name)).await {
            Ok(entry) => entry,
            Err(_) => match self.vfs.create_file(&self.dest_dir, &temp_name).await {
                Ok(entry) => entry,
                Err(_) => return Err(UploadError::Internal),
            },
        };
        {
            let mut sessions = self.sessions.lock().await;
            if let Some(session) = sessions.get_mut(session_id) {
                if let Some(file) = session.files.get_mut(file_id) {
                    file.temp_name = Some(temp_name);
                    file.temp_id = Some(temp.id.clone());
                }
            }
        }

        let mut hasher = Sha256::new();
        let mut written = 0u64;
        let mut buf = vec![0u8; 256 * 1024];
        if chunked {
            loop {
                let mut line = String::new();
                reader
                    .read_line(&mut line)
                    .await
                    .map_err(|_| UploadError::BadRequest)?;
                let size_str = line.trim().split(';').next().unwrap_or("").trim();
                let chunk_len = usize::from_str_radix(size_str, 16)
                    .map_err(|_| UploadError::BadRequest)?;
                if chunk_len == 0 {
                    // trailers
                    loop {
                        let mut trailer = String::new();
                        if reader.read_line(&mut trailer).await.map_err(|_| UploadError::BadRequest)? == 0
                            || trailer.trim().is_empty()
                        {
                            break;
                        }
                    }
                    break;
                }
                let mut remaining = chunk_len;
                while remaining > 0 {
                    let want = remaining.min(buf.len());
                    let n = reader
                        .read(&mut buf[..want])
                        .await
                        .map_err(|_| UploadError::BadRequest)?;
                    if n == 0 {
                        cleanup_after_partial(&self.vfs, &temp.id).await;
                        return Err(UploadError::BadRequest);
                    }
                    self.vfs
                        .write_range(&temp.id, written, &buf[..n])
                        .await
                        .map_err(|_| UploadError::Internal)?;
                    hasher.update(&buf[..n]);
                    written += n as u64;
                    remaining -= n;
                }
                let mut crlf = [0u8; 2];
                reader
                    .read_exact(&mut crlf)
                    .await
                    .map_err(|_| UploadError::BadRequest)?;
            }
        } else {
            // Trust Content-Length when present; fall back to the metadata size
            // for clients that omit it (read exactly `size` bytes).
            let target = if body_len > 0 { body_len } else { size };
            while written < target {
                let want = ((target - written) as usize).min(buf.len());
                let n = reader
                    .read(&mut buf[..want])
                    .await
                    .map_err(|_| UploadError::BadRequest)?;
                if n == 0 {
                    break;
                }
                self.vfs
                    .write_range(&temp.id, written, &buf[..n])
                    .await
                    .map_err(|_| UploadError::Internal)?;
                hasher.update(&buf[..n]);
                written += n as u64;
            }
        }
        if size > 0 && written != size {
            eprintln!(
                "localsend: upload size mismatch {session_id}/{file_id}: wrote {written}, metadata {size}, content-length {body_len}, chunked {chunked}"
            );
        }

        let cleanup = async {
            let _ = self.vfs.remove(&temp.id, false).await;
        };

        if written != size {
            cleanup.await;
            return Err(UploadError::BadRequest);
        }
        if let Some(expected) = expected_sha {
            let got = hex(&hasher.finalize());
            if !got.eq_ignore_ascii_case(&expected) {
                cleanup.await;
                return Err(UploadError::Checksum);
            }
        }

        let final_name = match self.unique_name(&name).await {
            Ok(name) => name,
            Err(_) => {
                cleanup.await;
                return Err(UploadError::Internal);
            }
        };
        if self.vfs.rename(&temp.id, &final_name).await.is_err() {
            cleanup.await;
            return Err(UploadError::Internal);
        }

        let mut sessions = self.sessions.lock().await;
        if let Some(session) = sessions.get_mut(session_id) {
            if let Some(file) = session.files.get_mut(file_id) {
                file.done = true;
                file.temp_id = None;
                file.temp_name = None;
            }
            if session.files.values().all(|f| f.done) {
                sessions.remove(session_id);
            }
        }
        Ok(())
    }

    async fn cancel_session(&self, session_id: &str) {
        let removed = self.sessions.lock().await.remove(session_id);
        if let Some(session) = removed {
            for file in session.files.values() {
                if let Some(id) = &file.temp_id {
                    let _ = self.vfs.remove(id, false).await;
                }
            }
        }
    }

    async fn unique_name(&self, wanted: &str) -> Result<String> {
        for i in 0..1000 {
            let candidate = suffix_name(wanted, i);
            let id = vfs_core::Vfs::join(&self.dest_dir, &candidate);
            match self.vfs.stat(&id).await {
                Err(vfs_core::VfsError::NotFound(_)) => return Ok(candidate),
                Ok(_) => continue,
                Err(err) => return Err(err.into()),
            }
        }
        Ok(format!("{}-{}", random_hex(4), wanted))
    }
}

async fn cleanup_after_partial(vfs: &Vfs, id: &str) {
    let _ = vfs.remove(id, false).await;
}

/// Flatten any relative path to a safe base name. Rejects traversal / control
/// characters; tolerates clients that preserve `folder/file.jpg` in `fileName`.
fn sanitize_file_name(name: &str) -> Option<String> {
    let normalized = name.replace('\\', "/");
    let base = normalized.rsplit('/').next().unwrap_or("").trim();
    if base.is_empty() || base == "." || base == ".." || base.chars().any(|c| c.is_control()) {
        return None;
    }
    Some(base.to_string())
}

fn suffix_name(name: &str, index: usize) -> String {
    if index == 0 {
        return name.to_string();
    }
    let (stem, ext) = match name.rsplit_once('.') {
        Some((stem, ext)) if !stem.is_empty() => (stem, format!(".{ext}")),
        _ => (name, String::new()),
    };
    format!("{stem} ({index}){ext}")
}

fn normalize_sha256(value: Option<String>) -> Option<String> {
    value
        .map(|v| v.trim().trim_start_matches("sha256:").to_ascii_lowercase())
        .filter(|v| v.len() == 64 && v.chars().all(|c| c.is_ascii_hexdigit()))
}

fn random_hex(bytes: usize) -> String {
    let mut raw = vec![0u8; bytes];
    rand::thread_rng().fill_bytes(&mut raw);
    hex(&raw)
}

fn hex(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push_str(&format!("{b:02x}"));
    }
    out
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitizes_relative_paths() {
        assert_eq!(sanitize_file_name("../etc/passwd").as_deref(), Some("passwd"));
        assert_eq!(sanitize_file_name("a/b.txt").as_deref(), Some("b.txt"));
        assert_eq!(sanitize_file_name("C:\\Users\\a.jpg").as_deref(), Some("a.jpg"));
        assert_eq!(sanitize_file_name("ok name.jpg").as_deref(), Some("ok name.jpg"));
        assert!(sanitize_file_name("..").is_none());
        assert!(sanitize_file_name("").is_none());
    }

    #[test]
    fn suffix_keeps_extension() {
        assert_eq!(suffix_name("a.jpg", 0), "a.jpg");
        assert_eq!(suffix_name("a.jpg", 2), "a (2).jpg");
        assert_eq!(suffix_name("README", 1), "README (1)");
    }
}
