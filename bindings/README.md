# Generated bindings

本目录下的 Swift / Kotlin / ArkTS 代码由 `uniffi-bindgen` 根据 Rust 的导出接口生成，**不要手改**。

重新生成：

```bash
./scripts/gen-bindings.sh         # swift + kotlin
./scripts/gen-bindings-arkts.sh   # HarmonyOS（ArkTS 包 + N-API adapter crate）
```

- `bindings/swift/` 被 iOS 构建脚本拷贝到 `apps/ios/Generated/`
- `bindings/kotlin/` 被 Android Gradle 直接引用（`sourceSets.main.java.srcDirs`）
- `bindings/arkts/` 被 HarmonyOS 工程引用（`apps/ohos/entry/oh-package.json5` 以
  `file:` 依赖引入）；其中 `native/` 是生成的 N-API adapter crate，需用
  `scripts/build-ohos.sh` 交叉编译（gen 脚本会自动补 `[workspace]` 隔离并
  对齐 uniffi 版本号）

修改 `crates/sfiles-ffi` 的导出签名后，必须重新生成并一起提交，否则运行时会触发
UniFFI 的 checksum 校验失败。
