# Super Files

跨平台文件管理应用。目标平台：Windows / macOS / Linux / Android(含 TV) / iOS / 鸿蒙(含 TV)，后续 tvOS。

当前状态：**M1「可用」已完成**（离线浏览 / 批量操作 / 冲突对话框 / 前台服务传输 / iOS 后台下载）。Rust 内核 + iOS(SwiftUI) / Android(Compose) 两端 + 自动生成绑定。

## 架构一句话

UI 全原生，逻辑全共享：Swift/Kotlin 只写界面和平台适配，文件系统、传输引擎、索引都用同一份 Rust 内核（通过 UniFFI 暴露）。

```
crates/vfs-core     统一虚拟文件系统 + local（jailed）/ WebDAV / SMB 后端
crates/engine       传输引擎：预扫描、分块、进度、取消、冲突策略
crates/index        SQLite 元数据索引 + 搜索
crates/stream       回环 HTTP+Range 媒体流服务（供 AVPlayer/ExoPlayer 直接播放任意后端）
crates/sfiles-ffi   UniFFI 出口（Swift/Kotlin 绑定源）
crates/sfiles-cli   桌面 CLI（冒烟测试 / 未来终端端）
bindings/swift      uniffi 生成的 Swift
bindings/kotlin     uniffi 生成的 Kotlin
apps/ios            SwiftUI 应用
apps/android        Jetpack Compose 应用（同 APK 支持 TV）
docs                架构、平台能力矩阵、API 契约、路线图、ADR
```

模块布局采用 2018+ 风格（`backends.rs` + `backends/`，不使用 `mod.rs`）。

## 快速开始（任意 Linux/macOS，无需 Xcode/Android SDK）

```bash
cargo test                 # 30+ 个内核/引擎测试
cargo build
./scripts/gen-bindings.sh  # 重新生成 Swift/Kotlin 绑定

# 用一个临时目录体验内核
mkdir -p /tmp/sf/storage && echo hi > /tmp/sf/storage/a.txt
./target/debug/sfiles ls /tmp/sf/storage
./target/debug/sfiles index /tmp/sf/storage /tmp/sf/index.sqlite
./target/debug/sfiles search /tmp/sf/index.sqlite a.txt
```

## Android

前置：JDK **17 或 21**（JDK 25 会让 Kotlin 2.1 报 `IllegalArgumentException: 25.0.4`），Android SDK 35，NDK 27。

```bash
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
cargo install cargo-ndk
export ANDROID_NDK_HOME=$HOME/Android/Sdk/ndk/27.0.11718014
./scripts/build-android.sh                    # 编译 Rust -> jniLibs
cd apps/android
JAVA_HOME=/usr/lib/jvm/java-21-openjdk ./gradlew assembleDebug
```

产物：`apps/android/app/build/outputs/apk/debug/app-debug.apk`（已验证编译通过，包含 3 个 ABI 的 `libsuperfiles.so`）。
用 Android Studio 打开 `apps/android` 也可以，注意把 Gradle JDK 指到 21 而不是 Studio 自带的 JDK 25。

> ⚠️ 改了 `crates/sfiles-ffi` 后必须重跑 `build-android.sh` 再打包；否则 bindings（新）
> 配 jniLibs（旧）会在启动时 `UnsatisfiedLinkError: undefined symbol: uniffi_...` 闪退。

M0 只浏览应用私有目录（`filesDir/storage`），因此不需要任何存储权限。全盘访问、SAF、DocumentsProvider 在 M1/M2。

## iOS

需要 macOS + Xcode。

```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
brew install xcodegen
./scripts/build-ios.sh        # 生成 Generated/ 与 SuperFilesCore.xcframework、.xcodeproj
open apps/ios/SuperFilesApp.xcodeproj
```

在 Signing & Capabilities 里选择自己的 Team 后即可真机/模拟器运行。已开启 `UIFileSharingEnabled`，App 容器会出现在系统「文件」App 里。

iPad 版为三栏 `NavigationSplitView`：

- 侧栏：应用存储 / 最近打开 / 收藏 / 网络存储（WebDAV、SMB、SFTP）/ 传输中心；
- 中栏：当前目录 / 搜索结果 / 最近 / 收藏，右键菜单支持预览、复制到…、移动到…、重命名、收藏、删除；
- 右栏：详情（图片、视频内联；PDF/Office 走 QuickLook），可分享、下载到「文件」App。

网络存储密码保存在系统 Keychain；复制/移动使用内核引擎并在传输中心显示进度。iPhone / Slide Over 折叠时详情自动改为 sheet 呈现。

## 绑定生成

```bash
./scripts/gen-bindings.sh
```

`bindings/` 是提交进仓库的（Android 直接引用，iOS 构建脚本拷贝），修改 Rust 导出 API 后必须重新生成并一起提交。

## 已实现 / 未实现

- [x] VFS 抽象、URI 规范、能力矩阵、本地后端（含 `..` 逃逸防护）
- [x] 分块读写、fd 直通（`export_to_fd` / `import_from_fd`）
- [x] 传输引擎：预扫描总量、进度、取消、覆盖/跳过/重命名
- [x] SQLite 索引 + FTS5 文件名搜索（trigram 子串：中文/英文/混合；拼音全拼与首字母 sidecar；大小写不敏感；可按 source 聚合过滤）
- [x] SwiftUI / Compose 可运行骨架
- [x] Android 首页按 Figma「栖档」稿 1:1 还原 + 底部 4 Tab 骨架（样例数据，M1 接真实状态）
- [x] 首页联动：问候语按时段切换、用量卡读真实存储（StatFs）、文件夹卡 → 全树类型过滤、搜索框 → 文件 Tab 自动聚焦
- [x] 模糊搜索开箱即用：首启自动建索引（FTS5 trigram 子串 + 拼音全拼/首字母）；locate 式**跨根合并搜索**（沙盒 + 共享 + 全盘索引并行查询、去重排序），任意目录/任意根下闪电命中
- [x] 双配色：浅色 = Figma 基线，深色 = 派生草案（tokens.json `color.dark`），随系统夜间模式 + 边到边沉浸
- [x] 文件「⋯」操作菜单：复制/移动（统一目标选择器，任意源 ↔ 任意目标：本地↔共享↔WebDAV/SMB/SFTP；移动=复制后删源）、详细信息、压缩（Rust 引擎流式 zip + 进度回调 + 大文件进度条）、重命名、打开方式（FileProvider/流式 Provider）、删除、上传（目标选择器 → 引擎复制，可落本地/NAS/云盘）
- [x] 「最近打开」真实化：索引 `recent_opens` 表（同路径去重、按打开时间倒序），打开文件即记录，首页实时刷新；文件单击 = 系统默认程序直开
- [x] 共享存储浏览：`MANAGE_EXTERNAL_STORAGE` 授权后「管理 → 内部共享存储」直接以 `/storage/emulated/0` 为根浏览（独立索引库，手动 FAB 建索引）；「⋯」菜单全局宿主，首页最近列表与文件页共用
- [x] 云存储接入框架（骨架）：OAuth2 + PKCE 授权、加密令牌存储、自动刷新、`superfiles://oauth/callback` 深链；provider 注册表含百度/阿里云盘/123盘占位，配置凭据 + Rust Backend 即可接入（见 docs/07-cloud-providers.md）
- [x] WebDAV 后端（vfs-core 层：PROPFIND / Range GET / PUT、PATCH 与 Content-Range 部分写协商、受限重试；mock-server 单测 + Apache/Nextcloud 真机矩阵）
- [x] SMB 后端（vfs-core 层：**原生随机读写**/SET_END_OF_FILE、NT 状态码错误映射、受限重试 + 断连重挂；id↔UNC 单测 + Samba 真机矩阵）
- [x] 回环 HTTP+Range 流媒体服务（`StreamServer::url_for(id)` 拿到可播 URL；token 保护、206/416 语义、并发 seek）
- [x] FFI 连接管理与流媒体出口：`mountWebdav/mountSmb/mounts/unmount/streamUrl`（同协议多实例按 root 前缀分流挂载）
- [x] 断点续传（M1）：SQLite `transfers` 表 + per-file offset checkpoint（每 16 chunk 落盘）；`startCopy` 自动入日志，杀进程后 `pendingTransfers()/resumeTransfer(id)` 从断点继续
- [x] 离线浏览（M1）：`list()` 成功即写索引（upsert + 删除对账 + `list_states` 时间戳）；实时列举失败回退 `listCached()`，UI 显示「离线缓存 · 更新于 X」横幅（Android/iOS）
- [x] 批量选择（M1）：长按进入多选 + 全选 + 返回退出；底部操作条复制/移动/压缩/删除；移动跨后端复制+删除
- [x] 冲突对话框（M1）：复制/移动前探测同名，逐项「覆盖/跳过/重命名」+「全部应用」，按策略分组下发引擎
- [x] 传输前台服务（M1，Android）：`dataSync` FGS 保活 + 通知栏实时进度（活跃时拉启、空闲退场）
- [x] iOS 后台下载（M1）：background URLSession（任务映射持久化、同名避让、冷启动事件回投），「下载到本地」经回环 streamUrl
- [x] iOS / iPadOS 客户端：三栏 `NavigationSplitView`（位置 / 列表 / 详情）、WebDAV/SMB/SFTP 挂载（密码进 Keychain）、复制/移动 + 传输进度、收藏/最近/搜索、QuickLook 与内联视频预览、系统分享
- [x] 近邻传输（LocalSend 兼容）：HTTPS 自签证书 + SHA-256 指纹固定、组播发现 + 手动 IP 兜底、接收端流式落盘（sha256/重名避让/临时文件清理）、发送与批量发送；Android 入口「我的 → 近邻传输」，iOS/鸿蒙共用同一 Rust 协议核
- [x] 就近分享原型（M3.5，ADR 0005）：选中文件 → 内网「链接 + 二维码」，浏览器免安装直接收（HTML 索引页），App 侧「接收文件」粘贴链接 → manifest 清单 → 分块拉取经 VFS 落盘（目标可为本地或 NAS，重名自动避让、半成品即删）；token 防枚举、关闭即焚；iOS 待跟进
- [x] 文件详情整页（对稿 design/figma/04）：预览卡（图片解码 / PDF 首页渲染+页数 / 视频首帧+时长）、标题+类型 chip、元信息卡（所在位置可跳转/修改时间/存储状态）、标签占位、重命名/移动/删除操作区、底栏（分享文件/下载到本地/更多）、收藏星标；远端文件缩略图暂回退类型图标
- [x] 稳定性：UniFFI 对象释放管线加固（`SuperFiles::drop` 把 vfs/索引/流服务/分享的最终释放转移到 tokio runtime 上下文并隔离 panic，GC 线程不再触发 SIGABRT）；索引锁中毒容忍（移动端进程随时被杀，中毒 ≠ 数据损坏）
- [x] 传输吞吐与可观测（SMB 复制 5MB/s → 目标带宽上限）：SMB 顺序读句柄跨 chunk 复用（省每块 CREATE/CLOSE 往返）+ 复制块 1 MiB + 引擎双缓冲流水线（写当前块时预取下一块）；传输中心/前台通知实时显示速度（轮询差值 + EMA 平滑）
- [x] SMB 真机压测与根因（192.168.31.10/Media，180MiB）：定位到 `smb-transport` 从不设 `TCP_NODELAY`，Nagle + 延迟 ACK 让每个 SMB 往返固定多付 ~40ms（1MiB 读 52ms → 19MiB/s）；vendor 一行补丁后单流 82MiB/s、引擎整文件复制 84.6MiB/s（smbclient 基线 103MiB/s）
- [x] 本地目录「秒开」：FTS 改按 `rowid` 删除（`id` 是 UNINDEXED，旧写法每行全表扫；5000 条约 3.3s → 47ms，42000 条索引下收益更大）+ `list()` 的索引写入移到后台写线程（按目录合并、内容未变整单跳过），前台只付 readdir+stat
- [x] 传输前台/后台分离：复制/移动先弹 App 内进度浮层（当前文件 + 总进度 + 速度），提供「终止 / 后台传输」；按下「后台传输」后才进入传输中心与通知栏，App 退到后台自动等价于按下它
- [x] 列表视觉（方案 A）：文件浏览页/首页分组统一「一组一张白卡 + 行间 0.5dp 发丝线」，长列表用首末圆角滚动卡片；复制/移动目标选择器改为品牌风对话框（暖底 + 白卡候选列表 + 17w700 标题 + 实心主按钮，字号/色板与首页同源）
- [x] 目录选择器体验：索引缓存秒开 + 后台实时刷新（10s 节流），隐藏文件沿全局开关过滤（目标选择器/压缩目录树一视同仁）
- [x] Android 多语言（简体 / 繁體 / English）：默认英文、`values-zh` 简体、`values-b+zh+Hant` 繁體（OpenCC s2twp），系统语言自动切换 + Android 13「单应用语言」（`locales_config.xml`）；UI/通知/ViewModel 文案统一走 `L10n.t(R.string.…)`（447 条，含参数化文案），非中文系统回退英文
- [x] 横屏/大屏自适应（docs/06 §7）：≥600dp 首页双列（左：问候/用量/本地存储，右：网络/收藏/最近）避免两侧大片留白；详情页宽窗「左预览 / 右信息」双列 + 底栏同宽居中；矮窗（横屏手机）/平板把底部导航换 `NavigationRail`；文件/收藏/我的/传输中心/近邻传输列表与网络存储表单 840dp 限宽居中，对话框 560dp 上限；竖屏保持 Figma 单列像素级不变
- [x] SFTP 后端（vfs-core 层：russh 0.55 + russh-sftp，密码/私钥认证、原生随机读写 + SETSTAT.fsize、断线惰性重连 + 受限重试；id↔路径越狱单测 + OpenSSH 真机矩阵 `tests/sftp_live.rs`）
- [ ] 云盘后端（M2/M3）
- [ ] iOS File Provider 扩展、Android DocumentsProvider（M2）
- [ ] 媒体库、播放、投屏（M4）
- [ ] Android TV 焦点优化、iPad 多窗口（M5）

详见 `docs/04-roadmap.md`。

## 文档

- `docs/01-architecture.md` — 分层、线程模型、错误与进度
- `docs/02-platform-matrix.md` — 各平台能力边界与落地方式
- `docs/03-vfs-api.md` — 内核 API 契约（实现后端必读）
- `docs/04-roadmap.md` — M0–M5 任务清单
- `docs/05-icons.md` — 双端文件图标规范（fallback 链 + 特化表）
- `docs/06-design-system.md` — 双端设计系统基准（tokens、组件状态表、TV 焦点模型）
- `docs/10-localsend.md` — 近邻传输（LocalSend 兼容：HTTPS/发现/接收/发送）
- `design/` — Figma 对接物：`tokens.json` (W3C DTCG)、`style-guide.html`（可视参考稿）、`screens.md`（画面清单）
- `docs/adr/` — 架构决策记录
