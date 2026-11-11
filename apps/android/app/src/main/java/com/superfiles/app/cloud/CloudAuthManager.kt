package com.superfiles.app.cloud

import com.superfiles.app.L10n
import com.superfiles.app.R

import android.content.Context
import android.content.Intent
import android.net.Uri
import com.superfiles.app.security.KeystoreCrypto
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import org.json.JSONObject

/**
 * OAuth2（PKCE）授权框架：授权跳转 → 深链回调 → code/refresh_token 交换 → 加密存取 → 自动刷新。
 * 与具体云盘无关；provider 差异全部收敛到 [CloudProvider] 配置与可选的 tokenParser。
 *
 * 使用方式（未来接入云盘时）：
 * ```
 * val provider = CloudProviders.byId("aliyun")!!   // 已配置 client
 * CloudAuthManager.startAuth(context, provider)     // 打开授权页
 * // ...用户授权后回到 App，MainActivity 把深链交给 handleDeepLink()
 * val result = CloudAuthManager.handleDeepLink(context, uri)  // 成功即持有 token
 * // Rust 后端就绪后：core.mountCloud("aliyun", token.accessToken, raw.domainId/driveId...)
 * ```
 */
object CloudAuthManager {

    private const val PREF = "cloud_oauth"
    private const val KEY_PENDING = "pending_auth"
    private const val TIMEOUT_MS = 15_000

    // ---------- 授权入口 ----------

    /** 生成 PKCE 挑战并跳转系统浏览器。provider 未配置凭据时返回 false。 */
    fun startAuth(context: Context, provider: CloudProvider): Boolean {
        val client = provider.client ?: return false
        val verifier = randomUrlSafe(48)
        val challenge = sha256B64Url(verifier)
        val state = randomUrlSafe(16)
        savePending(
            context,
            PendingAuth(provider.id, verifier, state, System.currentTimeMillis()),
        )
        val url = buildString {
            append(provider.endpoints.authorizationUrl)
            append("?response_type=code")
            append("&client_id=").append(Uri.encode(client.clientId))
            append("&redirect_uri=").append(Uri.encode(CloudAuthBus.REDIRECT_URI))
            append("&state=").append(Uri.encode(state))
            if (provider.scopes.isNotEmpty()) {
                append("&scope=").append(Uri.encode(provider.scopes.joinToString(" ")))
            }
            if (client.usePkce) {
                append("&code_challenge=").append(Uri.encode(challenge))
                append("&code_challenge_method=S256")
            }
            provider.extraAuthParams.forEach { (k, v) ->
                append("&").append(Uri.encode(k)).append("=").append(Uri.encode(v))
            }
        }
        context.startActivity(
            Intent(Intent.ACTION_VIEW, Uri.parse(url))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        return true
    }

    /**
     * 处理 `superfiles://oauth/callback?code=..&state=..`：
     * 校验 state → 用 PKCE verifier 换 token → 加密保存 → 返回 provider。
     */
    fun handleDeepLink(context: Context, uri: Uri): Result<CloudProvider> {
        val providerId = loadPending(context)?.providerId
        val provider = providerId?.let { CloudProviders.byId(it) }
            ?: return Result.failure(IllegalStateException(L10n.t(R.string.s_b9fca1d0d8)))
        val error = uri.getQueryParameter("error")
        if (error != null) {
            clearPending(context)
            return Result.failure(
                IllegalStateException(L10n.t(R.string.s_a4f1acc1ff, (error), (uri.getQueryParameter("error_description") ?: ""))),
            )
        }
        val code = uri.getQueryParameter("code")
            ?: return Result.failure(IllegalArgumentException(L10n.t(R.string.s_5b1e9bbca7)))
        return runCatching {
            val token = exchange(context, provider, code)
            saveToken(context, provider.id, token)
            clearPending(context)
            provider
        }
    }

    // ---------- token 交换 / 刷新 ----------

    private fun exchange(context: Context, provider: CloudProvider, code: String): TokenSet {
        val client = provider.client ?: error(L10n.t(R.string.s_e8a53f8e1a))
        val pending = loadPending(context) ?: error(L10n.t(R.string.s_fceb5577cd))
        val form = linkedMapOf(
            "grant_type" to "authorization_code",
            "code" to code,
            "redirect_uri" to CloudAuthBus.REDIRECT_URI,
            "client_id" to client.clientId,
        )
        if (client.usePkce) form["code_verifier"] = pending.codeVerifier
        client.clientSecret?.let { form["client_secret"] = it }
        return parseToken(provider, postForm(provider.endpoints.tokenUrl, form))
    }

    /** 刷新 access_token（未来后台任务/请求失败重试时调用）。 */
    fun refresh(context: Context, provider: CloudProvider): TokenSet? {
        val current = loadToken(context, provider.id) ?: return null
        val refresh = current.refreshToken ?: return null
        val client = provider.client ?: return null
        val form = linkedMapOf(
            "grant_type" to "refresh_token",
            "refresh_token" to refresh,
            "client_id" to client.clientId,
        )
        client.clientSecret?.let { form["client_secret"] = it }
        return runCatching {
            val token = parseToken(provider, postForm(provider.endpoints.tokenUrl, form))
            saveToken(context, provider.id, token)
            token
        }.getOrNull()
    }

    // ---------- token 存取（Keystore 加密） ----------

    fun saveToken(context: Context, providerId: String, token: TokenSet) {
        val json = JSONObject().apply {
            put("access", token.accessToken)
            put("refresh", token.refreshToken)
            put("expires", token.expiresAtMs)
            put("raw", token.raw)
        }
        prefs(context).edit()
            .putString("token_$providerId", KeystoreCrypto.encrypt(json.toString()))
            .apply()
    }

    fun loadToken(context: Context, providerId: String): TokenSet? = runCatching {
        val enc = prefs(context).getString("token_$providerId", null) ?: return null
        val json = JSONObject(KeystoreCrypto.decrypt(enc) ?: return null)
        TokenSet(
            accessToken = json.getString("access"),
            refreshToken = json.optString("refresh").takeIf { it.isNotEmpty() && it != "null" },
            expiresAtMs = json.optLong("expires"),
            raw = json.optString("raw"),
        )
    }.getOrNull()

    fun logout(context: Context, providerId: String) {
        prefs(context).edit().remove("token_$providerId").remove(KEY_PENDING).apply()
    }

    fun hasToken(context: Context, providerId: String): Boolean =
        loadToken(context, providerId) != null

    // ---------- 内部 ----------

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREF, Context.MODE_PRIVATE)

    private fun savePending(context: Context, pending: PendingAuth) {
        val json = JSONObject().apply {
            put("provider", pending.providerId)
            put("verifier", pending.codeVerifier)
            put("state", pending.state)
            put("created", pending.createdAtMs)
        }
        prefs(context).edit()
            .putString(KEY_PENDING, KeystoreCrypto.encrypt(json.toString()))
            .apply()
    }

    private fun loadPending(context: Context): PendingAuth? = runCatching {
        val enc = prefs(context).getString(KEY_PENDING, null) ?: return null
        val json = JSONObject(KeystoreCrypto.decrypt(enc) ?: return null)
        // 30 分钟有效期，避免僵尸会话
        if (System.currentTimeMillis() - json.optLong("created") > 30 * 60 * 1000L) {
            clearPending(context)
            return null
        }
        PendingAuth(
            providerId = json.getString("provider"),
            codeVerifier = json.getString("verifier"),
            state = json.getString("state"),
            createdAtMs = json.optLong("created"),
        )
    }.getOrNull()

    private fun clearPending(context: Context) {
        prefs(context).edit().remove(KEY_PENDING).apply()
    }

    private fun parseToken(provider: CloudProvider, body: String): TokenSet {
        provider.tokenParser?.invoke(body)?.let { return it }
        val json = JSONObject(body)
        val error = json.optString("error").takeIf { it.isNotEmpty() }
        if (error != null) {
            throw IllegalStateException("$error: ${json.optString("error_description")}")
        }
        val access = json.optString("access_token")
        if (access.isEmpty()) throw IllegalStateException(L10n.t(R.string.s_f452c3146f))
        val expiresIn = json.optLong("expires_in", 0)
        return TokenSet(
            accessToken = access,
            refreshToken = json.optString("refresh_token").takeIf { it.isNotEmpty() },
            expiresAtMs = if (expiresIn > 0) System.currentTimeMillis() + expiresIn * 1000 else 0,
            raw = body,
        )
    }

    private fun postForm(url: String, form: Map<String, String>): String {
        val body = form.entries.joinToString("&") { (k, v) ->
            "${Uri.encode(k)}=${Uri.encode(v)}"
        }
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            connectTimeout = TIMEOUT_MS
            readTimeout = TIMEOUT_MS
            doOutput = true
            setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
            setRequestProperty("Accept", "application/json")
        }
        return try {
            conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            val text = (if (conn.responseCode in 200..299) conn.inputStream else conn.errorStream)
                ?.bufferedReader()?.use { it.readText() }.orEmpty()
            if (conn.responseCode !in 200..299) {
                throw IllegalStateException(L10n.t(R.string.s_cb70a134ab, (conn.responseCode), (text)))
            }
            text
        } finally {
            conn.disconnect()
        }
    }

    private fun randomUrlSafe(bytes: Int): String {
        val buf = ByteArray(bytes)
        SecureRandom().nextBytes(buf)
        return Base64.getUrlEncoder().withoutPadding().encodeToString(buf)
    }

    private fun sha256B64Url(input: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(input.toByteArray(Charsets.US_ASCII))
        return Base64.getUrlEncoder().withoutPadding().encodeToString(digest)
    }
}
