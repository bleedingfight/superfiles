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

## M1 — 可用（下一步）

- [ ] 传输任务持久化（SQLite `transfers` 表），杀进程可恢复
- [ ] 断点续传：记录 per-file offset，重启后继续
- [ ] 列表结果写索引；离线浏览（断网展示缓存 + 过期标记）
- [ ] 批量选择、重命名、移动（跨后端走复制+删除）
- [ ] 冲突对话框（覆盖/跳过/重命名/全部应用）
- [ ] Android：Foreground Service + 通知进度
- [ ] iOS：HTTP 后端的 background URLSession
- [x] FTS5 搜索（中文分词/拼音）替换 LIKE（trigram：中文子串 + 全拼/首字母拼音 + 英文，默认 FTS5、短查询回退 LIKE；`source` 列为 M2 聚合索引打底）

验收：1 GB 文件传输、杀进程后恢复、断网下能看缓存目录。

## M2 — 网络存储

- [x] SMB2/3 后端（NTLMv2、原生随机读写/truncate/rename、`set_info` 语义删除、futures 流式列目录、断连重挂；真机矩阵 `tests/smb_live.rs`：Samba 4.12 全 pass）。注意：与 `russh` 的 dalek 冲突仅在 Apple 平台存在，SFTP 接入时需解
- [ ] SFTP 后端（`russh` + `russh-sftp`，同上依赖冲突）
- [x] WebDAV 后端（vfs-core 层：PROPFIND/Range GET/PUT，`PATCH X-Update-Range`↔`PUT Content-Range` 自动协商，mock-server 单测 + 真机矩阵种子 `tests/webdav_live.rs`）
- [x] 真机矩阵首轮：Apache mod_dav 全pass（协商到 Content-Range PUT）；Nextcloud 27 浏览/整文件CRUD pass，但**禁用两种部分写方言**（PATCH 走自家 chunking v2 → 500；Content-Range PUT 显式 400）→ 如实报 Unsupported，大文件分块上传需引擎侧临时文件策略（见下条）
- [ ] WebDAV 接入 FFI 连接管理；引擎对 `can_random_write=false` 目标实现临时文件+整体 PUT 策略（Nextcloud 必需的 fallback）；群晖/威联通真机轮测
- [ ] 设备发现：mDNS + WS-Discovery
- [ ] iOS File Provider 扩展（Replicated，iOS 16+）
- [ ] Android `DocumentsProvider`
- [x] 本地回环 HTTP 服务（Range）供 AVPlayer/ExoPlayer 播远程视频（`crates/stream`：token 保护 URL、206/416、HEAD、并发连接；FFI 暴露随 WebDAV 连接管理一起做）
- [ ] 连接管理 UI（凭据存 Keychain/Keystore）

验收：手机能在系统「文件」App 里浏览 NAS；电视能直接播 NAS 视频。

## M3 — 云盘聚合

- [ ] S3 兼容（OSS/COS/R2/MinIO）
- [ ] OneDrive / Google Drive / Dropbox OAuth
- [ ] 多账号、限流退避、配额显示
- [ ] 双向同步（可选）：冲突版本保留策略
- [ ] 离线收藏与自动下载

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
- 鸿蒙 NEXT/TV（ArkTS + `uniffi-bindgen-arkts`）
- tvOS（仅「网络存储浏览 + 播放 + 投屏」）

## 风险登记

| 风险 | 影响 | 缓解 |
|---|---|---|
| iOS 后台 SMB 传输不成立 | 用户预期落空 | 文案明确「需保持前台」+ 前台传输优化 |
| SMB 兼容性 | 大量长尾 bug | 先支持 SMB2/3+NTLM；建立真实 NAS 测试矩阵 |
| 云盘 API 限流/变动 | 下载失败 | 统一退避与配额层；抽象 `CloudProvider` |
| 全原生 UI 成本 | 迭代变慢 | 内核做厚；共享设计 token；按平台只写必要 UI |
| 商店审核（全盘权限） | 上架延迟 | 首版用 SAF/MediaStore；全盘作为高级模式 |
