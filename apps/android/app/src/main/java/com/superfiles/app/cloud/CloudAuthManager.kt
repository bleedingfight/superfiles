package com.superfiles.app.cloud

import com.superfiles.app.L10n
import com.superfiles.app.R
import com.superfiles.app.SfLog

import android.content.Context
import android.content.Intent
import android.net.Uri
import com.superfiles.app.security.KeystoreCrypto
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.URL
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import org.json.JSONObject

/**
 * OAuth2（PKCE）授权框架：授权跳转 → 深链回调 → code/refresh_token 交换 → 加密存取 → 自动刷新。
 * 与具体云盘无关；provider 差异全部收敛到 [CloudProvider] 配置与可选的 tokenParser。
 *
 * 使用方式：
 * ```
 * val provider = CloudProviders.byId("google_drive")!!   // 已配置 client
 * CloudAuthManager.startAuth(context, provider)           // 打开授权页
 * // Google 走 app 内 loopback（127.0.0.1:8765），其余走深链
 * // 成功后 CloudAuthBus.authDone 通知 VfsViewModel 挂载
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
        if (client.clientId.isEmpty()) return false
        if (provider.authMode == AuthMode.DEVICE) {
            startDeviceAuth(context.applicationContext, provider)
            return true
        }
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
            append("&redirect_uri=").append(Uri.encode(provider.redirectUri))
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
        if (isLoopback(provider.redirectUri)) {
            // Google 的 Web 客户端只接受 loopback：app 内起服务收 code。
            startLoopback(context.applicationContext, provider, url, provider.redirectUri)
        } else {
            context.startActivity(
                Intent(Intent.ACTION_VIEW, Uri.parse(url))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
        return true
    }

    // ---------- loopback 回调（Google 等只接受 http://localhost 的客户端） ----------

    private fun isLoopback(redirectUri: String): Boolean =
        redirectUri.startsWith("http://localhost") || redirectUri.startsWith("http://127.0.0.1")

    /**
     * 起一个只接收一次回调的本地 HTTP 服务，然后用系统浏览器打开授权页。
     * 浏览器跳到 `http://localhost:<port>/?code=...` 时直接在这里完成换 token。
     */
    private fun startLoopback(
        context: Context,
        provider: CloudProvider,
        authorizeUrl: String,
        redirectUri: String,
    ) {
        val port = Uri.parse(redirectUri).port.takeIf { it > 0 } ?: 8765
        Thread {
            try {
                ServerSocket().use { server ->
                    server.reuseAddress = true
                    server.bind(InetSocketAddress("127.0.0.1", port))
                    server.soTimeout = 5 * 60 * 1000

                    context.startActivity(
                        Intent(Intent.ACTION_VIEW, Uri.parse(authorizeUrl))
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )

                    val callback = server.accept().use { socket ->
                        val reader = BufferedReader(
                            InputStreamReader(socket.getInputStream(), StandardCharsets.UTF_8),
                        )
                        val requestLine = reader.readLine().orEmpty()
                        while (true) {
                            val line = reader.readLine()
                            if (line.isNullOrEmpty()) break
                        }
                        val target = requestLine.split(' ').getOrNull(1).orEmpty()
                        val body = "<html><body style=\"font-family:-apple-system,sans-serif\">" +
                            "<p>Authorization complete. You can close this page.</p>" +
                            "</body></html>"
                        val bytes = body.toByteArray(StandardCharsets.UTF_8)
                        val head = "HTTP/1.1 200 OK\r\n" +
                            "Content-Type: text/html; charset=utf-8\r\n" +
                            "Content-Length: ${bytes.size}\r\nConnection: close\r\n\r\n"
                        socket.getOutputStream().apply {
                            write(head.toByteArray(StandardCharsets.US_ASCII))
                            write(bytes)
                            flush()
                        }
                        Uri.parse("http://127.0.0.1$target")
                    }
                    finishLoopback(context, provider, callback)
                }
            } catch (e: Exception) {
                SfLog.i("cloud oauth loopback failed: ${e.message}")
                CloudAuthBus.authError.value = e.message ?: "OAuth callback failed"
            }
        }.start()
    }

    private fun finishLoopback(context: Context, provider: CloudProvider, callback: Uri) {
        val error = callback.getQueryParameter("error")
        if (error != null) {
            clearPending(context)
            CloudAuthBus.authError.value =
                "$error ${callback.getQueryParameter("error_description") ?: ""}".trim()
            return
        }
        val pending = loadPending(context)
        if (pending == null || pending.state != callback.getQueryParameter("state")) {
            clearPending(context)
            CloudAuthBus.authError.value = "OAuth state mismatch"
            return
        }
        val code = callback.getQueryParameter("code")
        if (code.isNullOrEmpty()) {
            CloudAuthBus.authError.value = "OAuth callback missing code"
            return
        }
        runCatching {
            val token = exchange(context, provider, code)
            saveToken(context, provider.id, token)
            clearPending(context)
        }.onSuccess {
            CloudAuthBus.notifyAuthed(provider.id)
        }.onFailure {
            SfLog.i("cloud oauth exchange failed: ${it.message}")
            CloudAuthBus.authError.value = it.message ?: "OAuth token exchange failed"
        }
    }

    // ---------- 设备码（115 扫码） ----------

    private fun startDeviceAuth(context: Context, provider: CloudProvider) {
        val client = provider.client ?: return
        val deviceUrl = provider.deviceCodeUrl
        val statusUrl = provider.qrStatusUrl
        if (deviceUrl.isNullOrEmpty() || statusUrl.isNullOrEmpty()) {
            CloudAuthBus.authError.value = "设备码接口未配置"
            return
        }
        Thread {
            try {
                val verifier = randomUrlSafe(48)
                val challenge = sha256B64Url(verifier)
                val body = "client_id=${Uri.encode(client.clientId)}" +
                    "&code_challenge=${Uri.encode(challenge)}" +
                    "&code_challenge_method=sha256"
                val resp = JSONObject(postRaw(deviceUrl, body))
                val data = resp.optJSONObject("data")
                    ?: error(resp.optString("message", "申请设备码失败"))
                val uid = data.getString("uid")
                val time = data.optString("time")
                val sign = data.optString("sign")
                val qrcode = data.getString("qrcode")

                // 115 的 qrcode 一般是 115.com 的深链，浏览器会唤起 115 App 确认
                context.startActivity(
                    Intent(Intent.ACTION_VIEW, Uri.parse(qrcode))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )

                val deadline = System.currentTimeMillis() + 5 * 60 * 1000L
                var confirmed = false
                while (System.currentTimeMillis() < deadline) {
                    val statusText = runCatching {
                        getRaw(
                            "$statusUrl?uid=${Uri.encode(uid)}" +
                                "&time=${Uri.encode(time)}&sign=${Uri.encode(sign)}",
                        )
                    }.getOrNull()
                    if (statusText != null) {
                        val st = JSONObject(statusText)
                        val status = st.optJSONObject("data")?.optInt("status", 0) ?: 0
                        if (status == 2) {
                            confirmed = true
                            break
                        }
                        if (st.optInt("state", 1) == 0) {
                            error(st.optString("message", "二维码已失效"))
                        }
                    }
                    Thread.sleep(2000)
                }
                if (!confirmed) error("等待 115 授权超时")

                val tokenText = postRaw(
                    provider.endpoints.tokenUrl,
                    "uid=${Uri.encode(uid)}&code_verifier=${Uri.encode(verifier)}",
                )
                val tokenJson = JSONObject(tokenText)
                val td = tokenJson.optJSONObject("data")
                    ?: error(tokenJson.optString("message", "换取 token 失败"))
                val access = td.optString("access_token")
                if (access.isEmpty()) error("115 未返回 access_token")
                val expiresIn = td.optLong("expires_in", 0)
                val token = TokenSet(
                    accessToken = access,
                    refreshToken = td.optString("refresh_token").takeIf { it.isNotEmpty() },
                    expiresAtMs = if (expiresIn > 0) {
                        System.currentTimeMillis() + expiresIn * 1000
                    } else {
                        0
                    },
                    raw = td.toString(),
                )
                saveToken(context, provider.id, token)
                CloudAuthBus.notifyAuthed(provider.id)
            } catch (e: Exception) {
                SfLog.i("115 device auth failed: ${e.message}")
                CloudAuthBus.authError.value = e.message ?: "115 授权失败"
            }
        }.start()
    }

    private fun postRaw(url: String, body: String): String {
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            connectTimeout = TIMEOUT_MS
            readTimeout = 30_000
            doOutput = true
            setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
            setRequestProperty("Accept", "application/json")
            setRequestProperty("User-Agent", "115Browser/27.0.0.2")
        }
        return try {
            conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            val text = (if (conn.responseCode in 200..299) conn.inputStream else conn.errorStream)
                ?.bufferedReader()?.use { it.readText() }.orEmpty()
            if (conn.responseCode !in 200..299) {
                throw IllegalStateException("115 HTTP ${conn.responseCode}: $text")
            }
            text
        } finally {
            conn.disconnect()
        }
    }

    private fun getRaw(url: String): String {
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = TIMEOUT_MS
            readTimeout = 20_000
            setRequestProperty("Accept", "application/json")
            setRequestProperty("User-Agent", "115Browser/27.0.0.2")
        }
        return try {
            val text = (if (conn.responseCode in 200..299) conn.inputStream else conn.errorStream)
                ?.bufferedReader()?.use { it.readText() }.orEmpty()
            if (conn.responseCode !in 200..299) {
                throw IllegalStateException("115 HTTP ${conn.responseCode}: $text")
            }
            text
        } finally {
            conn.disconnect()
        }
    }

    /**
     * 处理 `superfiles://oauth/callback?code=..&state=..`：
     * 校验 state → 用 PKCE verifier 换 token → 加密保存 → 返回 provider。
     */
    fun handleDeepLink(context: Context, uri: Uri): Result<CloudProvider> {
        val pending = loadPending(context)
            ?: return Result.failure(IllegalStateException(L10n.t(R.string.s_fceb5577cd)))
        val provider = CloudProviders.byId(pending.providerId)
            ?: return Result.failure(IllegalStateException(L10n.t(R.string.s_b9fca1d0d8)))
        val error = uri.getQueryParameter("error")
        if (error != null) {
            clearPending(context)
            return Result.failure(
                IllegalStateException(L10n.t(R.string.s_a4f1acc1ff, (error), (uri.getQueryParameter("error_description") ?: ""))),
            )
        }
        if (uri.getQueryParameter("state") != pending.state) {
            clearPending(context)
            return Result.failure(IllegalStateException("OAuth state mismatch"))
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
            "redirect_uri" to provider.redirectUri,
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
