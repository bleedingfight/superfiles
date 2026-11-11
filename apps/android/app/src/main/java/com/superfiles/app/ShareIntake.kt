package com.superfiles.app

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import com.superfiles.core.SuperFiles
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext
import java.io.File
import java.io.InputStream

/**
 * Files shared from other apps via `ACTION_SEND` / `ACTION_SEND_MULTIPLE`.
 *
 * Android only lists an app in the share sheet when its manifest declares these
 * actions (see AndroidManifest.xml). We do NOT copy immediately: the user picks
 * a destination in the app first, then [importToVfs] streams the content URIs
 * into that VFS directory.
 */
object ShareIntake {
    fun urisFrom(intent: Intent): List<Uri> = when (intent.action) {
        Intent.ACTION_SEND -> {
            @Suppress("DEPRECATION")
            val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
            listOfNotNull(uri)
        }
        Intent.ACTION_SEND_MULTIPLE -> {
            @Suppress("DEPRECATION")
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
        }
        else -> emptyList()
    }

    suspend fun importToVfs(
        context: Context,
        core: SuperFiles,
        uris: List<Uri>,
        destId: String,
        onProgress: (done: Int, total: Int) -> Unit = { _, _ -> },
    ): Int = withContext(Dispatchers.IO) {
        var saved = 0
        uris.forEachIndexed { index, uri ->
            val name = uniqueName(core, destId, safeName(displayName(context, uri)))
            val ok = runCatching {
                val entry = core.createFile(destId, name)
                try {
                    inputStream(context, uri)?.use { input ->
                        val buffer = ByteArray(256 * 1024)
                        var offset = 0uL
                        while (true) {
                            val n = input.read(buffer)
                            if (n <= 0) break
                            core.writeBytes(entry.id, offset, buffer.copyOf(n))
                            offset += n.toULong()
                        }
                    } ?: error("stream unavailable")
                } catch (t: Throwable) {
                    // Never leave a truncated file behind.
                    runCatching { core.remove(entry.id, false) }
                    throw t
                }
            }.isSuccess
            if (ok) saved++
            onProgress(index + 1, uris.size)
        }
        saved
    }

    private fun inputStream(context: Context, uri: Uri): InputStream? =
        if (uri.scheme == "file") {
            uri.path?.let { File(it).inputStream() }
        } else {
            context.contentResolver.openInputStream(uri)
        }

    private fun displayName(context: Context, uri: Uri): String {
        if (uri.scheme == "file") {
            return uri.lastPathSegment?.substringAfterLast('/') ?: "shared"
        }
        runCatching {
            context.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (index >= 0) {
                        val value = cursor.getString(index)
                        if (!value.isNullOrBlank()) return value
                    }
                }
            }
        }
        return uri.lastPathSegment?.substringAfterLast('/')?.takeIf { it.isNotBlank() } ?: "shared"
    }

    private fun safeName(raw: String): String {
        val cleaned = raw
            .replace(Regex("""[\\/:*?"<>|\p{Cntrl}]"""), "_")
            .trim()
            .trim('.')
            .take(160)
        return cleaned.ifBlank { "shared" }
    }

    private fun uniqueName(core: SuperFiles, destId: String, name: String): String {
        var candidate = name
        var index = 0
        while (index < 1000) {
            val id = core.join(destId, candidate)
            val exists = runCatching { core.stat(id) }.isSuccess
            if (!exists) return candidate
            index++
            val stem = name.substringBeforeLast('.', name)
            val ext = name.substringAfterLast('.', "").let { if (it.isEmpty()) "" else ".$it" }
            candidate = "$stem ($index)$ext"
        }
        return "${System.currentTimeMillis()}-$name"
    }
}

/**
 * In-memory hand-off from MainActivity's share intent to AppRoot's destination
 * picker. The Activity owns the URI read grant for as long as it is alive.
 */
object ShareIntakeBus {
    private val _pending = MutableStateFlow<List<Uri>>(emptyList())
    val pending: StateFlow<List<Uri>> = _pending

    fun offer(uris: List<Uri>) {
        if (uris.isNotEmpty()) _pending.value = uris
    }

    fun consume() {
        _pending.value = emptyList()
    }
}
