//! SMB 2/3 backend, built on the pure-Rust [`smb`] crate (afiffon/smb-rs).
//!
//! Unlike WebDAV, the protocol has native random reads, random writes and
//! SET_END_OF_FILE, so the POSIX-shaped `Backend` contract maps 1:1 and
//! `can_random_write` is genuinely true (nice for resumable transfers).
//!
//! Cost model: mutations still open a fresh handle per call, but **sequential
//! reads cache one open handle per backend** (`read_cache` below) — the copy
//! engine and the playback server read chunk-by-chunk in order, and paying a
//! CREATE+CLOSE round trip per 256 KiB chunk was measured at ~5 MB/s on a
//! LAN share that does 50+ MB/s with handle reuse. Cache invalidates on any
//! mutation (write/truncate/remove/rename) and when the file id changes.

use std::sync::Arc;

use async_trait::async_trait;
use futures_util::StreamExt;

use smb::resource::SetLen;
use smb::{
    Client, ClientConfig, CreateDisposition, CreateOptions, FileAccessMask, FileAllInformation,
    FileAttributes, FileCreateArgs, FileDispositionInformation, FileIdBothDirectoryInformation,
    FileRenameInformation, ReadAt, Resource, ResourceHandle, Status, UncPath, WriteAt,
};

/// `Resource` (enum) derefs nowhere; borrow the common handle per variant.
fn handle_of(res: &Resource) -> &ResourceHandle {
    match res {
        Resource::File(f) => f.handle(),
        Resource::Directory(d) => d.handle(),
        Resource::Pipe(p) => p.handle(),
    }
}

use crate::backend::Backend;
use crate::capabilities::Capabilities;
use crate::entry::{guess_mime, mtime_ms, Entry, EntryKind};
use crate::error::{Result, VfsError};
use crate::uri::split_id;

pub const SCHEME: &str = "smb";

/// 单个 SMB 操作的硬上限预算：线上一轮永不完成时不能转成永久冻死
/// （见 [`SmbBackend::cap`] 的注释）。
const OP_CAP: std::time::Duration = std::time::Duration::from_secs(90);

/// Credentials. Kerberos (and with it sspi clients) are an M2+ concern; NTLMv2
/// username/password is the baseline that Synology/QNAP/Windows/Samba all do.
#[derive(Debug, Clone)]
pub struct SmbAuth {
    pub username: String,
    pub password: String,
}

impl SmbAuth {
    pub fn new(username: impl Into<String>, password: impl Into<String>) -> Self {
        Self {
            username: username.into(),
            password: password.into(),
        }
    }

    /// Anonymous share login; honored only when the server maps guests
    /// (e.g. Samba `map to guest = Bad User`).
    pub fn guest() -> Self {
        Self::new("guest", "")
    }
}

/// A single mounted share (`smb://<host>/<share>/...`).
pub struct SmbBackend {
    /// 可替换：smb-rs 的 Client 内部有 worker，连接断开后 worker 死亡，
    /// 复用它会一直报 "failed to send message to worker"，必须整体重建。
    client: tokio::sync::RwLock<Arc<Client>>,
    port: Option<u16>,
    host: String,
    share: String,
    auth: SmbAuth,
    /// 顺序读句柄缓存（同一时刻至多一个文件）。复制/播放都是顺序读同一文件，
    /// 跨 chunk 复用句柄省掉每块 2-3 个 SMB 往返。写入/删除/改名/截断即失效。
    ///
    /// 存 `Arc`：读路径只在「取/换句柄」时短暂持锁，实际读通过 Arc 副本在锁外
    /// 进行——多个并发 read_range（引擎双路预取、播放 seek）互不阻塞。
    read_cache: tokio::sync::Mutex<Option<Arc<CachedRead>>>,
    /// 顺序写句柄缓存：复制引擎按 1 MiB 调 `write_range`，如果每块都
    /// CREATE+WRITE+FLUSH+CLOSE，Samba 上会慢且抖动明显。这里跨 chunk
    /// 复用一个句柄，只在换文件/截断/删除/改名时 flush+close。
    ///
    /// `write_lock` 把同一后端的写操作串行化，因此单个缓存项是安全的；
    /// 读路径不受影响，仍可并发。
    write_cache: tokio::sync::Mutex<Option<Arc<CachedWrite>>>,
    write_lock: tokio::sync::Mutex<()>,
}

struct CachedRead {
    id: String,
    res: Resource,
}

struct CachedWrite {
    id: String,
    res: Resource,
}

impl SmbBackend {
    /// Connect eagerly so bad credentials/hosts fail at mount time, not on
    /// the first browse click. `port=None` uses the SMB default (445).
    pub async fn connect(
        host: &str,
        share: &str,
        port: Option<u16>,
        auth: SmbAuth,
    ) -> Result<Self> {
        let mut config = ClientConfig::default();
        // smb-rs 默认读超时 10s；慢 Wi-Fi/繁忙 NAS 大文件读常超 10s 无数据，
        // 会误报 "Operation timed out: ReceiveNextMessage, took >10s"。放宽到 60s。
        config.connection.timeout = Some(std::time::Duration::from_secs(60));
        if let Some(port) = port {
            config.connection.port = Some(port);
        }
        let backend = Self {
            client: tokio::sync::RwLock::new(Arc::new(Client::new(config))),
            port,
            host: host.trim_matches(['/', '\\']).to_string(),
            share: share.trim_matches(['/', '\\']).to_string(),
            auth,
            read_cache: tokio::sync::Mutex::new(None),
            write_cache: tokio::sync::Mutex::new(None),
            write_lock: tokio::sync::Mutex::new(()),
        };
        backend.share_connect().await?;
        Ok(backend)
    }

    async fn client(&self) -> Arc<Client> {
        self.client.read().await.clone()
    }

    /// 单个 SMB 操作的硬上限。
    ///
    /// smb-rs 的 credits 是发送时先扣、应答时才还的信号量；有几条应答不被
    /// 「记账」的路径（STATUS_PENDING 的 interim 应答只在最终应答处归还、
    /// receive 超时后迟到的应答无人认领、transform 失败的通知不走 recvo），
    /// 而 `acquire_many` 没有任何超时——长传输累积泄漏后信号量干涸，后续
    /// 请求会**无报错地永久挂起**。这层把「永远不返回」统一转成传输类错误，
    /// 交给 `retry` 重建连接（新连接 = 新的 credits 预算）继续传；重试耗尽
    /// 则显式失败，绝不无限冻死。
    async fn cap<T, F>(fut: F) -> Result<T>
    where
        F: std::future::Future<Output = Result<T>>,
    {
        Self::cap_with(OP_CAP, fut).await
    }

    /// [`cap`] 的可测版本：超时预算由调用方给定（单测用 50ms 量级）。
    async fn cap_with<T, F>(limit: std::time::Duration, fut: F) -> Result<T>
    where
        F: std::future::Future<Output = Result<T>>,
    {
        match tokio::time::timeout(limit, fut).await {
            Ok(res) => res,
            Err(_) => Err(VfsError::Network(format!(
                "smb operation stalled ({}s cap)",
                limit.as_secs()
            ))),
        }
    }

    async fn share_connect(&self) -> Result<()> {
        let target = self.root_unc()?;
        self.client()
            .await
            .share_connect(&target, &self.auth.username, self.auth.password.clone())
            .await
            .map_err(map_err)
    }

    /// 连接/worker 死亡后整体重建 Client 并重新 share_connect。
    async fn reset_client(&self) -> Result<()> {
        let mut config = ClientConfig::default();
        config.connection.timeout = Some(std::time::Duration::from_secs(60));
        if let Some(port) = self.port {
            config.connection.port = Some(port);
        }
        let client = Arc::new(Client::new(config));
        let target = self.root_unc()?;
        client
            .share_connect(&target, &self.auth.username, self.auth.password.clone())
            .await
            .map_err(map_err)?;
        *self.client.write().await = client;
        Ok(())
    }

    /// Canonical id of the share root.
    pub fn root_id(&self) -> String {
        format!("{SCHEME}://{}/{}", self.host, self.share)
    }

    /// 读句柄缓存失效：写/删/改名/截断之后，缓存句柄可能指向已被替换的文件，
    /// 必须先关掉；下次 read_range 会重新打开。
    async fn invalidate_read_cache(&self) {
        let mut cache = self.read_cache.lock().await;
        if let Some(old) = cache.take() {
            let _ = Self::cap(async { handle_of(&old.res).close().await.map_err(map_err) }).await;
        }
    }

    /// Only drop the read handle when the same file is being mutated; writing
    /// a different file (SMB → SMB copy) must not break sequential prefetch.
    async fn invalidate_read_cache_for(&self, id: &str) {
        let mut cache = self.read_cache.lock().await;
        let matches = cache
            .as_ref()
            .map(|cached| cached.id == id)
            .unwrap_or(false);
        if matches {
            if let Some(old) = cache.take() {
                let _ =
                    Self::cap(async { handle_of(&old.res).close().await.map_err(map_err) }).await;
            }
        }
    }

    /// Flush + close the cached write handle. Caller must hold `write_lock`.
    async fn close_write_cache_locked(&self) {
        let old = self.write_cache.lock().await.take();
        let Some(old) = old else { return };
        if let Some(file) = old.res.as_file() {
            let _ = Self::cap(async { file.flush().await.map_err(VfsError::io) }).await;
        }
        let _ = Self::cap(async { handle_of(&old.res).close().await.map_err(map_err) }).await;
    }

    /// Flush + close the cached write handle, waiting for any in-flight write.
    async fn close_write_cache(&self) {
        let _guard = self.write_lock.lock().await;
        self.close_write_cache_locked().await;
    }

    /// Drop the cached handle for `id` (e.g. after a transport error).
    /// Caller must hold `write_lock`.
    async fn drop_write_cache_locked(&self, id: &str) {
        let matches = self
            .write_cache
            .lock()
            .await
            .as_ref()
            .map(|cached| cached.id == id)
            .unwrap_or(false);
        if matches {
            self.close_write_cache_locked().await;
        }
    }

    /// Get (or open) the cached write handle for `id`. Caller must hold
    /// `write_lock`; the handle is reused across sequential chunks.
    async fn write_handle(&self, id: &str) -> Result<Arc<CachedWrite>> {
        let mut cache = self.write_cache.lock().await;
        if let Some(cached) = cache.as_ref() {
            if cached.id == id {
                return Ok(cached.clone());
            }
        }
        if let Some(old) = cache.take() {
            if let Some(file) = old.res.as_file() {
                let _ = file.flush().await;
            }
            handle_of(&old.res).close().await.ok();
        }

        // OpenIf + generic write: native POSIX-slice semantics, no
        // negotiation dance needed like on WebDAV.
        let unc = self.resolve_unc(id)?;
        let args = FileCreateArgs {
            disposition: CreateDisposition::OpenIf,
            attributes: FileAttributes::new(),
            options: CreateOptions::new().with_non_directory_file(true),
            desired_access: write_access(),
        };
        let res = self
            .client()
            .await
            .create_file(&unc, &args)
            .await
            .map_err(map_err)?;
        if res.as_file().is_none() {
            handle_of(&res).close().await.ok();
            return Err(VfsError::Io(format!("not a file: {id}")));
        }
        let cached = Arc::new(CachedWrite {
            id: id.to_string(),
            res,
        });
        *cache = Some(cached.clone());
        Ok(cached)
    }

    fn root_unc(&self) -> Result<UncPath> {
        format!(r"\\{}\{}", self.host, self.share)
            .parse()
            .map_err(|e| VfsError::Unsupported(format!("bad smb unc path: {e}")))
    }

    /// Entry id -> `\\host\share\rel\path` (empty rel = share root).
    fn resolve_unc(&self, id: &str) -> Result<UncPath> {
        let rel = self.resolve_rel(id)?;
        let root = self.root_unc()?;
        Ok(if rel.is_empty() {
            root
        } else {
            root.with_path(&rel)
        })
    }

    /// Entry id -> share-relative path joined with `\` ("" for the share root).
    fn resolve_rel(&self, id: &str) -> Result<String> {
        let (scheme, rest) = split_id(id);
        if scheme != SCHEME {
            return Err(VfsError::Unsupported(format!(
                "smb backend cannot handle {id}"
            )));
        }
        let mut segments = rest.split(['/', '\\']).filter(|s| !s.is_empty());
        let host = segments.next().unwrap_or_default();
        if !host.eq_ignore_ascii_case(&self.host) {
            return Err(VfsError::Unsupported(format!(
                "id belongs to another smb host: {id}"
            )));
        }
        let share = segments
            .next()
            .ok_or_else(|| VfsError::Unsupported(format!("smb id misses share: {id}")))?;
        if !share.eq_ignore_ascii_case(&self.share) {
            return Err(VfsError::Unsupported(format!(
                "id belongs to another smb share: {id}"
            )));
        }
        // Same lexical jail as local: `..` must not pop above the share root.
        let mut kept: Vec<&str> = Vec::new();
        for seg in segments {
            match seg {
                "." => {}
                ".." if kept.pop().is_none() => {
                    return Err(VfsError::PermissionDenied(format!(
                        "path escapes share root: {id}"
                    )))
                }
                ".." => {}
                other => kept.push(other),
            }
        }
        Ok(kept.join("\\"))
    }

    /// Open an existing object; the resulting [Resource] knows its own kind.
    async fn open(&self, id: &str, access: FileAccessMask) -> Result<Resource> {
        let unc = self.resolve_unc(id)?;
        self.client()
            .await
            .create_file(&unc, &FileCreateArgs::make_open_existing(access))
            .await
            .map_err(map_err)
    }

    /// Retry transport-class failures with bounded backoff (contract §4);
    /// protocol errors (status codes) are never retried.
    async fn retry<T, F, Fut>(&self, mut op: F) -> Result<T>
    where
        F: FnMut() -> Fut,
        Fut: std::future::Future<Output = Result<T>>,
    {
        const MAX_ATTEMPTS: u32 = 3;
        let mut delay = std::time::Duration::from_millis(200);
        let mut attempt = 0u32;
        loop {
            // 每次 attempt 都套 90s 硬上限：credits 干涸时 op 永不返回，
            // 不掐掉就冻死（见 cap 文档）。掐掉后按传输错误重建连接重试。
            match Self::cap(op()).await {
                Err(err) if is_transport(&err) && attempt + 1 < MAX_ATTEMPTS => {
                    // A stopped connection is re-established before the retry,
                    // mirroring how the WebDAV backend re-sends its request.
                    let _ = Self::cap(self.reset_client()).await;
                    tokio::time::sleep(delay).await;
                    delay *= 4;
                    attempt += 1;
                }
                other => return other,
            }
        }
    }

    fn entry_of_child(&self, parent_id: &str, info: &FileIdBothDirectoryInformation) -> Entry {
        let name = info.file_name.to_string();
        let kind = if info.file_attributes.directory() {
            EntryKind::Directory
        } else {
            EntryKind::File
        };
        let id = crate::uri::join(parent_id, &name);
        Entry {
            id,
            parent: Some(parent_id.to_string()),
            name: name.clone(),
            kind,
            size: if kind == EntryKind::Directory {
                0
            } else {
                info.end_of_file
            },
            modified_ms: mtime_ms(Some(info.last_write_time.into())),
            mime: (kind == EntryKind::File)
                .then(|| guess_mime(&name))
                .flatten(),
            hidden: info.file_attributes.hidden() || name.starts_with('.'),
            readonly: info.file_attributes.readonly(),
        }
    }
}

#[async_trait]
impl Backend for SmbBackend {
    fn scheme(&self) -> &'static str {
        SCHEME
    }

    fn display_name(&self) -> String {
        format!("smb ({}/{})", self.host, self.share)
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities {
            can_watch: false, // Directory::watch exists in the crate; VFS has no watch API yet.
            ..Capabilities::READ_WRITE
        }
    }

    async fn stat(&self, id: &str) -> Result<Entry> {
        self.retry(|| async {
            let res = self.open(id, read_access()).await?;
            let info: FileAllInformation = handle_of(&res).query_info().await.map_err(map_err)?;
            handle_of(&res).close().await.map_err(map_err)?;

            let name = if id == self.root_id() {
                self.share.clone()
            } else {
                id.rsplit(['/', '\\'])
                    .find(|s| !s.is_empty())
                    .unwrap_or_default()
                    .to_string()
            };
            let kind = if info.basic.file_attributes.directory() {
                EntryKind::Directory
            } else {
                EntryKind::File
            };
            Ok(Entry {
                id: id.to_string(),
                parent: crate::uri::parent_of(id).or(Some(self.root_id())),
                name: name.clone(),
                kind,
                size: if kind == EntryKind::Directory {
                    0
                } else {
                    info.standard.end_of_file
                },
                modified_ms: mtime_ms(Some(info.basic.last_write_time.into())),
                mime: (kind == EntryKind::File)
                    .then(|| guess_mime(&name))
                    .flatten(),
                hidden: info.basic.file_attributes.hidden() || name.starts_with('.'),
                readonly: info.basic.file_attributes.readonly(),
            })
        })
        .await
    }

    async fn list(&self, id: &str) -> Result<Vec<Entry>> {
        self.retry(|| async {
            let res = self.open(id, read_access()).await?;
            if !res.is_dir() {
                handle_of(&res).close().await.ok();
                return Err(VfsError::Io(format!("not a directory: {id}")));
            }
            let dir = Arc::new(res.unwrap_dir());
            let mut stream = smb::Directory::query::<FileIdBothDirectoryInformation>(&dir, "*")
                .await
                .map_err(map_err)?;
            let mut entries = Vec::new();
            while let Some(item) = stream.next().await {
                match item {
                    Ok(info) => {
                        let entry = self.entry_of_child(id, &info);
                        // Some servers echo "." / ".." in the enumeration.
                        if entry.name != "." && entry.name != ".." {
                            entries.push(entry);
                        }
                    }
                    Err(_) => continue, // single bad item must not fail the listing
                }
            }
            drop(stream);
            dir.handle().close().await.map_err(map_err)?;
            entries.sort_by(|a, b| {
                let a_dir = a.kind == EntryKind::Directory;
                let b_dir = b.kind == EntryKind::Directory;
                b_dir
                    .cmp(&a_dir)
                    .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
            });
            Ok(entries)
        })
        .await
    }

    async fn create_dir(&self, parent: &str, name: &str) -> Result<Entry> {
        validate_name(name)?;
        let child_id = crate::uri::join(parent, name);
        self.retry(|| async {
            let unc = self.resolve_unc(&child_id)?;
            let args = FileCreateArgs {
                disposition: CreateDisposition::Create,
                attributes: FileAttributes::new().with_directory(true),
                options: CreateOptions::new().with_directory_file(true),
                desired_access: FileAccessMask::new().with_generic_all(true),
            };
            let res = self
                .client()
                .await
                .create_file(&unc, &args)
                .await
                .map_err(map_err)?;
            handle_of(&res).close().await.map_err(map_err)?;
            self.stat(&child_id).await
        })
        .await
    }

    async fn create_file(&self, parent: &str, name: &str) -> Result<Entry> {
        validate_name(name)?;
        let child_id = crate::uri::join(parent, name);
        self.retry(|| async {
            let unc = self.resolve_unc(&child_id)?;
            let res = self
                .client()
                .await
                .create_file(
                    &unc,
                    &FileCreateArgs::make_create_new(
                        FileAttributes::new(),
                        CreateOptions::new().with_non_directory_file(true),
                    ),
                )
                .await
                .map_err(map_err)?;
            handle_of(&res).close().await.map_err(map_err)?;
            self.stat(&child_id).await
        })
        .await
    }

    async fn remove(&self, id: &str, recursive: bool) -> Result<()> {
        self.invalidate_read_cache().await;
        self.close_write_cache().await;
        // Not retried end-to-end: after a stuck-but-successful delete the
        // retry would land on NotFound and report a false failure.
        let entry = self.stat(id).await?;
        if entry.is_dir() && recursive {
            for child in self.list(id).await? {
                Box::pin(self.remove(&child.id, true)).await?;
            }
        }
        // delete_leaf 不走 retry（防删一半重试造成假报错），单独套硬上限。
        Self::cap(self.delete_leaf(&entry)).await
    }

    async fn rename(&self, id: &str, new_name: &str) -> Result<Entry> {
        self.invalidate_read_cache().await;
        self.close_write_cache().await;
        validate_name(new_name)?;
        // MS-FSCC 2.4.34.2: with root_directory = 0 the FileName is the full
        // share-relative path, NOT a basename. Same-parent only (contract §2:
        // cross-directory moves are the engine's job).
        let src_rel = self.resolve_rel(id)?;
        let new_rel = match src_rel.rfind('\\') {
            Some(idx) => format!("{}\\{new_name}", &src_rel[..idx]),
            None => new_name.to_string(),
        };
        // rename 语义要求整段原子完成，中途失败不能重跑，只套硬上限防挂死。
        Self::cap(async {
            let res = self.open(id, write_access()).await?;
            handle_of(&res)
                .set_info(FileRenameInformation {
                    replace_if_exists: true.into(),
                    root_directory: 0,
                    file_name: new_rel.as_str().into(),
                })
                .await
                .map_err(map_err)?;
            handle_of(&res).close().await.map_err(map_err)
        })
        .await?;
        let parent = crate::uri::parent_of(id).unwrap_or_else(|| self.root_id());
        self.stat(&crate::uri::join(&parent, new_name)).await
    }

    async fn read_range(&self, id: &str, offset: u64, len: usize) -> Result<Vec<u8>> {
        if len == 0 {
            return Ok(Vec::new());
        }
        self.retry(|| async {
            // 句柄获取/轮换：仅在锁内做短操作；实际读在锁外（见下），
            // 因此多个并发 read_range 可以同时飞在网络上（SMB2 同句柄并发读合法）。
            let handle: Arc<CachedRead> = {
                let mut cache = self.read_cache.lock().await;
                match cache.as_ref() {
                    Some(cached) if cached.id == id => cached.clone(),
                    _ => {
                        if let Some(old) = cache.take() {
                            handle_of(&old.res).close().await.ok();
                        }
                        let res = self.open(id, read_access()).await?;
                        if res.as_file().is_none() {
                            handle_of(&res).close().await.ok();
                            return Err(VfsError::Io(format!("not a file: {id}")));
                        }
                        let arc = Arc::new(CachedRead {
                            id: id.to_string(),
                            res,
                        });
                        *cache = Some(arc.clone());
                        arc
                    }
                }
            };

            let mut buf = vec![0u8; len];
            let mut filled = 0usize;
            let mut fault: Option<VfsError> = None;
            match handle.res.as_file() {
                Some(file) => {
                    while filled < len {
                        match file
                            .read_at(&mut buf[filled..], offset + filled as u64)
                            .await
                        {
                            Ok(0) => break, // EOF：短读合法（契约 §2）
                            Ok(n) => filled += n,
                            Err(err) => {
                                fault = Some(map_err(err));
                                break;
                            }
                        }
                    }
                }
                None => fault = Some(VfsError::Io(format!("not a file: {id}"))),
            }
            if let Some(err) = fault {
                // 句柄可能已半坏：仅当缓存里仍是这个句柄时换掉（避免误关并发读的新句柄）
                let mut cache = self.read_cache.lock().await;
                if cache
                    .as_ref()
                    .map(|c| Arc::ptr_eq(c, &handle))
                    .unwrap_or(false)
                {
                    if let Some(old) = cache.take() {
                        handle_of(&old.res).close().await.ok();
                    }
                }
                return Err(err);
            }
            buf.truncate(filled);
            Ok(buf)
        })
        .await
    }

    async fn write_range(&self, id: &str, offset: u64, data: &[u8]) -> Result<()> {
        self.invalidate_read_cache_for(id).await;
        let _guard = self.write_lock.lock().await;
        let result = self
            .retry(|| async {
                let cached = self.write_handle(id).await?;
                let Some(file) = cached.res.as_file() else {
                    self.drop_write_cache_locked(id).await;
                    return Err(VfsError::Io(format!("not a file: {id}")));
                };
                let mut written = 0usize;
                while written < data.len() {
                    match file
                        .write_at(&data[written..], offset + written as u64)
                        .await
                    {
                        Ok(0) => {
                            self.drop_write_cache_locked(id).await;
                            return Err(VfsError::Io(format!(
                                "zero-length write at {id}+{offset}"
                            )));
                        }
                        Ok(n) => written += n,
                        Err(err) => {
                            self.drop_write_cache_locked(id).await;
                            return Err(map_err(err));
                        }
                    }
                }
                Ok(())
            })
            .await;
        if result.is_err() {
            self.close_write_cache_locked().await;
        }
        result
    }

    async fn truncate(&self, id: &str, size: u64) -> Result<()> {
        self.invalidate_read_cache_for(id).await;
        // Flush + close the write handle at the file boundary; this is the
        // only per-file flush now (previously it happened every 1 MiB chunk).
        self.close_write_cache().await;
        self.retry(|| async {
            let res = self.open(id, write_access()).await?;
            let Some(file) = res.as_file() else {
                handle_of(&res).close().await.ok();
                return Err(VfsError::Io(format!("not a file: {id}")));
            };
            file.set_len(size).await.map_err(map_err)?;
            file.handle().close().await.map_err(map_err)?;
            Ok(())
        })
        .await
    }
}

impl SmbBackend {
    /// Mark-and-close deletion for a single (possibly checked-empty) file or
    /// directory. Server rejects non-empty dirs with STATUS_DIRECTORY_NOT_EMPTY.
    async fn delete_leaf(&self, entry: &Entry) -> Result<()> {
        let res = self.open(&entry.id, write_access()).await?;
        if let Resource::Directory(dir) = res {
            // Contract §2: recursive=false must never silently recurse.
            let dir = Arc::new(dir);
            let mut stream = smb::Directory::query::<FileIdBothDirectoryInformation>(&dir, "*")
                .await
                .map_err(map_err)?;
            // Samba echoes "." and ".." back for SMB2 queries; they don't
            // count as content.
            let mut not_empty = false;
            while let Some(item) = stream.next().await {
                if let Ok(info) = item {
                    let name = info.file_name.to_string();
                    if name != "." && name != ".." {
                        not_empty = true;
                        break;
                    }
                }
            }
            drop(stream);
            if not_empty {
                dir.close().await.ok();
                return Err(VfsError::Io(format!(
                    "directory not empty (pass recursive=true): {}",
                    entry.id
                )));
            }
            dir.set_info(FileDispositionInformation {
                delete_pending: true.into(),
            })
            .await
            .map_err(map_err)?;
            dir.close().await.map_err(map_err)?;
            Ok(())
        } else {
            handle_of(&res)
                .set_info(FileDispositionInformation {
                    delete_pending: true.into(),
                })
                .await
                .map_err(map_err)?;
            handle_of(&res).close().await.map_err(map_err)?;
            Ok(())
        }
    }
}

fn read_access() -> FileAccessMask {
    FileAccessMask::new().with_generic_read(true)
}

fn write_access() -> FileAccessMask {
    FileAccessMask::new()
        .with_generic_read(true)
        .with_generic_write(true)
        .with_delete(true)
}

/// Transport-class failures are worth a retry; anything with a real NT
/// status is deterministic and mapped immediately.
fn is_transport(err: &VfsError) -> bool {
    // Io 在此后端基本都是传输层/worker 死亡；协议状态码走单独分支不会被重试。
    matches!(err, VfsError::Network(_) | VfsError::Io(_))
}

fn map_err(err: smb::Error) -> VfsError {
    use smb::Error as E;
    match err {
        E::ReceivedErrorMessage(status, _) | E::UnexpectedMessageStatus(status) => {
            map_status(status)
        }
        E::ConnectionStopped => VfsError::Network("smb connection stopped".into()),
        E::IoError(e) if e.kind() == std::io::ErrorKind::Other => {
            // resource layer wraps statuses into io::Error on read/write
            VfsError::Network(e.to_string())
        }
        E::IoError(e) => VfsError::io(e),
        E::SspiError(e) => VfsError::PermissionDenied(format!("smb auth: {e}")),
        E::NegotiationError(e) => VfsError::Network(format!("smb negotiation: {e}")),
        other => VfsError::Io(other.to_string()),
    }
}

fn map_status(status: u32) -> VfsError {
    match status {
        Status::U32_OBJECT_NAME_NOT_FOUND | Status::U32_OBJECT_PATH_NOT_FOUND => {
            VfsError::NotFound(Status::try_display_as_status(status))
        }
        Status::U32_OBJECT_NAME_COLLISION => VfsError::AlreadyExists("target exists".into()),
        Status::U32_ACCESS_DENIED | Status::U32_SHARING_VIOLATION | Status::U32_LOGON_FAILURE => {
            VfsError::PermissionDenied(Status::try_display_as_status(status))
        }
        Status::U32_DIRECTORY_NOT_EMPTY => {
            VfsError::Io("directory not empty (pass recursive=true)".into())
        }
        other => VfsError::Io(format!(
            "smb status {}",
            Status::try_display_as_status(other)
        )),
    }
}

/// Windows-illegal names are rejected client-side so the UI gets `InvalidName`
/// instead of a wire error.
fn validate_name(name: &str) -> Result<()> {
    let invalid = name.is_empty()
        || name == "."
        || name == ".."
        || name.contains(['/', '\\', '<', '>', ':', '"', '|', '?', '*', '\0'])
        || name.ends_with(['.', ' ']);
    if invalid {
        return Err(VfsError::InvalidName(name.to_string()));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn backend() -> SmbBackend {
        // Construction without connecting: only used for id↔UNC unit tests.
        SmbBackend {
            client: tokio::sync::RwLock::new(Arc::new(Client::new(ClientConfig::default()))),
            port: None,
            host: "NAS.local".into(),
            share: "Media".into(),
            auth: SmbAuth::guest(),
            read_cache: tokio::sync::Mutex::new(None),
            write_cache: tokio::sync::Mutex::new(None),
            write_lock: tokio::sync::Mutex::new(()),
        }
    }

    #[test]
    fn ids_map_to_unc_paths() {
        let b = backend();
        let root = b.resolve_unc("smb://NAS.local/Media").unwrap();
        assert_eq!(root.to_string(), r"\\NAS.local\Media");
        let nested = b
            .resolve_unc("smb://nas.LOCAL/Media/我的 片/film (1).mkv")
            .unwrap();
        assert_eq!(
            nested.to_string(),
            r"\\NAS.local\Media\我的 片\film (1).mkv"
        );
        let normalized = b
            .resolve_unc("smb://NAS.local/media/a/./b/../c.txt")
            .unwrap();
        assert_eq!(normalized.to_string(), r"\\NAS.local\Media\a\c.txt");
    }

    #[test]
    fn rejects_escapes_and_foreign_mounts() {
        let b = backend();
        let err = b
            .resolve_unc("smb://NAS.local/Media/../../etc")
            .unwrap_err();
        assert!(matches!(err, VfsError::PermissionDenied(_)));
        assert!(b.resolve_unc("smb://other/Media/a").is_err());
        assert!(b.resolve_unc("smb://NAS.local/other/a").is_err());
        assert!(b.resolve_unc("webdav://NAS.local/Media/a").is_err());
    }

    #[test]
    fn windows_illegal_names() {
        assert!(validate_name("normal file.txt").is_ok());
        assert!(validate_name("a<b>.txt").is_err());
        assert!(validate_name("trailing.").is_err());
        assert!(validate_name("trailing ").is_err());
        assert!(matches!(
            validate_name("a/b").unwrap_err(),
            VfsError::InvalidName(_)
        ));
    }

    /// cap 的核心保证：永不完成的操作必须变成「传输类错误」，而不是挂死。
    /// is_transport 匹配 Network(_)，所以它会走 retry 的重建连接重试路径。
    #[tokio::test]
    async fn cap_converts_stalled_ops_into_transport_errors() {
        let never = futures_util::future::pending::<Result<()>>();
        let err = SmbBackend::cap_with(std::time::Duration::from_millis(50), never)
            .await
            .unwrap_err();
        assert!(matches!(err, VfsError::Network(_)), "unexpected: {err:?}");
        assert!(is_transport(&err));

        // 正常完成的操作不受影响，返回值原样透传。
        let ok = SmbBackend::cap_with(std::time::Duration::from_secs(5), async { Ok(42u8) }).await;
        assert_eq!(ok.unwrap(), 42);
    }
}

/// 枚举某个 SMB 服务器上可访问的共享（连接 IPC$ 后走 srvsvc）。
pub async fn list_shares(host: &str, port: Option<u16>, auth: SmbAuth) -> Result<Vec<String>> {
    let mut config = ClientConfig::default();
    config.connection.timeout = Some(std::time::Duration::from_secs(60));
    if let Some(port) = port {
        config.connection.port = Some(port);
    }
    let client = Client::new(config);
    let host = host.trim_matches(['/', '\\']).to_string();
    let ipc = smb::UncPath::ipc_share(&host).map_err(map_err)?;
    client
        .share_connect(&ipc, &auth.username, auth.password.clone())
        .await
        .map_err(map_err)?;
    let shares = client.list_shares(&host).await.map_err(map_err)?;
    Ok(shares
        .into_iter()
        .filter_map(|s| s.netname.as_ref().map(|n| n.to_string()))
        .filter(|n| !n.eq_ignore_ascii_case("IPC$"))
        .collect())
}
