# 路线图

## M0 — 骨架（✅ 已完成）

- [x] Rust workspace：`vfs-core` / `engine` / `index` / `sfiles-ffi` / `sfiles-cli` / `sfiles-bindgen`
- [x] Entry id 规范、`Backend` trait、能力矩阵、错误分类
- [x] 本地后端（root jail、符号链接、名字校验）
- [x] 分块读写 + fd 直通（`read_to_fd` / `write_from_fd`）
- [x] 传输引擎：预扫描、进度、取消、覆盖/跳过/重命名
- [x] SQLite 索引（WAL），文件名搜索、LIKE 转义
- [x] UniFFI 绑定生成（Swift + Kotlin），提交到 `bindings/`
- [x] iOS SwiftUI 应用（浏览、新建文件夹、删除、索引、搜索入口）
- [x] Android Compose 应用（同上 + LEANBACK 入口）
- [x] 内核单测 11 个 + FFI 门面测试 2 个 + CLI 冒烟
- [x] Android APK 实际编译通过（Gradle 8.14.3 + JDK 21 + NDK 27，含 3 ABI 的 `.so`）

验收：`cargo test` 全绿；`./target/debug/sfiles ls/cp/index/search` 可用；Android `assembleDebug` 通过；iOS 工程需在 macOS 上 `scripts/build-ios.sh` 后编译。

## M1 — 可用（✅ 已完成）

- [x] 传输任务持久化（SQLite `transfers` 表），杀进程可恢复
- [x] 断点续传：记录 per-file offset，重启后继续
- [x] 列表结果写索引；离线浏览（`list()` 成功即 upsert + 删除对账 + `list_states` 更新时间戳；实时列举失败 UI 回退 `listCached()` 并显示「离线缓存 · 更新于 X」横幅；Android/iOS 双端）
- [x] 批量选择、移动（复制/删除）：长按进入多选（选择顶栏 + 全选 + 返回键退出），底部操作条复制/移动/压缩/删除；移动跨后端走复制+删除（引擎事务完成后清理源）；重命名为单条「⋯」菜单既有能力
- [x] 冲突对话框（覆盖/跳过/重命名/全部应用）：复制/移动前探测目标同名项，逐项弹窗（批量显示「第 N/M 项」），决策完按策略分组下发引擎（跳过组不下发）
- [x] Android：Foreground Service（`dataSync`）+ 通知栏实时进度（活跃传输拉启、空闲退场；POST_NOTIFICATIONS 运行时申请；修复传输轮询/取消/恢复跨内核路由）
- [x] iOS：HTTP 后端的 background URLSession（`BackgroundDownloadManager`：任务映射持久化、同名避让、完成事件经 AppDelegate 冷启动回投；行内「下载到本地」经回环 streamUrl 落 Documents/下载/；ATS 放开本地网段）
- [x] FTS5 搜索（中文分词/拼音）替换 LIKE（trigram：中文子串 + 全拼/首字母拼音 + 英文，默认 FTS5、短查询回退 LIKE；`source` 列为 M2 聚合索引打底）
- [x] 索引与文件系统联动：增/删/改名/写入/复制/移动/压缩/解压成功后当场更新索引（删除立刻搜不到；目录改名纯 SQL 改前缀），读操作不再被扫描队列阻塞
- [x] 索引范围与索引管理（Android）：本地存储（沙盒 + 共享存储）启动时自动增量索引；SMB/WebDAV/S3/云盘只有用户点「建立索引」后才入库；「我的 → 索引管理」按存储列出已索引条目数，左滑删除（本地索引删除前警告并说明后果），可单独重建
- [x] 分类聚合走索引：`ext` 列 + 复合索引（`ext, modified_ms DESC`）；首屏 240 条走紧凑字节流（一次跨语言拷贝，避免 uniffi 逐字符串 JNA），剩余后台续载；隐藏文件默认不计入，与「显示隐藏文件」开关一致

验收：1 GB 文件传输（FGS 保活）、杀进程后恢复（索引档案 + `pendingTransfers`）、断网下能看缓存目录（`listCached` 回退）。

## M2 — 网络存储

- [x] SMB2/3 后端（NTLMv2、原生随机读写/truncate/rename、`set_info` 语义删除、futures 流式列目录、断连重挂；真机矩阵 `tests/smb_live.rs`：Samba 4.12 全 pass）。注意：与 `russh` 的 dalek/RC 依赖冲突已在 SFTP 接入时通过钉版解决（见下）
- [x] SFTP 后端（`russh` + `russh-sftp`，密码/私钥认证、原生随机读写/truncate/rename、session 断开惰性重连；真机矩阵 `tests/sftp_live.rs`：OpenSSH(linuxserver) 全 pass）。依赖冲突已解：russh 钉 0.55（其 crypto 家族与 sspi 的 RC 钉版完全不重叠，锁文件并存两份；分析见根 `Cargo.toml` 注释），SFTP 与 WebDAV/SMB 可同 feature 共存并默认启用
- [x] WebDAV 后端（vfs-core 层：PROPFIND/Range GET/PUT，`PATCH X-Update-Range`↔`PUT Content-Range` 自动协商，mock-server 单测 + 真机矩阵种子 `tests/webdav_live.rs`）
- [x] 真机矩阵首轮：Apache mod_dav 全pass（协商到 Content-Range PUT）；Nextcloud 27 浏览/整文件CRUD pass，但**禁用两种部分写方言**（PATCH 走自家 chunking v2 → 500；Content-Range PUT 显式 400）→ 如实报 Unsupported，大文件分块上传需引擎侧临时文件策略（见下条）
- [ ] WebDAV 接入 FFI 连接管理；引擎对 `can_random_write=false` 目标实现临时文件+整体 PUT 策略（Nextcloud 必需的 fallback）；群晖/威联通真机轮测
- [ ] 设备发现：mDNS + WS-Discovery
- [ ] iOS File Provider 扩展（Replicated，iOS 16+）
- [ ] Android `DocumentsProvider`
- [x] 本地回环 HTTP 服务（Range）供 AVPlayer/ExoPlayer 播远程视频（`crates/stream`：token 保护 URL、206/416、HEAD、并发连接；FFI 暴露随 WebDAV 连接管理一起做）
- [x] FFI 连接管理接口：`mountWebdav` / `mountSmb` / `mounts` / `unmount` / `streamUrl`（多 NAS 按 root 前缀分流）
- [x] iOS / iPadOS 客户端（三栏 `NavigationSplitView`：位置 / 列表 / 详情；WebDAV/SMB/SFTP 挂载、复制/移动 + 传输中心、收藏/最近/搜索、QuickLook/视频内联预览）
- [ ] 连接管理 UI（凭据存 Keychain/Keystore）

验收：手机能在系统「文件」App 里浏览 NAS；电视能直接播 NAS 视频。

## M3 — 云盘聚合

- [x] S3 兼容（OSS/COS/R2/MinIO）：SigV4 签名、path-style / virtual-host、`list-type=2` 分页、Range 下载、流式 PUT（UNSIGNED-PAYLOAD）、copy+delete 重命名、目录 marker 与递归删除；本地 moto/rclone 冒烟测试 `crates/vfs-core/examples/s3_smoke.rs`
- [x] OneDrive / Google Drive / Dropbox OAuth（Android + 鸿蒙：loopback PKCE；Dropbox 走 127.0.0.1 精确回调）
- [x] 115 设备码 + PKCE 授权（无 redirect、无 AppSecret）
- [ ] iOS 端云盘接入（内核已支持，缺 UI 与授权流程）
- [ ] 多账号、限流退避、配额显示
- [ ] 双向同步（可选）：冲突版本保留策略
- [ ] 离线收藏与自动下载

## M3.5 — 就近分享（ADR 0005）

- [x] ShareServer：LAN HTTP 服务（HTML 索引页 + manifest.json + Range 文件分发；token 防枚举；仅入选文件可达；关闭即焚）
- [x] Android 发送：⋯/多选「分享链接…」→ zxing 二维码 + 链接对话框（停止即焚）
- [x] Android 接收：文件页「⋯ → 接收文件…」粘贴链接 → 清单确认 → 分块拉取经 VFS 落盘（重名避让、半成品清理、逐文件进度）
- [ ] iOS 发送/接收（ShareServer 是同一份内核代码，接 UI 即可；后台续传受系统限制）
- [ ] 增强：扫码接收（相机）、目录直发（内部先打包）、App 对 App 断点续传
- 明确不做：设备发现/配对、自定义双端协议、互联网中继（见 ADR 0005）

验收（Android）：两部手机同 Wi-Fi，A 分享 1 个 100MB 视频 → B 浏览器直接下载成功；B 装 App → 粘贴链接收到「下载/DCIM」且可断在线缆（= Range）后重拉。

## M4 — 媒体库

- [ ] 增量扫描 + 元数据提取（平台 API：AVAsset/MediaMetadataRetriever）
- [ ] 剧集/相册聚合、去重（大小+哈希）
- [ ] 播放器（字幕、倍速、记忆进度）
- [ ] 投屏：Cast SDK + DLNA
- [ ] 相册时间线

## M5 — 打磨与 TV

- [ ] Android TV 焦点图谱、遥控器全流程、安全区
- [ ] iPad 多窗口/键盘快捷键/拖拽
- [ ] 无障碍（TalkBack/VoiceOver）、i18n
- [ ] 上传崩溃/性能（10 万文件目录、低端机）
- [ ] 隐私合规文案与商店材料

## 后续平台

- macOS（SwiftUI 复用 + AppKit 菜单/QuickLook 插件）
- Windows（WinUI3 + Rust C ABI）
- Linux（GTK4 + 同一个 CLI）
- 鸿蒙 NEXT/TV（ArkTS + `uniffi-bindgen-arkts`；M2 spike 已打通，见 docs/02 §4）
- tvOS（仅「网络存储浏览 + 播放 + 投屏」）

## 风险登记

| 风险 | 影响 | 缓解 |
|---|---|---|
| iOS 后台 SMB 传输不成立 | 用户预期落空 | 文案明确「需保持前台」+ 前台传输优化 |
| SMB 兼容性 | 大量长尾 bug | 先支持 SMB2/3+NTLM；建立真实 NAS 测试矩阵 |
| 云盘 API 限流/变动 | 下载失败 | 统一退避与配额层；抽象 `CloudProvider` |
| 全原生 UI 成本 | 迭代变慢 | 内核做厚；共享设计 token；按平台只写必要 UI |
| 商店审核（全盘权限） | 上架延迟 | 首版用 SAF/MediaStore；全盘作为高级模式 |
