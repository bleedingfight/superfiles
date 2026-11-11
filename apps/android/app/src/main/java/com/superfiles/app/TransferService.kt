package com.superfiles.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import com.superfiles.core.TransferSnapshot
import com.superfiles.core.TransferState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/**
 * M1 前台服务（dataSync）：传输进行中保活进程 + 通知栏实时进度。
 *
 * 传输本体在 Rust runtime（本进程）内执行；本服务只负责「进程不被杀 + 进度可见」。
 * 生命周期完全由 [VfsViewModel] 的传输轮询经 [sync] 驱动：
 * 出现活跃任务 → startForegroundService；全部结束（完成/失败/取消）→ stopService。
 */
class TransferService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
        // startForegroundService 后必须在数秒内进入前台态
        startForegroundCompat(buildNotification(snapshots.value, rates.value))
        scope.launch {
            snapshots.collectLatest { list ->
                if (list.none { it.isActive() }) {
                    stopSelf()
                } else {
                    notificationManager().notify(NOTIFICATION_ID, buildNotification(list, rates.value))
                }
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int =
        // 无指令负载：所有状态都经 companion 的 snapshots 流推送
        START_STICKY

    override fun onDestroy() {
        scope.cancel()
        synchronized(gate) { running = false }
        super.onDestroy()
    }

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= 29) {
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            @Suppress("DEPRECATION")
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                L10n.t(R.string.s_cf81956ca1),
                NotificationManager.IMPORTANCE_LOW, // 常驻进度条不应响铃
            ).apply { description = L10n.t(R.string.s_5bfd231b5d) }
            notificationManager().createNotificationChannel(channel)
        }
    }

    private fun notificationManager(): NotificationManager =
        getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun buildNotification(
        list: List<TransferSnapshot>,
        rates: Map<String, Long>,
    ): Notification {
        val active = list.filter { it.isActive() }
        val totalBytes = active.sumOf { it.bytesTotal.toLong() }
        val doneBytes = active.sumOf { it.bytesDone.toLong() }
        val percent = if (totalBytes > 0) {
            ((doneBytes * 100) / totalBytes).toInt().coerceIn(0, 100)
        } else {
            0
        }
        val totalRate = active.sumOf { rates[it.id] ?: 0L }
        val current = active.firstNotNullOfOrNull { it.current }
        val launch = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(L10n.t(R.string.s_1ee2930fb7, (active.size)))
            .setContentText(
                buildString {
                    append("$percent%")
                    if (totalRate > 0) append(" · ${formatSpeed(totalRate)}")
                    current?.let { append(" · $it") }
                },
            )
            .setProgress(100, percent, totalBytes <= 0)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(launch)
            .build()
    }

    /** 速度的人话格式（与列表 formatSize 同口径：KB/MB/GB 一位小数）。 */
    private fun formatSpeed(bytesPerSec: Long): String {
        if (bytesPerSec < 1024) return "$bytesPerSec B/s"
        val units = listOf("KB", "MB", "GB", "TB")
        var value = bytesPerSec.toDouble()
        var index = -1
        while (value >= 1024 && index < units.lastIndex) {
            value /= 1024
            index++
        }
        return String.format(java.util.Locale.US, "%.1f %s/s", value, units[index])
    }

    companion object {
        private const val CHANNEL_ID = "transfers"
        private const val NOTIFICATION_ID = 1001
        private val snapshots = MutableStateFlow<List<TransferSnapshot>>(emptyList())
        private val rates = MutableStateFlow<Map<String, Long>>(emptyMap())
        private val gate = Any()
        private var running = false

        private fun TransferSnapshot.isActive(): Boolean =
            state == TransferState.QUEUED || state == TransferState.RUNNING

        /**
         * 传输轮询的唯一出口（约 0.7s/2.5s 一拍）：有活跃任务时确保服务在场并推送
         * 最新快照 + 速度（通知栏随动）；空闲即退场。
         */
        fun sync(context: Context, list: List<TransferSnapshot>, ratesMap: Map<String, Long>) {
            val active = list.any { it.isActive() }
            snapshots.value = list.filter { it.isActive() }
            rates.value = ratesMap
            val intent = Intent(context, TransferService::class.java)
            synchronized(gate) {
                if (active && !running) {
                    running = true
                    runCatching { context.startForegroundService(intent) }
                        .onFailure { running = false }
                } else if (!active && running) {
                    running = false
                    context.stopService(intent)
                }
            }
        }
    }
}
