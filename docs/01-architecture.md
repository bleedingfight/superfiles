# 架构

## 1. 分层

```
┌─────────────────────────────────────────────────────────────┐
│ UI 层（每个平台一份，全原生）                                 │
│   iOS/iPadOS  SwiftUI + Swift Concurrency                   │
│   Android/TV  Jetpack Compose + Coroutines/Flow             │
│   (后续) macOS SwiftUI 复用 / Windows WinUI3 / Linux GTK4     │
├─────────────────────────────────────────────────────────────┤
│ 平台适配层（薄）                                              │
│   iOS     File Provider 扩展、UIDocumentPicker、BGTask、      │
│           AVPlayer、本地 HTTP 回环服务、Keychain             │
│   Android SAF/MediaStore、DocumentsProvider、FGS、Media3     │
├─────────────────────────────────────────────────────────────┤
│ Rust 内核（一份代码，编到所有平台）                            │
│   vfs-core  id 规范 / Backend trait / 能力矩阵 / local 后端   │
│   engine    传输队列、预扫描、进度、取消、冲突策略             │
│   index     SQLite 元数据、搜索                              │
│   ffi       UniFFI wire types + 同步门面                     │
└─────────────────────────────────────────────────────────────┘
```

原则：**跨平台一致的逻辑必须在内核里，跨平台不一致的必须在 UI/适配层。**
文件操作、协议、分块、续传、错误分类属于前者；导航栏、文件选择器、权限弹窗属于后者。

## 2. 线程模型

- 内核持有一个全局 tokio runtime（`sfiles-ffi` 中 `runtime()`，2 个 worker）。
- 所有 FFI 方法都是**同步**的：内部 `runtime().block_on(...)`。
- UI 必须从后台线程/调度器调用：Swift 用 `Task.detached`，Kotlin 用 `Dispatchers.IO`。
- `start_copy` 立即返回 transfer id，真正的拷贝在 runtime 上执行；UI 轮询 `transfer_snapshot`。

为什么不用 UniFFI 的 `async` 导出：Android/JNI 线程上没有 tokio context，需要每端额外注入 runtime；同步 API 的行为在所有平台上可预测，也让「取消/轮询」这种模型天然成立。详见 `adr/0002`。

## 3. 数据流（一次目录浏览）

```
Swift/Kotlin        FFI                engine/index             Backend
    │  list(id)       │                     │                     │
    ├────────────────>│ block_on(vfs.list)  │                     │
    │                 ├────────────────────>│ backend_for(id)      │
    │                 │                     ├────────────────────>│ read_dir / SMB list
    │                 │<────────────────────┤                     │
    │<────────────────┤ Vec<Entry> (wire)   │                     │
    │  @MainActor     │                     │                     │
```

目录列表总是实时来自后端；索引只用于「离线浏览 + 全局搜索 + 秒开缓存」（M1 起把 list 结果 upsert 进索引）。

## 4. 字节永远不穿过 FFI

- 平台把**文件描述符**交给内核：iOS `FileHandle.fileDescriptor`，Android `ParcelFileDescriptor.detachFd()`。
- 内核用 `BorrowedFd`/`ManuallyDrop<File>` 读写，**不接管所有权**（不会 double close）。
- 大文件传输完全发生在 Rust 内部：`read_range` → `write_range`，只在 Rust 内存中停留一个 chunk（默认 256 KiB）。
- `read_bytes` 只用于预览（几万个字节级别）。

## 5. 错误模型

内核 `VfsError`（8 个语义变体）→ FFI `SfError`（同构，带 message）。
UI 按变体决定交互，不解析 message：

| 变体 | UI 行为 |
|---|---|
| `NotFound` | 刷新列表 / 提示文件已删除 |
| `PermissionDenied` | 引导授权（SAF/全盘权限） |
| `AlreadyExists` | 冲突对话框（覆盖/跳过/重命名） |
| `Unsupported` | 置灰按钮（看 `Capabilities`） |
| `Network` | 重试 + 显示离线缓存 |
| `InvalidName` | 输入框内联报错 |
| `Cancelled` | 静默（用户主动取消） |
| `Io` | 上报日志 + 通用错误 |

## 6. 能力矩阵

每个后端返回 `Capabilities`，UI 只依据能力开关按钮。新增一个「只读 WebDAV」后端时，UI 不需要任何改动。

## 7. 索引与离线

- SQLite（WAL）存 `entries`（id / parent / name / kind / size / mtime / mime / hidden / readonly）。
- 搜索 M0 用 `LIKE`（大小写不敏感、转义通配符），M1 换 FTS5（中文分词/拼音）。
- 传输任务状态 M0 在内存；M1 落库以获得「杀进程后恢复」。

## 8. 目录布局约定

| 平台 | `local_root` |
|---|---|
| iOS | `<容器>/Documents` |
| Android | `context.filesDir/storage`（M0），M1 起增加 SAF tree / 全盘 |
| 桌面 | 用户选择的工作目录（本地后端有 jail） |

本地后端对 `..` 做词法归一化并校验仍在 root 内；`create_dir/create_file/rename` 拒绝含分隔符的名字。

## 9. 后续扩展点

- 新后端：实现 `vfs_core::Backend`（见 `03-vfs-api.md`），`Vfs::mount` 注册。
- 新平台：只要能把 Rust 编过去，再写 UI 壳；绑定用 UniFFI（鸿蒙可用 `uniffi-bindgen-arkts`）。
- 桌面 CLI 已存在（`crates/sfiles-cli`），可用于自动化测试和未来终端端。
