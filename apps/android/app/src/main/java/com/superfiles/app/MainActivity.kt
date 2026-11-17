package com.superfiles.app

import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import com.superfiles.app.ui.AppRoot
import com.superfiles.app.ui.SuperFilesTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // 边到边：状态栏透明 + 对比度自动（深色下不再留白条）
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        handleOAuthIntent(intent)
        handleShareIntent(intent)
        handleLocalSendIntent(intent)
        requestNotificationPermission()
        setContent {
            SuperFilesTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background,
                ) {
                    AppRoot()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleOAuthIntent(intent)
        handleShareIntent(intent)
        handleLocalSendIntent(intent)
    }

    /** Android 分享面板「发送到 superfiles」：交给 AppRoot 先选目标目录。 */
    private fun handleShareIntent(intent: Intent?) {
        val uris = intent?.let(ShareIntake::urisFrom).orEmpty()
        if (uris.isNotEmpty()) ShareIntakeBus.offer(uris)
    }

    /** M1 传输前台服务的通知栏进度需要 POST_NOTIFICATIONS（API 33+ 运行时权限）。 */
    private fun requestNotificationPermission() {
        if (android.os.Build.VERSION.SDK_INT < 33) return
        if (androidx.core.content.ContextCompat.checkSelfPermission(
                this,
                android.Manifest.permission.POST_NOTIFICATIONS,
            ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        androidx.core.app.ActivityCompat.requestPermissions(
            this,
            arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
            REQ_POST_NOTIFICATIONS,
        )
    }

    private companion object {
        const val REQ_POST_NOTIFICATIONS = 1001
    }

    /** `superfiles://localsend` 组网深链：注册对端（扫码行同一总线）。 */
    private fun handleLocalSendIntent(intent: Intent?) {
        val data = intent?.data ?: return
        if (data.scheme != "superfiles" || data.host != "localsend") return
        com.superfiles.app.LocalSendLinkBus.deliver(data.toString())
    }

    /** `superfiles://oauth/callback` 深链：交给云盘授权框架完成 token 交换。 */
    private fun handleOAuthIntent(intent: Intent?) {
        val data = intent?.data ?: return
        if (data.scheme != "superfiles" || data.host != "oauth") return
        com.superfiles.app.cloud.CloudAuthBus.deliver(data)
        lifecycleScope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    com.superfiles.app.cloud.CloudAuthManager.handleDeepLink(this@MainActivity, data)
                }
            }
            result
                .getOrNull()
                ?.onSuccess { provider ->
                    // 授权成功：token 已加密保存，通知 ViewModel 完成挂载
                    com.superfiles.app.cloud.CloudAuthBus.notifyAuthed(provider.id)
                    Toast.makeText(
                        this@MainActivity,
                        L10n.t(R.string.s_3de0ece3dc, (L10n.t(provider.displayNameRes))),
                        Toast.LENGTH_LONG,
                    ).show()
                }
                ?.onFailure { e ->
                    Toast.makeText(this@MainActivity, L10n.t(R.string.s_7e6b3848b4, (e.message)), Toast.LENGTH_LONG).show()
                }
        }
    }
}
