package com.superfiles.app

import android.content.Context
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 应用内事件日志：关键路径的错误/操作带上下文落盘成环形文件，随诊断包导出。
 *
 * 为什么需要它：普通应用读 logcat 只能看到自己 UID 的日志，且重启即失、
 * 还依赖我们用对 tag；而真正的排查痛点是「错误被吞」（如流式 Provider 的
 * onRead 失败返回伪 EOF，播放器只报「播放失败」）。这里把错误上下文持久化，
 * 导出诊断包时附带尾部内容，无需任何权限。
 *
 * 每条同时镜像到 logcat（tag=SuperFiles），两条通道同源。
 */
object SfLog {
    private const val TAG = "SuperFiles"
    private const val MAX_FILE_BYTES = 512 * 1024L
    private const val TRIM_KEEP_BYTES = 384 * 1024

    @Volatile
    private var file: File? = null
    private val fmt = SimpleDateFormat("MM-dd HH:mm:ss.SSS", Locale.US)

    /**
     * 落盘放到单线程队列：`write()` 的调用点里有 UI 主线程（打开远端文件、
     * 错误提示等），同步 `appendText` 会在点击/切换时卡住一两帧。
     */
    private val writer = java.util.concurrent.Executors.newSingleThreadExecutor { r ->
        Thread(r, "sfiles-log").apply { isDaemon = true }
    }

    /** 幂等；Provider 冷启动早于 Activity 也能工作。 */
    fun init(context: Context) {
        if (file == null) {
            file = File(context.filesDir, "logs/app-events.log").apply {
                parentFile?.mkdirs()
            }
        }
    }

    fun d(msg: String) = write("D", msg)
    fun i(msg: String) = write("I", msg)
    fun e(msg: String, err: Throwable? = null) =
        write("E", if (err != null) "$msg: ${err.javaClass.simpleName}: ${err.message}" else msg)

    private fun write(level: String, msg: String) {
        when (level) {
            "E" -> Log.e(TAG, msg)
            "I" -> Log.i(TAG, msg)
            else -> Log.d(TAG, msg)
        }
        val f = file ?: return
        writer.execute {
            runCatching {
                f.appendText(fmt.format(Date()) + " " + level + " " + msg + "\n")
                if (f.length() > MAX_FILE_BYTES) {
                    val all = f.readBytes()
                    val keepFrom = all.size - TRIM_KEEP_BYTES
                    // 对齐到下一个换行，避免半行
                    val nl = (keepFrom until all.size).firstOrNull { all[it] == '\n'.code.toByte() }
                    f.writeBytes(all.copyOfRange(if (nl != null) nl + 1 else keepFrom, all.size))
                }
            }
        }
    }

    /** 导出尾部（诊断包用）；未初始化/读取失败返回占位说明而不是抛错。 */
    fun tail(maxBytes: Int = 64 * 1024): String {
        val f = file ?: return "(事件日志未初始化)"
        // 先把队列里排着的行落盘，否则导出看不到最近的错误
        runCatching { writer.submit {}.get(500, java.util.concurrent.TimeUnit.MILLISECONDS) }
        if (!f.exists()) return "(暂无事件日志)"
        return runCatching {
            val all = f.readBytes()
            if (all.size <= maxBytes) return String(all)
            val keepFrom = all.size - maxBytes
            val nl = (keepFrom until all.size).firstOrNull { all[it] == '\n'.code.toByte() }
            val s = if (nl != null) nl + 1 else keepFrom
            "……（截断，仅尾部 ${all.size - s} 字节）\n" + String(all, s, all.size - s)
        }.getOrElse { "(读取事件日志失败: ${it.message})" }
    }
}
