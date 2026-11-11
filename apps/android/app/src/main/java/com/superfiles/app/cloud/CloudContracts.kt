package com.superfiles.app.cloud

import com.superfiles.app.R

import android.net.Uri
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * 云盘接入框架的契约层（当前只搭骨架，未接入任何真实云盘）。
 *
 * 接入一家新云盘需要三件事：
 * 1. 在 [CloudProviders] 注册 OAuth 端点 + 开放平台 client 凭据（或 API Key 方案）；
 * 2. Rust 侧在 vfs-core 新增 `Backend` 实现（文件 ID 语义、分页列表、临时直链下载/分片上传），
 *    通过 FFI `mount_cloud(providerId, accessToken, ...)` 挂载；
 * 3. UI 侧在「添加云存储 → 授权 → 选盘」流程里调用 [CloudAuthManager]。
 *
 * 认证状态与令牌生命周期全部由 [CloudAuthManager] 统一管理，provider 只提供数据。
 */

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
) {
    val configured: Boolean get() = client != null
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
    )

    fun byId(id: String): CloudProvider? = all.firstOrNull { it.id == id }
}

/** OAuth 回调专用深链总线：MainActivity 收到 `superfiles://oauth/callback` 后投递。 */
object CloudAuthBus {
    const val REDIRECT_URI = "superfiles://oauth/callback"
    val deepLink = MutableStateFlow<Uri?>(null)

    fun deliver(uri: Uri?) {
        deepLink.value = uri
    }
}
