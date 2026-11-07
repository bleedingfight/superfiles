# ADR 0002：FFI 同步 + 轮询，而不是 async 导出

- 状态：已采纳
- 日期：2026-11

## 背景

UniFFI 支持 `async` 导出（`async_runtime = "tokio"`），会生成 Swift `async` / Kotlin `suspend`。
听起来更现代，但需要每端提供 tokio runtime context（Android JNI 线程默认没有），
并且和「传输任务生命周期长于一次调用」的模型不匹配。

## 决策

所有导出的方法都是同步的；内核内部持有一个全局 tokio runtime：

- 短操作：`runtime().block_on(...)`，由调用方在后台线程执行。
- 长操作：`start_copy` 立即返回 id，拷贝在 runtime 中运行，UI 轮询 `transfer_snapshot` / `transfers`。

## 理由

- 调用方明确知道「这是阻塞调用，要在 IO 调度器上跑」，不存在隐式的 runtime 依赖。
- 轮询模型天然适配「App 被切后台/进程重启」：状态在 Rust 侧，UI 重连即可。
- 取消是显式 API，不依赖 task cancellation 传播。
- 避免了 UniFFI async 在不同语言/不同 runtime 版本上的坑。

## 代价

- UI 需要自己写一个轮询循环（Swift `Task` + `Task.sleep`，Kotlin `Flow` + `delay`）。
- 无法用结构化并发自动传播取消。

## 演进

如果 M2 后轮询开销成为问题，可以增加「进度回调」版本（`with_foreign` trait），但保留轮询作为兜底。
