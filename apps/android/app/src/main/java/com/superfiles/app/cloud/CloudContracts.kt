package com.superfiles.app.cloud

import com.superfiles.app.BuildConfig
import com.superfiles.app.R

import android.net.Uri
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * 云盘接入框架的契约层。Google Drive 已接通：
 * Web 类型 OAuth 客户端 + loopback 回调（`http://localhost:8765/`）。
 *
 * 接入一家新云盘需要三件事：
 * 1. 在 [CloudProviders] 注册 OAuth 端点 + 开放平台 client 凭据（或 API Key 方案）；
 * 2. Rust 侧在 vfs-core 新增 `Backend` 实现（文件 ID 语义、分页列表、临时直链下载/分片上传），
 *    通过 FFI `mount_cloud(providerId, accessToken, ...)` 挂载；
 * 3. UI 侧在「添加云存储 → 授权 → 选盘」流程里调用 [CloudAuthManager]。
 *
 * 认证状态与令牌生命周期全部由 [CloudAuthManager] 统一管理，provider 只提供数据。
 */

/** 授权方式：浏览器回调 vs 设备码（115 扫码）。 */
enum class AuthMode { REDIRECT, DEVICE }

/** OAuth2 端点。`authorizationUrl` 走系统浏览器，`tokenUrl` 走后台表单 POST。 */
data class OAuthEndpoints(
    val authorizationUrl: String,
    val tokenUrl: String,
)

/** 开放平台应用凭据；null 表示尚未在开发者平台注册（UI 显示"未配置"）。 */
data class OAuthClient(
    val clientId: String,
    val clientSecret: String? = null,
    /** 是否需要 PKCE（公共客户端必选；后端型可用 secret + code）。 */
    val usePkce: Boolean = true,
)

/** 一个云盘 provider 的静态定义（不持有运行时状态）。 */
data class CloudProvider(
    val id: String,
    @androidx.annotation.StringRes val displayNameRes: Int,
    val endpoints: OAuthEndpoints,
    val client: OAuthClient? = null,
    val scopes: List<String> = emptyList(),
    val extraAuthParams: Map<String, String> = emptyMap(),
    /** 非标准 token 响应的解析钩子；null 用通用 OAuth2 JSON 解析。 */
    val tokenParser: ((String) -> TokenSet?)? = null,
    /**
     * 回调地址。默认走深链 `superfiles://oauth/callback`；
     * Google 的 Web 客户端不接受自定义 scheme，必须用 loopback
     * （`http://localhost:8765/`，app 内起本地服务接收）。
     */
    val redirectUri: String = CloudAuthBus.REDIRECT_URI,
    /** 设备码模式（115）：不需要 redirect_uri。 */
    val authMode: AuthMode = AuthMode.REDIRECT,
    val deviceCodeUrl: String? = null,
    val qrStatusUrl: String? = null,
) {
    val configured: Boolean get() = client != null && client.clientId.isNotEmpty()
}

/** 存取令牌（已加密落盘，运行时反序列化为此结构）。 */
data class TokenSet(
    val accessToken: String,
    val refreshToken: String?,
    val expiresAtMs: Long,
    /** 原始响应用作各家扩展字段（uid、domain_id、drive_id 等）。 */
    val raw: String,
)

/** 待完成的授权会话（跨浏览器往返；进程被杀也可恢复）。 */
data class PendingAuth(
    val providerId: String,
    val codeVerifier: String,
    val state: String,
    val createdAtMs: Long,
)

/**
 * Provider 注册表。**示例占位**：端点保留，client 为 null（未配置）。
 * 上线某家时：填入开放平台审核通过的 clientId/secret 即可走通整条授权链路。
 */
object CloudProviders {
    val all: List<CloudProvider> = listOf(
        CloudProvider(
            id = "baidu",
            displayNameRes = R.string.s_77ee718b3d,
            endpoints = OAuthEndpoints(
                authorizationUrl = "https://openapi.baidu.com/oauth/2.0/authorize",
                tokenUrl = "https://openapi.baidu.com/oauth/2.0/token",
            ),
            scopes = listOf("basic", "netdisk"),
            client = null, // TODO: 填入开放平台 clientId
        ),
        CloudProvider(
            id = "aliyun",
            displayNameRes = R.string.s_b8e377f410,
            endpoints = OAuthEndpoints(
                authorizationUrl = "https://openapi.alipan.com/oauth/authorize",
                tokenUrl = "https://openapi.alipan.com/oauth/access_token",
            ),
            scopes = listOf("user:base", "file:all:read", "file:all:write"),
            client = null, // TODO: 填入开放平台 clientId/secret
        ),
        CloudProvider(
            id = "pan123",
            displayNameRes = R.string.s_ec82eb15e1,
            endpoints = OAuthEndpoints(
                authorizationUrl = "https://open-api.123pan.com/oauth2/authorize",
                tokenUrl = "https://open-api.123pan.com/oauth2/token",
            ),
            client = null, // TODO: 填入开放平台 clientId/secret
        ),
        CloudProvider(
            id = "google_drive",
            displayNameRes = R.string.s_google_drive,
            endpoints = OAuthEndpoints(
                authorizationUrl = "https://accounts.google.com/o/oauth2/v2/auth",
                tokenUrl = "https://oauth2.googleapis.com/token",
            ),
            scopes = listOf("https://www.googleapis.com/auth/drive"),
            client = OAuthClient(
                clientId = BuildConfig.GOOGLE_CLIENT_ID,
                clientSecret = BuildConfig.GOOGLE_CLIENT_SECRET,
                usePkce = true,
            ),
            // Google 的 Web 客户端不接受自定义 scheme，只能走 loopback。
            redirectUri = "http://localhost:8765/",
            // offline + consent：确保每次都能拿到 refresh_token
            extraAuthParams = mapOf(
                "access_type" to "offline",
                "prompt" to "consent",
            ),
        ),
        CloudProvider(
            id = "dropbox",
            displayNameRes = R.string.s_dropbox,
            endpoints = OAuthEndpoints(
                authorizationUrl = "https://www.dropbox.com/oauth2/authorize",
                tokenUrl = "https://api.dropboxapi.com/oauth2/token",
            ),
            scopes = listOf(
                "files.metadata.read",
                "files.metadata.write",
                "files.content.read",
                "files.content.write",
            ),
            // 公共客户端：走 PKCE，不带 secret（Console 里要开 Allow public clients）
            client = OAuthClient(
                clientId = BuildConfig.DROPBOX_CLIENT_ID,
                clientSecret = null,
                usePkce = true,
            ),
            // Dropbox 后台注册的是 127.0.0.1（不是 localhost），必须精确匹配
            redirectUri = "http://127.0.0.1:8765/",
            // 不传这个只会拿到 4 小时的 access_token，没有 refresh_token
            extraAuthParams = mapOf("token_access_type" to "offline"),
        ),

        CloudProvider(
            id = "pan115",
            displayNameRes = R.string.s_115,
            endpoints = OAuthEndpoints(
                authorizationUrl = "",
                tokenUrl = "https://passportapi.115.com/open/deviceCodeToToken",
            ),
            // 设备码 + PKCE：无 redirect、无 client_secret
            client = OAuthClient(
                clientId = BuildConfig.PAN115_CLIENT_ID,
                clientSecret = null,
                usePkce = true,
            ),
            authMode = AuthMode.DEVICE,
            deviceCodeUrl = "https://passportapi.115.com/open/authDeviceCode",
            qrStatusUrl = "https://qrcodeapi.115.com/get/status/",
        ),
        CloudProvider(
            id = "onedrive",
            displayNameRes = R.string.s_onedrive,
            endpoints = OAuthEndpoints(
                authorizationUrl = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
                tokenUrl = "https://login.microsoftonline.com/common/oauth2/v2.0/token",
            ),
            scopes = listOf("offline_access", "Files.ReadWrite.All"),
            // Microsoft 公共客户端：PKCE，不带 secret（Entra 里要开
            // Authentication → Allow public client flows）
            client = OAuthClient(
                clientId = BuildConfig.ONEDRIVE_CLIENT_ID,
                clientSecret = null,
                usePkce = true,
            ),
            // Entra 的 localhost 回调忽略端口，但仍要按注册值精确发送
            redirectUri = "http://localhost:8765/",
            extraAuthParams = mapOf("response_mode" to "query"),
        ),
    )

    fun byId(id: String): CloudProvider? = all.firstOrNull { it.id == id }
}

/** OAuth 回调专用深链总线：MainActivity 收到 `superfiles://oauth/callback` 后投递。 */
object CloudAuthBus {
    const val REDIRECT_URI = "superfiles://oauth/callback"
    val deepLink = MutableStateFlow<Uri?>(null)

    /** 授权完成（token 已加密保存）：值为 providerId，供 VfsViewModel 触发挂载。 */
    val authDone = MutableStateFlow<String?>(null)

    /** 授权失败信息（loopback 回调里抛出的错误），供 UI 提示后清空。 */
    val authError = MutableStateFlow<String?>(null)

    fun deliver(uri: Uri?) {
        deepLink.value = uri
    }

    fun notifyAuthed(providerId: String) {
        authDone.value = providerId
    }
}
