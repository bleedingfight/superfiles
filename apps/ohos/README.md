# Super Files — HarmonyOS 客户端（spike）

ArkTS/ArkUI 壳 + 同一个 Rust 内核（经 UniFFI → N-API adapter 桥接）。

## 现状

- `entry/src/main/ets/pages/Index.ets` 是**打通链路的验证页**：打开沙箱根目录、
  建文件、列目录。真正的浏览/传输 UI 尚未实现（对齐 iOS 端信息架构重写）。
- 本目录由 DevEco Studio 打开（`Open → 选择 apps/ohos`）。

## 构建步骤

```bash
# 1. 一次性：rust target
rustup target add aarch64-unknown-linux-ohos

# 2. 一次性：安装 DevEco command-line-tools（含 OHOS NDK），或：
export OHOS_SDK=<command-line-tools>/sdk/default/openharmony

# 3. 生成 ArkTS 绑定（改了 crates/sfiles-ffi 的导出 API 后必须重跑）
./scripts/gen-bindings-arkts.sh        # 需要 uniffi-bindgen-arkts（见脚本头注释）

# 4. 交叉编译内核 + N-API adapter，产物拷到 entry/libs/arm64-v8a/
./scripts/build-ohos.sh

# 5. DevEco 里 Run；或命令行：
#    cd apps/ohos && hvigorw assembleHap
```

## 打包进 HAP 的两个 .so

| 文件 | 来源 |
|---|---|
| `libsuperfiles.so` | `crates/sfiles-ffi`（Rust 内核，UniFFI cdylib） |
| `libsuperfiles_arkts.so` | `bindings/arkts/native`（生成的 N-API adapter，动态链接前者） |

二者名字必须不同（module_name=`superfiles_arkts`，见 `crates/sfiles-ffi/uniffi.toml`）。

## 坑（已踩过）

- **桌面没有图标**：`module.json5` 的 `skills.actions` 必须是
  `action.system.home`（不是 `ohos.want.action.home`）。写错的话包能装、`aa
  start` 能拉起，但启动器不索引，桌面上找不到。
- **图标是空白方块**：`entry/src/main/resources/base/media/icon.png` 和
  `AppScope/.../app_icon.png` 要放真图，模板里的 1×1 透明占位图看不出来。
- 两者都改完必须重装（`./scripts/run-ohos.sh --no-rust`），改配置不进增量包。

## 打包与签名

```bash
# 构建 HAP（未签名）
export PATH="$HOME/command-line-tools/bin:$HOME/command-line-tools/sdk/default/openharmony/toolchains:$PATH"
export DEVECO_SDK_HOME="$HOME/command-line-tools/sdk"
cd apps/ohos && hvigorw assembleHap --mode module -p product=default --no-daemon
# 产物：entry/build/default/outputs/default/entry-default-unsigned.hap
```

HarmonyOS NEXT 真机只安装华为根证书链签发的 HAP（未签名会报
`code:9568320 no signature file`）。调试签名材料在 AppGallery Connect 生成：
调试证书（`.p12` + `.cer`）、按设备 UDID 注册后生成的调试 Profile（`.p7b`），然后：

```bash
java -jar $DEVECO_SDK_HOME/default/openharmony/toolchains/lib/hap-sign-tool.jar sign-app \
  -keyAlias <alias> -signAlg SHA256withECDSA -mode localSign \
  -appCertFile <cert>.cer -profileFile <profile>.p7b \
  -inFile entry-default-unsigned.hap -outFile entry-default-signed.hap \
  -keystoreFile <cert>.p12 -keystorePwd <pwd> -keyPwd <pwd>

hdc install entry-default-signed.hap
```

## 平台注意点（实现 UI 时逐条处理）

- 沙箱：只能写应用目录；`ctx.filesDir` 作为 local_root；`TMPDIR` 已由内核
  兜底到 `<local_root>/.tmp`（`ensure_writable_tmpdir`）。
- 凭据：`@ohos.security.asset`（Asset Store Kit）替代 Keychain。
- 后台传输：`backgroundTaskManager` 长时任务（`ohos.permission.KEEP_BACKGROUND_RUNNING`），
  能力远弱于 Android FGS，传输中心要按「前台任务 + 断点续传」设计。
- 局域网：LocalSend 组播发现需确认 multicast 权限策略。
- TV：`deviceTypes` 已含 `tv`，焦点/遥控器适配未做。
