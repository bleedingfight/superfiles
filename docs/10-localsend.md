# 10 · 近邻传输（LocalSend 兼容）

> 目标：Android / iOS / 鸿蒙之间不经过云盘、不装同一款 App 也能传文件。
> 实现遵循 [LocalSend Protocol v2](https://github.com/localsend/protocol)，
> 默认 HTTPS + 自签证书 + 指纹固定，局域网内直连。

## 1. 分层

```
UI（Android / iOS / HarmonyOS）
   │  UniFFI
   ▼
crates/sfiles-ffi        startLocalSend / LocalSendHandle
   │
   ▼
crates/localsend         协议核心（纯 Rust，三端共用）
   ├── cert.rs           自签证书 + SHA-256 指纹
   ├── protocol.rs       v2 JSON 契约
   ├── http.rs           最小 HTTP/1.1（跑在 TLS 上）
   ├── server.rs         HTTPS 接收端 + 会话 + 组播发现
   └── client.rs         发现应答 / prepare-upload / 分块上传
```

Rust 侧不依赖平台 UI，iOS/鸿蒙只需把同一套 FFI 方法接到各自的界面。

## 2. 已实现端点

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/localsend/v2/info` | 调试用设备信息 |
| POST | `/api/localsend/v2/register` | 发现应答 / 手动连接 |
| POST | `/api/localsend/v2/prepare-upload` | 接收文件元数据，返回 sessionId + 每文件 token |
| POST | `/api/localsend/v2/upload` | 流式写入 VFS，支持 sha256 校验 |
| POST | `/api/localsend/v2/cancel` | 取消会话并清理 `.part` 临时文件 |

未实现：`prepare-download` / `download`（反向下载，`download: false`）。

## 3. 发现

- 组播：`224.0.0.167:53317`（UDP）；
- 启动即广播，之后每 5 秒一次；
- 收到 `announce: true` 的广播后，通过 HTTPS `POST /register` 回应；
- 组播被 AP 隔离时，UI 支持手动填 IP + 端口；
- 发现只交换设备名/端口/证书指纹，不交换文件内容。

## 4. HTTPS 与指纹

- 每台设备第一次启动生成 **ECDSA P-256 自签证书**，私钥 0600 保存；
- **双向 TLS（mTLS）**：LocalSend v2.2 要求客户端也出示自己的证书；我们的
  HTTPS client 用本机证书做 client auth，服务端请求并接受任意有效自签证书；
- 指纹 = 证书 DER 的 SHA-256（hex）；服务端记录客户端证书指纹作为真实身份，
  JSON 里的 `fingerprint` 只作兜底；
- 发现/手动连接时携带指纹；
- 发送端连接时做 **certificate pinning**：只接受指纹匹配的服务端证书（TOFU）；
- 指纹不匹配直接拒绝，防止局域网中间人；
- 服务端只监听 `0.0.0.0:53317`（可在配置里改端口），关闭即停止。

## 5. 接收落盘

- 接收目录由 `LocalSendOptions.destDir` 指定（Android 默认 `应用存储/LocalSend`）；
- 上传先写 `.localsend-<session>-<file>.part`，校验通过后 `rename` 成正式文件名；
- 重名自动 `name (1).ext`；
- 文件名拒绝 `/`、`\`、`..`、控制字符；单文件上限 100 GiB；
- 会话 10 分钟未完成自动清理临时文件。

## 6. Android 入口

- `我的 → 近邻传输`：开启/关闭、查看本机指纹、附近设备、手动 IP；
- 文件「⋯ → 发送到附近设备…」；
- 多选底部操作条「发送」；
- `CHANGE_WIFI_MULTICAST_STATE` 权限 + `MulticastLock`（Android 组播必需）。

FFI：

```kotlin
val handle = core.startLocalSend(LocalSendOptions(...))
handle.info()          // alias / port / fingerprint
handle.peers()         // 已发现设备
handle.registerAt(ip, port, fingerprint)
handle.send(peer, ids)
core.stopLocalSend()
```

## 7. 跨平台注意事项

- **证书生成/TLS**：`rcgen` + `rustls(ring)`，Android 已验证编译；iOS 目标相同；
  鸿蒙 `aarch64-unknown-linux-ohos` 需要验证 `ring` 是否能编，若不行改用
  `rustls` 的纯 Rust provider（如 `rustls-rustcrypto`）。
- **组播权限**：
  - Android：`CHANGE_WIFI_MULTICAST_STATE` + `MulticastLock`；
  - iOS：Local Network 权限 + Multicast entitlement；
  - 鸿蒙：局域网/组播权限单独申请。
- **后台存活**：Android 目前依赖 App 前台进程；后续应复用传输前台服务
  （`dataSync` FGS）保证锁屏/切后台仍可接收。
- **反向下载**：官方 LocalSend 的浏览器下载 API 未实现；需要时再加。

## 8. 验证

```bash
cargo test -p sfiles-localsend
```

包含：
- HTTPS + 指纹固定下的 `register → prepare-upload → upload` 全链路；
- 错误指纹必须被拒绝；
- 两个实例通过组播互相发现；
- 文件重名/非法文件名/分块落盘。

Android 构建：

```bash
./scripts/build-android.sh
cd apps/android && ./gradlew assembleDebug
```
