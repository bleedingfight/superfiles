# 平台能力矩阵与落地方式

## 1. 能力边界（先认清，再设计）

| 平台 | 任意目录浏览 | 主要落地方式 | 关键限制 |
|---|---|---|---|
| Windows | ✅ | Win32 FS API + WinUI3 | 无（注意长路径、UNC） |
| macOS | ✅ | AppKit/SwiftUI + FS API | TCC（桌面/文档/下载）、App Store 沙箱 |
| Linux | ✅ | GTK4 + FS API | 发行版打包（deb/AppImage/Flatpak） |
| Android 手机/平板 | ⚠️ 部分 | SAF + `MANAGE_EXTERNAL_STORAGE` + MediaStore | 商店政策要求用途声明；Android 15+ 复查更严 |
| Android TV | ⚠️ 部分 | 同一 APK + leanback/D-pad 焦点 | 无触摸；遥控器焦点图谱要手写 |
| iOS / iPadOS | ❌ | 容器 + `UIDocumentPicker` + **File Provider 扩展** | 无法访问其他 App 数据；后台传输受限 |
| 鸿蒙 NEXT | ❌ | ArkTS 沙箱 + Picker/FileShare；Rust 走 N-API | 同 iOS 类沙箱 |
| 鸿蒙 4 及以下 | ⚠️ | 直接跑 Android APK | 后续版本不再兼容 |
| tvOS | ❌ 基本不可行 | 最多做「网络存储浏览 + 播放 + 投屏」 | 无文件系统、无文档选择器 |
| Tizen/webOS 电视 | ❌ | Web 应用 | 只能做媒体聚合 |

结论：**桌面 + Android(含 TV) 做完整文件管理；iOS/鸿蒙做「文件提供者 + 云/网络浏览器」；tvOS 只做媒体端或不做。**

## 2. iOS 具体方案

| 需求 | 实现 |
|---|---|
| 自己的文件在系统「文件」App 可见 | `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`（M0 已开） |
| 让云盘/SMB 出现在系统「文件」App | File Provider 扩展（iOS 16+ `NSFileProviderReplicatedExtension`） |
| 导入/导出任意文件 | `UIDocumentPickerViewController` + Share Extension |
| 远程视频直接播放 | 内核起本地回环 HTTP（127.0.0.1 + 随机端口 + token，支持 Range），AVPlayer 播该 URL |
| 后台下载 | 仅 HTTP 类后端可用 `URLSession` background；SMB/SFTP **无法真正后台**，只能前台 + `BGProcessingTask` 收尾 |
| 相册媒体 | PhotoKit（读取），导出走 Share/保存到相册 |
| 凭据 | Keychain；File Provider 与主 App 通过 App Group 共享容器 |
| iPad 界面 | `NavigationSplitView` 三栏（位置侧栏 / 文件列表 / 详情）；图片与视频内联预览，其余 QuickLook；复制/移动目标选择器 + 传输进度 |

产品定位：**「文件与云存储浏览器 + 系统文件提供者」**，不要宣称「系统文件管理器」。

## 3. Android 具体方案

| 需求 | 实现 |
|---|---|
| 全盘管理 | `MANAGE_EXTERNAL_STORAGE` + `Environment.isExternalStorageManager()` 引导页 |
| SD 卡 / U 盘 | SAF（`ACTION_OPEN_DOCUMENT_TREE`）+ `StorageVolume` + 持久化 URI 权限 |
| 把云盘暴露给系统 | `DocumentsProvider` |
| 长时间下载/上传 | Foreground Service（`dataSync`）+ 通知进度 + 断点状态落库 |
| 媒体库 | MediaStore 增量扫描（`getGenerationModified`） |
| 局域网发现 | `NsdManager`（mDNS）+ WS-Discovery 找 SMB |
| 播放 | Media3/ExoPlayer，直接使用本地回环 HTTP URL |
| TV | 同一 APK，`LEANBACK_LAUNCHER`（已加）；焦点图谱、16:9 安全区、字号 ≥20sp |

### 3.1 多语言（Android）

- 默认资源 = 英文（`values/strings.xml`），简体中文在 `values-zh/strings.xml`，繁體在 `values-b+zh+Hant/strings.xml`（OpenCC `s2twp`，同时覆盖 zh-TW / zh-HK）；非中/英文系统回退英文。
- `res/xml/locales_config.xml` 声明 `en` / `zh-Hans` / `zh-Hant`，Android 13+ 可在「设置 → App → 语言」单独切换。
- 文案统一 `L10n.t(R.string.…)`（Application 上下文初始化），Compose / ViewModel / 前台服务/通知共用；带参数用 `%1$s` 占位。
- 新增文案：两套 XML 同步加同名字符串（key 为内容哈希/递增编号），中文自然语言搜索的关键词表（`NaturalLanguageQueryParser`）是解析器数据，不参与 UI 翻译。

## 4. 鸿蒙（M2 spike 已落地）

- 鸿蒙 NEXT：ArkTS UI（`apps/ohos`）+ Rust 内核走 N-API。
  - 绑定：ohos-rs/uniffi-bindgen-arkts 从同一 `libsuperfiles.so` 生成 ArkTS
    包 + N-API adapter crate（`bindings/arkts`）。注意：该工具发布版只支持
    uniffi 0.31，本仓库用 0.32，需按 `scripts/gen-bindings-arkts.sh` 头注释
    打 4 处小补丁（0.32 元数据与 API、`Type::Box/Set` 新变体、callback 的
    u64→BigInt / f32→f64 修正）。
  - 交叉编译：`scripts/build-ohos.sh`（aarch64-unknown-linux-ohos，NDK clang；
    `russh` 必须用 `ring` provider——默认的 aws-lc-rs 含 CMake+ARM 汇编，是
    OHOS 交叉编译的头号坑）。产物：内核 `libsuperfiles.so` + adapter
    `libsuperfiles_arkts.so`，两个都打进 HAP。
  - 沙箱内可访问：应用沙箱目录、Picker 选择的文件、FileShare。
  - TMPDIR：OHOS 应用进程无 TMPDIR 且 /tmp 不可写，内核已在
    `SuperFiles::open` 时兜底到 `<local_root>/.tmp`。
  - spike 页已验证：open + createFile + list 真机链路（见 apps/ohos/README）。
- 鸿蒙 TV：同一 ArkTS 工程做布局适配（遥控器焦点）。
- 鸿蒙 4 及以下：直接复用 Android APK。

## 5. 桌面（规划）

| 平台 | UI | 内核接入 |
|---|---|---|
| macOS | SwiftUI 复用 iOS 视图 60% + AppKit 菜单/QuickLook 插件 | 同一个 xcframework |
| Windows | WinUI 3 | Rust C ABI（`staticlib` + `cbindgen` 或 UniFFI C#） |
| Linux | GTK4/libadwaita | 同上；已有 `sfiles` CLI 可用 |

## 6. 各平台「不可做」的诚实清单

- iOS：读不到其他 App 的沙箱；没有系统级文件关联管理；后台 SMB 传输不成立。
- Android：Scoped Storage 下不能随意写别人 App 的目录；`MANAGE_EXTERNAL_STORAGE` 有商店审核风险。
- 鸿蒙 NEXT：同类沙箱限制，且生态 API 仍在演进。
- tvOS：没有文件系统访问，产品形态只能是媒体浏览。
- 所有 TV：文本输入困难，路径输入类交互要改成「浏览 + 收藏 + 最近」。
