# Super Files

跨平台文件管理应用。目标平台：Windows / macOS / Linux / Android(含 TV) / iOS / 鸿蒙(含 TV)，后续 tvOS。

当前状态：**M0 骨架可编译、可测试**。Rust 内核 + iOS(SwiftUI) / Android(Compose) 两端工程骨架 + 自动生成绑定。

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

M0 只浏览应用私有目录（`filesDir/storage`），因此不需要任何存储权限。全盘访问、SAF、DocumentsProvider 在 M1/M2。

## iOS

需要 macOS + Xcode。

```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
brew install xcodegen
./scripts/build-ios.sh        # 生成 Generated/ 与 SuperFilesCore.xcframework、.xcodeproj
open apps/ios/SuperFilesApp.xcodeproj
```

在 Signing & Capabilities 里选择自己的 Team 后即可真机/模拟器运行。M0 已开启 `UIFileSharingEnabled`，App 容器会出现在系统「文件」App 里。

## 绑定生成

```bash
./scripts/gen-bindings.sh
```

`bindings/` 是提交进仓库的（Android 直接引用，iOS 构建脚本拷贝），修改 Rust 导出 API 后必须重新生成并一起提交。

## 已实现 / 未实现

- [x] VFS 抽象、URI 规范、能力矩阵、本地后端（含 `..` 逃逸防护）
- [x] 分块读写、fd 直通（`export_to_fd` / `import_from_fd`）
- [x] 传输引擎：预扫描总量、进度、取消、覆盖/跳过/重命名
- [x] SQLite 索引 + 文件名搜索
- [x] SwiftUI / Compose 可运行骨架
- [x] WebDAV 后端（vfs-core 层：PROPFIND / Range GET / PUT、PATCH 与 Content-Range 部分写协商、受限重试；mock-server 单测 + Apache/Nextcloud 真机矩阵）
- [x] SMB 后端（vfs-core 层：**原生随机读写**/SET_END_OF_FILE、NT 状态码错误映射、受限重试 + 断连重挂；id↔UNC 单测 + Samba 真机矩阵）
- [x] 回环 HTTP+Range 流媒体服务（`StreamServer::url_for(id)` 拿到可播 URL；token 保护、206/416 语义、并发 seek）
- [ ] SFTP / 云盘后端（M2/M3）
- [ ] WebDAV 的 FFI 连接管理与真机兼容矩阵（M2）
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
- `design/` — Figma 对接物：`tokens.json` (W3C DTCG)、`style-guide.html`（可视参考稿）、`screens.md`（画面清单）
- `docs/adr/` — 架构决策记录
