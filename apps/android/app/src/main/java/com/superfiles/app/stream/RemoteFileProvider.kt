package com.superfiles.app.stream

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Handler
import android.os.ParcelFileDescriptor
import android.os.ProxyFileDescriptorCallback
import android.os.storage.StorageManager
import android.webkit.MimeTypeMap
import com.superfiles.core.EntryKind
import com.superfiles.core.SuperFiles
import java.io.File
import java.io.FileNotFoundException
import java.net.URLDecoder
import java.net.URLEncoder

/**
 * 远端文件流式 Provider：外部应用经 `content://…/open?path=<id>` 打开文件时，
 * 用 [StorageManager.openProxyFileDescriptor] + 内核 `readBytes` 按偏移**按需读**
 * （PDF 翻页 / 视频 seek 都是 Range 读取），不整包下载、不占缓存。
 */
class RemoteFileProvider : ContentProvider() {

    companion object {
        /** 供 VfsViewModel 注册内核实例（远端挂载都在 appCore 上）。 */
        @Volatile
        var appCore: SuperFiles? = null

        fun uriFor(id: String): Uri = Uri.parse("content://com.superfiles.app.stream/open")
            .buildUpon()
            .appendQueryParameter("path", URLEncoder.encode(id, "UTF-8"))
            .build()

        /**
         * 代理 fd 回调的专用线程：onRead 里是阻塞式内核调用（SMB/WebDAV 网络往返），
         * 绝不能跑主线程（播放期间会把整个 App 卡死、慢网可触发 ANR）。
         */
        private val ioThread by lazy {
            android.os.HandlerThread("remote-fd-io").apply { start() }
        }
        private val ioHandler by lazy { Handler(ioThread.looper) }
    }

    override fun onCreate(): Boolean {
        // Provider 可能冷启动（外部应用直接拉起），事件日志也要可用
        com.superfiles.app.SfLog.init(context!!)
        return true
    }

    private fun idOf(uri: Uri): String =
        URLDecoder.decode(uri.getQueryParameter("path") ?: "", "UTF-8")

    private fun entryOf(id: String) = appCore?.stat(id)

    override fun getType(uri: Uri): String? {
        val id = idOf(uri)
        entryOf(id)?.mime?.let { return it }
        val ext = id.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "*/*"
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        val id = idOf(uri)
        val core = appCore ?: throw FileNotFoundException("core not ready").also {
            com.superfiles.app.SfLog.e("provider open denied: core not ready, id=$id")
        }
        val entry = try {
            core.stat(id)
        } catch (e: Exception) {
            com.superfiles.app.SfLog.e("provider stat failed: $id", e)
            throw FileNotFoundException("$id: ${e.message}")
        }
        if (entry.kind != EntryKind.FILE) {
            com.superfiles.app.SfLog.e("provider open denied: not a file, id=$id kind=${entry.kind}")
            throw FileNotFoundException(id)
        }

        // 本地绝对路径条目：直接给真实 fd（无需代理）
        if (id.startsWith("/")) {
            return ParcelFileDescriptor.open(File(id), ParcelFileDescriptor.MODE_READ_ONLY)
        }

        com.superfiles.app.SfLog.i("provider open: $id size=${entry.size} backend=${id.substringBefore("://")}")
        // 远端条目：代理 fd，读请求按偏移转发给内核（readBytes / 分块 Range）
        val storage = context!!.getSystemService(Context.STORAGE_SERVICE) as StorageManager
        val totalSize = entry.size.toLong()
        return storage.openProxyFileDescriptor(
            ParcelFileDescriptor.MODE_READ_ONLY,
            object : ProxyFileDescriptorCallback() {
                // 读失败只记一次（播放器在坏文件上会疯狂重试同一偏移，防日志刷屏）
                var failureLogged = false

                // ---- 会话级统计（onRelease 时汇总一行，供播放质量分析） ----
                private val openedAt = android.os.SystemClock.elapsedRealtime()
                private var readCount = 0L
                private var bytesRead = 0L
                private var readMsTotal = 0L
                private var readMsMax = 0L
                private var firstReadMs = -1L
                /** >500ms 的慢读次数：播放卡顿/预读不足的量化指标。 */
                private var slowReads = 0L
                private var minOffsetSeen = Long.MAX_VALUE
                private var maxOffsetSeen = 0L

                override fun onGetSize(): Long = totalSize

                override fun onRead(offset: Long, size: Int, data: ByteArray): Int {
                    if (offset >= totalSize) return 0
                    val want = minOf(size.toLong(), totalSize - offset).toInt()
                    if (want <= 0) return 0
                    val startedAt = android.os.SystemClock.elapsedRealtime()
                    val chunk = try {
                        core.readBytes(id, offset.toULong(), want.toUInt())
                    } catch (e: Exception) {
                        if (!failureLogged) {
                            failureLogged = true
                            com.superfiles.app.SfLog.e(
                                "provider read failed: $id offset=$offset want=$want",
                                e,
                            )
                        }
                        return 0 // 伪 EOF：播放器据此报「播放失败」，真实原因在事件日志里
                    }
                    val latency = android.os.SystemClock.elapsedRealtime() - startedAt
                    readCount++
                    readMsTotal += latency
                    if (latency > readMsMax) readMsMax = latency
                    if (latency > 500) slowReads++
                    if (firstReadMs < 0) firstReadMs = latency
                    if (offset < minOffsetSeen) minOffsetSeen = offset
                    if (offset + chunk.size > maxOffsetSeen) maxOffsetSeen = offset + chunk.size
                    if (chunk.isEmpty()) {
                        if (!failureLogged) {
                            failureLogged = true
                            com.superfiles.app.SfLog.e(
                                "provider read empty: $id offset=$offset want=$want size=$totalSize",
                            )
                        }
                        return 0
                    }
                    bytesRead += chunk.size
                    System.arraycopy(chunk, 0, data, 0, chunk.size)
                    return chunk.size
                }

                override fun onRelease() {
                    // 播放器关闭：删除 WebDAV 边播边缓存的临时文件
                    runCatching { appCore?.releaseStream(id) }
                        .onFailure { com.superfiles.app.SfLog.e("provider release cache failed: $id", it) }
                    if (readCount == 0L) {
                        com.superfiles.app.SfLog.i("provider session: $id（未发生读取即关闭）")
                        return
                    }
                    val wall = android.os.SystemClock.elapsedRealtime() - openedAt
                    // 单行结构化摘要，便于 grep 分析：
                    // provider-session id=… size=… reads=… mb=… wall_s=… first_ms=… avg_ms=… max_ms=… slow500=… span=…
                    com.superfiles.app.SfLog.i(
                        "provider session: $id" +
                            " size=$totalSize reads=$readCount" +
                            " mb=${"%.1f".format(bytesRead / 1048576.0)}" +
                            " wall_s=${"%.1f".format(wall / 1000.0)}" +
                            " first_ms=$firstReadMs avg_ms=${readMsTotal / readCount}" +
                            " max_ms=$readMsMax slow500=$slowReads" +
                            " span=${minOffsetSeen}-${maxOffsetSeen}",
                    )
                }
            },
            ioHandler,
        )
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException()

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = throw UnsupportedOperationException()

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int =
        throw UnsupportedOperationException()
}
