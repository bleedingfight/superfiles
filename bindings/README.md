# Generated bindings

本目录下的 Swift / Kotlin 代码由 `uniffi-bindgen` 根据 Rust 的导出接口生成，**不要手改**。

重新生成：

```bash
./scripts/gen-bindings.sh
```

- `bindings/swift/` 被 iOS 构建脚本拷贝到 `apps/ios/Generated/`
- `bindings/kotlin/` 被 Android Gradle 直接引用（`sourceSets.main.java.srcDirs`）

修改 `crates/sfiles-ffi` 的导出签名后，必须重新生成并一起提交，否则运行时会触发
UniFFI 的 checksum 校验失败。

后续鸿蒙可使用 `uniffi-bindgen-arkts` 从同一个 `libsuperfiles` 生成 ArkTS 绑定。
