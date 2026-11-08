# VFS API 契约

实现一个新后端（SMB/SFTP/WebDAV/云盘）前请先读完本文。任何违反契约的行为都会在传输引擎或 UI 上表现为难以定位的 bug。

## 1. Entry Id 规范

- 本地：绝对路径，如 `/home/me/a.txt`、`C:\Users\me\a.txt`。
- 远端：`<scheme>://<path>`，如 `smb://nas/share/movie.mkv`、`sftp://host/srv/data`。
- `file://` 与 `local://` 都归一化为本地。
- 未知前缀回退为本地（对用户手输路径更宽容）。
- UI 只持有 id，不解析它；需要展示路径时用 `Vfs::display_path`。

## 2. Backend trait

```rust
#[async_trait]
pub trait Backend: Send + Sync + 'static {
    fn scheme(&self) -> &'static str;
    fn capabilities(&self) -> Capabilities;

    async fn stat(&self, id: &str) -> Result<Entry>;
    async fn list(&self, id: &str) -> Result<Vec<Entry>>;
    async fn create_dir(&self, parent: &str, name: &str) -> Result<Entry>;
    async fn create_file(&self, parent: &str, name: &str) -> Result<Entry>;
    async fn remove(&self, id: &str, recursive: bool) -> Result<()>;
    async fn rename(&self, id: &str, new_name: &str) -> Result<Entry>;

    async fn read_range(&self, id: &str, offset: u64, len: usize) -> Result<Vec<u8>>;
    async fn write_range(&self, id: &str, offset: u64, data: &[u8]) -> Result<()>;
    async fn truncate(&self, id: &str, size: u64) -> Result<()>;

    // 默认实现：基于上面三个 I/O 方法流式处理平台 fd
    async fn read_to_fd(&self, id: &str, fd: i32, offset: u64, cancel: &CancelToken) -> Result<u64>;
    async fn write_from_fd(&self, id: &str, fd: i32, offset: u64, cancel: &CancelToken) -> Result<u64>;
}
```

### 语义要求

| 方法 | 要求 |
|---|---|
| `stat` | 不跟随符号链接（用 `symlink_metadata` 语义），必须返回真实 `size`/`mtime` |
| `list` | 不递归；`Entry.parent` 必须正确；单条目失败不应导致整目录失败（跳过并继续） |
| `read_range` | 允许短读（文件尾部）；`offset` 越界返回空 |
| `write_range` | 可创建文件；**必须**支持随机写，否则 `can_random_write=false` 且引擎需要走临时文件策略 |
| `truncate` | 用于覆盖大文件为小文件时收缩；不支持则 `can_write=false` 或在引擎层禁止覆盖 |
| `rename` | 仅改基名；跨目录移动由引擎实现（复制 + 删除） |
| `remove` | 目录且 `recursive=false` 时必须返回错误而不是静默递归 |

### 并发

- 同一 id 的并发读写不做串行保证；引擎在单任务内顺序调用。
- 后端必须 `Send + Sync`，可被多个 transfer 同时使用。
- 不假设调用顺序（不要缓存「当前目录」之类的会话状态）。

## 3. 能力矩阵

```rust
Capabilities {
    can_list, can_read, can_write, can_create, can_rename, can_delete,
    can_seek,            // 任意 offset 读：Range 播放必需
    can_random_write,    // 任意 offset 写：断点续传必需
    can_watch,           // 变更通知
    native_thumbnails,   // 后端侧缩略图（如 Google Drive）
}
```

预设：`READ_WRITE`、`READ_ONLY`、`DOWNLOAD_ONLY`。
UI 必须按能力渲染，禁止写「if backend == smb」这类分支。

## 4. 错误映射

后端只能返回 `VfsError` 的语义变体：

- 底层 `io::Error` → `VfsError::io(err)`（自动区分 NotFound/PermissionDenied/AlreadyExists）。
- 协议错误按语义归类；不要把可恢复错误包装成 `Io`。
- 网络类后端在内部做有限重试（指数退避），重试耗尽再返回 `Network`。
- 用户取消返回 `Cancelled`，不要返回 `Io("cancelled")`。

## 5. 传输引擎契约

- 先 `scan` 得到 `(files, bytes)` 总量，再逐个拷贝；UI 因此能显示确定进度条。
- 每 chunk 检查 `CancelToken`，最坏延迟一个 chunk（256 KiB）。
- 冲突在**目标已存在**时处理：`Overwrite` / `Skip` / `Rename`（`name (1).ext`）。
- 符号链接按文件处理、不递归，防止环。
- 目录深度上限 64。

## 6. 新增后端检查清单

- [ ] 实现 `Backend`，`scheme()` 返回唯一 scheme。
- [ ] 在 `Vfs::mount` 注册；FFI 层暴露连接/断开方法（M2）。
- [ ] 用真实设备做兼容性矩阵：Windows 共享、群晖、威联通、Samba 4、中文文件名。
- [ ] 单元测试：`stat/list/read_range/write_range/rename/remove` 全链路 + 断线重试。
- [ ] 明确能力矩阵（只读？支持 rename？支持随机写？）。
- [ ] 错误路径测试：认证失败、路径不存在、权限不足、超时。

## 7. FFI 出口

| 方法 | 说明 |
|---|---|
| `open(localRoot, indexPath)` | 打开本地根 + 可选索引 |
| `rootId()` / `displayPath(id)` | 根 id / 展示路径 |
| `capabilities(id)` | 能力矩阵 |
| `stat/list/createDir/createFile/remove/rename` | 浏览与元数据操作 |
| `readBytes/writeBytes` | 小数据（预览） |
| `exportToFd/importFromFd` | 大数据流式（平台 fd） |
| `mountWebdav(label, baseUrl, user, pass)` | 挂载 WebDAV；返回 root id |
| `mountSmb(label, host, share, user, pass)` | 挂载 SMB 共享；返回 root id |
| `mounts()` / `unmount(rootId)` | 连接管理（同协议多实例按 root 前缀分流） |
| `streamUrl(id)` | 回环 HTTP+Range 播放 URL（懒启动） |
| `startCopy/transferSnapshot/transfers/cancelTransfer/forgetTransfer` | 传输任务 |
| `pendingTransfers()/resumeTransfer(id)` | 断点续传：重启后恢复未完成的复制（`forgetTransfer` 放弃） |
| `indexDir/search/indexCount/clearIndex` | 索引 |

版本策略：新增方法向后兼容；**不要修改已有方法签名**（UniFFI 有 checksum 校验，签名变化必须两端同时更新并重新生成绑定）。
