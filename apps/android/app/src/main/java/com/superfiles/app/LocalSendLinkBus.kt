package com.superfiles.app

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow

/**
 * `superfiles://localsend` 组网深链总线。
 * 系统深链（扫码相机/浏览器）与 App 内扫码结果共用一个入口，
 * 由 VfsViewModel 消费：解析 → 自动拉起接收服务 → registerAt 注册对端。
 */
object LocalSendLinkBus {
    // replay=1：冷启动时 MainActivity 先于 ViewModel 到达，深链不能丢
    private val _links = MutableSharedFlow<String>(replay = 1, extraBufferCapacity = 8)
    val links = _links.asSharedFlow()

    fun deliver(link: String) {
        _links.tryEmit(link)
    }
}
