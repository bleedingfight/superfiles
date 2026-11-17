package com.superfiles.app.ui

import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.webkit.MimeTypeMap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import com.superfiles.app.L10n
import com.superfiles.app.R
import com.superfiles.app.VfsViewModel
import com.superfiles.app.stream.RemoteFileProvider
import com.superfiles.core.Entry
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

private const val TEXT_LIMIT = 512 * 1024
private const val POS_PREFS = "preview_positions"

private enum class PreviewKind { IMAGE, VIDEO, AUDIO, TEXT, PDF }

private val IMAGE_EXT = setOf("jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "heif")
private val VIDEO_EXT = setOf("mp4", "mkv", "mov", "webm", "m4v", "avi", "ts", "3gp")
private val AUDIO_EXT = setOf("mp3", "flac", "wav", "aac", "m4a", "ogg", "opus", "amr", "ape", "wv", "aiff", "aif", "au", "mid", "midi")
private val TEXT_EXT = setOf(
    "txt", "md", "json", "log", "xml", "yaml", "yml", "csv", "ini", "conf",
    "rs", "kt", "ets", "ts", "js", "py", "sh", "toml", "html", "css",
)

private fun kindOf(entry: Entry): PreviewKind {
    val mime = (entry.mime ?: "").lowercase()
    val ext = entry.name.substringAfterLast('.', "").lowercase()
    return when {
        mime.startsWith("image/") || ext in IMAGE_EXT -> PreviewKind.IMAGE
        mime.startsWith("video/") || ext in VIDEO_EXT -> PreviewKind.VIDEO
        mime.startsWith("audio/") || ext in AUDIO_EXT -> PreviewKind.AUDIO
        mime == "application/pdf" || ext == "pdf" -> PreviewKind.PDF
        else -> PreviewKind.TEXT
    }
}

internal fun isPreviewable(entry: Entry): Boolean {
    val mime = (entry.mime ?: "").lowercase()
    if (mime.startsWith("image/") || mime.startsWith("video/") || mime.startsWith("text/") ||
        mime.startsWith("audio/")
    ) {
        return true
    }
    val ext = entry.name.substringAfterLast('.', "").lowercase()
    return ext in IMAGE_EXT || ext in VIDEO_EXT || ext in AUDIO_EXT || ext in TEXT_EXT || ext == "pdf"
}

/** 本地 → FileProvider，远端 → 内核流式 Provider（支持 Range seek）。 */
private fun uriOf(context: Context, viewModel: VfsViewModel, entry: Entry): Uri? =
    if (viewModel.isLocalEntry(entry)) {
        val file = viewModel.localFileOf(entry) ?: return null
        androidx.core.content.FileProvider.getUriForFile(
            context,
            "${context.packageName}.fileprovider",
            file,
        )
    } else {
        RemoteFileProvider.uriFor(entry.id)
    }

/**
 * 内置预览：图片（双指缩放）/ 视频（断点续播）/ 文本 / PDF。
 * 对齐 HarmonyOS 的 `PreviewView`，远端文件走内核流式 Provider，不落盘。
 */
@Composable
fun PreviewPage(viewModel: VfsViewModel, entry: Entry, onBack: () -> Unit) {
    val context = LocalContext.current
    val kind = remember(entry.id) { kindOf(entry) }
    val uri = remember(entry.id) { uriOf(context, viewModel, entry) }

    Column(modifier = Modifier.fillMaxSize().background(SfColors.Surface)) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = onBack) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = L10n.t(R.string.s_5f411223ca),
                    tint = SfColors.OnSurface,
                )
            }
            Text(
                text = entry.name,
                fontSize = 14.sp,
                color = SfColors.OnSurface,
                modifier = Modifier.weight(1f),
                maxLines = 1,
            )
        }

        if (uri == null) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(L10n.t(R.string.s_df86c859dc), color = SfColors.OnSurfaceVariant)
            }
            return@Column
        }

        when (kind) {
            PreviewKind.IMAGE -> ImagePreview(context, uri)
            PreviewKind.VIDEO -> VideoPreview(context, uri, entry.id, entry.name)
            PreviewKind.AUDIO -> AudioPreview(context, uri, entry.id, entry.name)
            PreviewKind.TEXT -> TextPreview(context, uri)
            PreviewKind.PDF -> PdfPreview(context, uri)
        }
    }
}

// ---------------------------------------------------------------- 图片（缩放）

@Composable
private fun ImagePreview(context: Context, uri: Uri) {
    var bitmap by remember(uri) { mutableStateOf<Bitmap?>(null) }
    var failed by remember(uri) { mutableStateOf(false) }
    var scale by remember(uri) { mutableStateOf(1f) }
    var offset by remember(uri) { mutableStateOf(Offset.Zero) }

    LaunchedEffect(uri) {
        val bmp = withContext(Dispatchers.IO) {
            runCatching {
                context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it) }
            }.getOrNull()
        }
        bitmap = bmp
        failed = bmp == null
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .pointerInput(uri) {
                detectTransformGestures { _, pan, zoom, _ ->
                    val next = (scale * zoom).coerceIn(1f, 5f)
                    scale = next
                    offset = if (next > 1f) offset + pan else Offset.Zero
                }
            }
            .pointerInput(uri) {
                detectTapGestures(onDoubleTap = {
                    if (scale > 1f) {
                        scale = 1f
                        offset = Offset.Zero
                    } else {
                        scale = 2.5f
                    }
                })
            },
        contentAlignment = Alignment.Center,
    ) {
        when {
            bitmap != null -> Image(
                bitmap = bitmap!!.asImageBitmap(),
                contentDescription = null,
                modifier = Modifier
                    .fillMaxSize()
                    .graphicsLayer(
                        scaleX = scale,
                        scaleY = scale,
                        translationX = offset.x,
                        translationY = offset.y,
                    ),
                contentScale = ContentScale.Fit,
            )
            failed -> Text(L10n.t(R.string.s_preview_failed), color = SfColors.OnSurfaceVariant)
            else -> CircularProgressIndicator()
        }
    }
}

// ---------------------------------------------------------------- 视频（断点续播）

private fun posPrefs(context: Context): SharedPreferences =
    context.getSharedPreferences(POS_PREFS, Context.MODE_PRIVATE)

@Composable
private fun VideoPreview(context: Context, uri: Uri, entryId: String, name: String) {
    val codecIssue = remember(uri) { unsupportedCodec(context, uri) }
    var playbackError by remember(uri) { mutableStateOf<String?>(null) }

    if (codecIssue != null || playbackError != null) {
        PlaybackFallback(
            context = context,
            uri = uri,
            name = name,
            detail = codecIssue ?: playbackError ?: "",
        )
        return
    }

    val start = remember(uri) { posPrefs(context).getLong(entryId, 0L) }
    val player = remember(uri) {
        ExoPlayer.Builder(context).build().apply {
            setMediaItem(MediaItem.fromUri(uri))
            if (start in 1..(duration.takeIf { it > 0 } ?: Long.MAX_VALUE)) seekTo(start)
            prepare()
            playWhenReady = true
        }
    }

    DisposableEffect(uri) {
        val prefs = posPrefs(context)
        val listener = object : Player.Listener {
            override fun onIsPlayingChanged(isPlaying: Boolean) {
                if (!isPlaying) prefs.edit().putLong(entryId, player.currentPosition).apply()
            }

            override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
                playbackError = error.errorCodeName
            }
        }
        player.addListener(listener)
        onDispose {
            runCatching { prefs.edit().putLong(entryId, player.currentPosition).apply() }
            player.removeListener(listener)
            player.release()
        }
    }

    LaunchedEffect(uri) {
        while (true) {
            delay(3000)
            runCatching {
                posPrefs(context).edit().putLong(entryId, player.currentPosition).apply()
            }
        }
    }

    AndroidView(
        modifier = Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Color.Black),
        factory = { ctx ->
            PlayerView(ctx).apply {
                this.player = player
                useController = true
                setShowBuffering(PlayerView.SHOW_BUFFERING_WHEN_PLAYING)
            }
        },
    )
}

/** 系统没有对应解码器时返回可读的 mime（如 VC-1 / DTS），否则 null。 */
private fun unsupportedCodec(context: Context, uri: Uri): String? = runCatching {
    val pfd = context.contentResolver.openFileDescriptor(uri, "r") ?: return null
    pfd.use {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(it.fileDescriptor)
            val codecs = MediaCodecList(MediaCodecList.REGULAR_CODECS)
            var videoMime: String? = null
            var audioMime: String? = null
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                val supported = runCatching { codecs.findDecoderForFormat(format) }.getOrNull() != null
                if (supported) continue
                if (mime.startsWith("video/")) {
                    videoMime = mime
                } else if (mime.startsWith("audio/")) {
                    audioMime = mime
                }
            }
            // 视频轨道缺失最致命；只有音频不支持时也一并降级（避免"有画面没声音"）。
            videoMime ?: audioMime
        } finally {
            runCatching { extractor.release() }
        }
    }
}.getOrNull()

@Composable
private fun PlaybackFallback(context: Context, uri: Uri, name: String, detail: String) {
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            text = L10n.t(R.string.s_preview_unsupported),
            fontSize = 15.sp,
            color = SfColors.OnSurface,
        )
        Text(
            text = if (detail.isBlank()) name else "$name\n$detail",
            fontSize = 12.sp,
            color = SfColors.OnSurfaceVariant,
            modifier = Modifier.padding(top = 8.dp),
        )
        androidx.compose.material3.Button(
            onClick = { openExternally(context, uri) },
            modifier = Modifier.padding(top = 20.dp),
        ) {
            Text(L10n.t(R.string.s_preview_open_external))
        }
    }
}

private fun openExternally(context: Context, uri: Uri) {
    val intent = Intent(Intent.ACTION_VIEW)
        .setDataAndType(uri, "*/*")
        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    runCatching {
        context.startActivity(Intent.createChooser(intent, null))
    }
}

// ---------------------------------------------------------------- 音频（系统解码播放，失败自动跳系统/第三方）

@Composable
private fun AudioPreview(context: Context, uri: Uri, entryId: String, name: String) {
    val codecIssue = remember(uri) { unsupportedCodec(context, uri) }
    var playbackError by remember(uri) { mutableStateOf<String?>(null) }

    if (codecIssue != null || playbackError != null) {
        // 系统解码器播不动的格式（如 APE/WV）：自动交给系统/第三方播放器（有默认应用直开，
        // 否则系统自动弹选择器）；此处只留说明卡 + 手动按钮兜底。
        val mime = remember(uri) {
            MimeTypeMap.getSingleton()
                .getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase())
                ?: "audio/*"
        }
        LaunchedEffect(uri) { viewExternally(context, uri, mime) }
        val note = L10n.t(R.string.s_audio_handoff)
        PlaybackFallback(
            context = context,
            uri = uri,
            name = name,
            detail = (codecIssue ?: playbackError).orEmpty().let { if (it.isBlank()) note else "$note\n$it" },
        )
        return
    }

    val start = remember(uri) { posPrefs(context).getLong(entryId, 0L) }
    val player = remember(uri) {
        ExoPlayer.Builder(context).build().apply {
            setMediaItem(MediaItem.fromUri(uri))
            seekTo(start)
            prepare()
            playWhenReady = true
        }
    }
    var playing by remember(uri) { mutableStateOf(true) }
    var positionText by remember(uri) { mutableStateOf("") }

    DisposableEffect(uri) {
        val prefs = posPrefs(context)
        val listener = object : Player.Listener {
            override fun onIsPlayingChanged(isPlaying: Boolean) {
                playing = isPlaying
                if (!isPlaying) prefs.edit().putLong(entryId, player.currentPosition).apply()
            }

            override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
                playbackError = error.errorCodeName
            }
        }
        player.addListener(listener)
        onDispose {
            runCatching { prefs.edit().putLong(entryId, player.currentPosition).apply() }
            player.removeListener(listener)
            player.release()
        }
    }

    LaunchedEffect(uri) {
        while (true) {
            val total = player.duration
            positionText = if (total > 0) "${fmtTime(player.currentPosition)} / ${fmtTime(total)}" else fmtTime(player.currentPosition)
            delay(500)
        }
    }

    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("🎵", fontSize = 56.sp)
        Text(
            text = name,
            fontSize = 15.sp,
            color = SfColors.OnSurface,
            maxLines = 2,
            modifier = Modifier.padding(top = 12.dp),
        )
        if (positionText.isNotEmpty()) {
            Text(
                text = positionText,
                fontSize = 12.sp,
                color = SfColors.OnSurfaceVariant,
                modifier = Modifier.padding(top = 4.dp),
            )
        }
        IconButton(
            onClick = { if (player.isPlaying) player.pause() else player.play() },
            modifier = Modifier.padding(top = 16.dp),
        ) {
            Icon(
                imageVector = if (playing) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                contentDescription = null,
                tint = SfColors.Primary,
            )
        }
    }
}

private fun fmtTime(ms: Long): String {
    val total = ms / 1000
    val h = total / 3600
    val m = (total % 3600) / 60
    val s = total % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
}

/** 直接 ACTION_VIEW 交给外部（优先默认应用，失败再兜一次系统选择器）。 */
private fun viewExternally(context: Context, uri: Uri, mime: String) {
    val intent = Intent(Intent.ACTION_VIEW)
        .setDataAndType(uri, mime)
        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    val ok = runCatching { context.startActivity(intent) }.isSuccess
    if (!ok) {
        runCatching { context.startActivity(Intent.createChooser(intent, null)) }
    }
}

// ---------------------------------------------------------------- 文本

@Composable
private fun TextPreview(context: Context, uri: Uri) {
    var text by remember(uri) { mutableStateOf<String?>(null) }
    LaunchedEffect(uri) {
        text = withContext(Dispatchers.IO) {
            runCatching {
                context.contentResolver.openInputStream(uri)?.use { input ->
                    val buf = ByteArray(TEXT_LIMIT)
                    var read = 0
                    while (read < buf.size) {
                        val n = input.read(buf, read, buf.size - read)
                        if (n <= 0) break
                        read += n
                    }
                    String(buf, 0, read, Charsets.UTF_8)
                } ?: ""
            }.getOrElse { "读取失败：${it.message}" }
        }
    }
    val content = text
    if (content == null) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
        return
    }
    val lines = remember(content) { content.split('\n') }
    val digits = lines.size.toString().length
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 8.dp, vertical = 6.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        lines.forEachIndexed { index, line ->
            Row(verticalAlignment = Alignment.Top) {
                Text(
                    text = (index + 1).toString().padStart(digits),
                    fontSize = 11.sp,
                    fontFamily = FontFamily.Monospace,
                    color = SfColors.OnSurfaceVariant.copy(alpha = 0.6f),
                    modifier = Modifier.padding(end = 8.dp),
                )
                Text(
                    text = line.ifEmpty { " " },
                    fontSize = 12.sp,
                    fontFamily = FontFamily.Monospace,
                    color = SfColors.OnSurface,
                )
            }
        }
    }
}

// ---------------------------------------------------------------- PDF

@Composable
private fun PdfPreview(context: Context, uri: Uri) {
    var pageCount by remember(uri) { mutableStateOf(0) }
    var pageIndex by remember(uri) { mutableStateOf(0) }
    var bitmap by remember(uri) { mutableStateOf<Bitmap?>(null) }
    var failed by remember(uri) { mutableStateOf(false) }

    val handle = remember(uri) {
        runCatching {
            val pfd = context.contentResolver.openFileDescriptor(uri, "r")
                ?: return@runCatching null
            val renderer = PdfRenderer(pfd)
            pfd to renderer
        }.getOrNull()
    }

    LaunchedEffect(handle) {
        pageCount = handle?.second?.pageCount ?: 0
        if (handle == null) failed = true
    }

    LaunchedEffect(handle, pageIndex) {
        val renderer = handle?.second ?: return@LaunchedEffect
        if (pageIndex >= pageCount) return@LaunchedEffect
        bitmap = withContext(Dispatchers.IO) {
            runCatching {
                renderer.openPage(pageIndex).use { page ->
                    val width = 1240
                    val height = (width.toFloat() * page.height / page.width)
                        .toInt().coerceAtLeast(1)
                    Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also {
                        it.eraseColor(Color.WHITE)
                        page.render(it, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    }
                }
            }.getOrNull()
        }
    }

    DisposableEffect(handle) {
        onDispose {
            runCatching { handle?.second?.close() }
            runCatching { handle?.first?.close() }
        }
    }

    Column(Modifier.fillMaxSize()) {
        Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
            when {
                failed -> Text(L10n.t(R.string.s_preview_failed), color = SfColors.OnSurfaceVariant)
                bitmap != null -> Image(
                    bitmap = bitmap!!.asImageBitmap(),
                    contentDescription = null,
                    modifier = Modifier.fillMaxSize(),
                    contentScale = ContentScale.Fit,
                )
                else -> CircularProgressIndicator()
            }
        }
        if (pageCount > 1) {
            Row(
                modifier = Modifier.fillMaxWidth().height(48.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.Center,
            ) {
                IconButton(
                    onClick = { if (pageIndex > 0) pageIndex-- },
                    enabled = pageIndex > 0,
                ) {
                    Icon(Icons.Filled.KeyboardArrowUp, contentDescription = null)
                }
                Text(
                    text = "${pageIndex + 1} / $pageCount",
                    fontSize = 12.sp,
                    color = SfColors.OnSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 12.dp),
                )
                IconButton(
                    onClick = { if (pageIndex + 1 < pageCount) pageIndex++ },
                    enabled = pageIndex + 1 < pageCount,
                ) {
                    Icon(Icons.Filled.KeyboardArrowDown, contentDescription = null)
                }
            }
        }
    }
}
