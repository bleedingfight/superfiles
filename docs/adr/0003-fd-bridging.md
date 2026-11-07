# ADR 0003：字节不跨 FFI，只传文件描述符

- 状态：已采纳
- 日期：2026-11

## 背景

传输 4 GB 视频时，如果把数据分块传给 Swift/Kotlin 再写回磁盘，会带来：

- 每次调用复制一次 `Vec<u8>` → `Data` / `ByteArray`；
- 峰值内存翻倍（chunk 缓冲区 + 平台侧缓冲区）；
- 额外两次内存拷贝（Rust → FFI → 平台）。

## 决策

跨边界只传**句柄**：

- iOS：`FileHandle.fileDescriptor`
- Android：`ParcelFileDescriptor.detachFd()` / `FileOutputStream.fd`
- 内核用 `ManuallyDrop<File>` 包装，读写完成后不关闭 fd（所有权留给平台）。

Rust 内部的跨后端传输是 `read_range` → `write_range`，数据只在 Rust 内存里停留一个 chunk。

## 理由

- 内存常数级，不受文件大小影响。
- 少两次拷贝，传输速度接近原生。
- fd 的所有权语义简单：平台开、平台关。

## 约束

- 平台必须在调用期间保持 fd 有效（Swift/Kotlin 的 `withUnsafe...` / `use {}` 块）。
- 不支持 fd 的后端（纯 HTTP 云盘）在 `read_to_fd` 默认实现里退化为分块流，仍然不把字节交给 UI。

## 相关

`read_bytes` / `write_bytes` 仍保留，但只用于预览（几万字节），文档中明确标注。
