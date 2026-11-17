package com.superfiles.app.ui

import com.superfiles.app.L10n
import com.superfiles.app.R

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color as AndroidColor
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import android.webkit.MimeTypeMap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import com.superfiles.app.VfsViewModel
import com.superfiles.core.Entry
import com.superfiles.core.EntryKind
import java.io.File
import java.text.DateFormat
import java.util.Date
import java.util.Locale
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.withContext

/** PDF 单页渲染宽度（px），与鸿蒙端 1400 同档；超出可视窗口的页及时释放防 OOM。 */
private const val PDF_BMP_WIDTH = 1200

/** 窗口化渲染半径：可视页 ±2 渲染，窗外 ±4 之外 recycle。 */
private const val PDF_WIN_RADIUS = 2

/** 单文件预览上限（与鸿蒙端一致）。 */
private const val PDF_MAX_BYTES = 200L * 1024 * 1024

/** 落地缓存分块（与鸿蒙端一致 2MB）。 */
private const val PDF_CHUNK = 2 * 1024 * 1024

// ---- 外部打开兜底 ----

/** 常见文档后缀 → MIME（对齐鸿蒙端 OpenExternal.ets；系统按 MIME 路由到 WPS 等）。 */
internal fun mimeOfName(name: String): String =
    when (name.substringAfterLast('.', "").lowercase()) {
        "pdf" -> "application/pdf"
        "doc" -> "application/msword"
        "docx" -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        "xls" -> "application/vnd.ms-excel"
        "xlsx" -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        "ppt" -> "application/vnd.ms-powerpoint"
        "pptx" -> "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        "txt" -> "text/plain"
        "csv" -> "text/csv"
        "md" -> "text/markdown"
        "epub" -> "application/epub+zip"
        else -> MimeTypeMap.getSingleton()
            .getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase()) ?: "*/*"
    }

/**
 * 用第三方应用打开条目：本地走 FileProvider；远端走既有流式 Provider
 * （按偏移 Range 读取，不整包下载）。系统里没有应用承接时提示「未找到可打开该文件的应用」。
 */
internal fun openEntryExternally(context: Context, viewModel: VfsViewModel, entry: Entry) {
    val mime = entry.mime ?: mimeOfName(entry.name)
    val intent: Intent = if (viewModel.isLocalEntry(entry)) {
        val file = viewModel.localFileOf(entry)
        if (file == null) {
            viewModel.notice(L10n.t(R.string.s_df86c859dc))
            return
        }
        Intent(Intent.ACTION_VIEW)
            .setDataAndType(
                FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file),
                mime,
            )
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    } else {
        Intent(Intent.ACTION_VIEW)
            .setDataAndType(com.superfiles.app.stream.RemoteFileProvider.uriFor(entry.id), mime)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    try {
        context.startActivity(intent)
        viewModel.recordOpen(entry)
    } catch (e: ActivityNotFoundException) {
        viewModel.notice(L10n.t(R.string.s_3f020d7809))
    }
}

// ---- PDF 应用内预览 ----

/**
 * PdfRenderer 封装：renderer 非线程安全，渲染经互斥串行；
 * 页尺寸在加载时一次性取出（打开页只读 size，不做位图渲染）。
 */
private class PdfDoc(
    private val pfd: ParcelFileDescriptor,
    private val renderer: PdfRenderer,
    val pageSizes: List<Pair<Int, Int>>,
) {
    val pageCount: Int get() = pageSizes.size
    private val mutex = Mutex()

    suspend fun renderPage(index: Int): Bitmap? = runCatching {
        withContext(Dispatchers.IO) {
            mutex.lock()
            try {
                renderer.openPage(index).use { page ->
                    val width = PDF_BMP_WIDTH
                    val height = (width.toFloat() * page.height / page.width).toInt().coerceAtLeast(1)
                    Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also {
                        it.eraseColor(AndroidColor.WHITE)
                        page.render(it, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    }
                }
            } finally {
                mutex.unlock()
            }
        }
    }.getOrNull()

    fun close() {
        runCatching { renderer.close() }
        runCatching { pfd.close() }
    }
}

private fun openPdfDoc(file: File): PdfDoc {
    val pfd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    try {
        val renderer = PdfRenderer(pfd)
        val sizes = ArrayList<Pair<Int, Int>>(renderer.pageCount)
        for (i in 0 until renderer.pageCount) {
            renderer.openPage(i).use { page -> sizes += page.width to page.height }
        }
        return PdfDoc(pfd, renderer, sizes)
    } catch (e: Exception) {
        runCatching { pfd.close() }
        throw e
    }
}

/** 与鸿蒙端一致的 id 散列（缓存文件名用）。 */
private fun hashOf(id: String): Int {
    var h = 5381
    for (c in id) h = h * 33 + c.code
    return h
}

/** 内核字节 → 缓存文件（同尺寸缓存命中直接复用）；2MB 分块带进度。 */
private suspend fun materializeToCache(
    context: Context,
    viewModel: VfsViewModel,
    entry: Entry,
    onProgress: (Int) -> Unit,
): File = withContext(Dispatchers.IO) {
    val file = File(context.cacheDir, "pdf_${hashOf(entry.id)}_${entry.size}.pdf")
    val total = entry.size.toLong()
    if (file.isFile && file.length() == total) return@withContext file
    var off = 0L
    file.outputStream().buffered(PDF_CHUNK).use { out ->
        while (off < total) {
            val want = minOf(PDF_CHUNK.toLong(), total - off).toInt()
            val chunk = viewModel.readEntryBytes(entry.id, off, want)
            if (chunk.isEmpty()) break
            out.write(chunk)
            off += chunk.size
            onProgress((off * 100 / total).toInt().coerceAtMost(99))
        }
    }
    if (off < total) {
        file.delete()
        throw IllegalStateException("incomplete")
    }
    file
}

/**
 * PDF 应用内预览页：内核字节落地缓存（本地文件直用真身，不复制），
 * 系统 PdfRenderer 逐页渲染为位图，LazyColumn 竖向滚动翻页；
 * 可视页 ±2 渲染、窗外释放防 OOM；捏合缩放（1..4x）+ 双击复位；
 * 底部页数徽标。单文件上限 200MB。渲染失败兜底「使用其他应用打开」。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PdfPreviewPage(
    viewModel: VfsViewModel,
    entry: Entry,
    onBack: () -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    // 0 取文件中 1 解析中 2 就绪 3 失败
    var phase by remember(entry.id) { mutableStateOf(0) }
    var progress by remember(entry.id) { mutableStateOf(0) }
    var error by remember(entry.id) { mutableStateOf<String?>(null) }
    var doc by remember(entry.id) { mutableStateOf<PdfDoc?>(null) }
    // 页码 → 位图；窗口内页渲染完成后仅对应 item 重组
    val bitmaps = remember(entry.id) { mutableStateMapOf<Int, Bitmap>() }
    val listState = remember(entry.id) { LazyListState() }
    // 缩放：捏合 1..4x；双击 1↔2。平移不做（页宽贴合，滚动翻页）——与鸿蒙端一致
    var scale by remember(entry.id) { mutableStateOf(1f) }

    // 加载：落地缓存 → PdfRenderer；离开页面关闭 renderer + 释放全部位图
    DisposableEffect(entry.id) {
        if (entry.size.toLong() <= 0L || entry.size.toLong() > PDF_MAX_BYTES) {
            error = L10n.t(R.string.s_98c0a4c46d)
            phase = 3
            onDispose { }
        } else {
            val job = scope.launch {
                runCatching {
                    phase = 0
                    val file = withContext(Dispatchers.IO) {
                        if (viewModel.isLocalEntry(entry)) viewModel.localFileOf(entry) else null
                    } ?: materializeToCache(context, viewModel, entry) { p -> progress = p }
                    phase = 1
                    doc = withContext(Dispatchers.IO) { openPdfDoc(file) }
                    phase = 2
                }.onFailure { e ->
                    if (e is CancellationException) throw e
                    com.superfiles.app.SfLog.e("pdf preview failed: ${entry.name}", e)
                    error = L10n.t(R.string.s_1b4d0cd413)
                    phase = 3
                }
            }
            onDispose {
                job.cancel()
                bitmaps.values.forEach { runCatching { it.recycle() } }
                bitmaps.clear()
                doc?.close()
            }
        }
    }

    // 窗口化渲染：跟随滚动中心页，可视 ±2 渲染，窗外 ±2 页之外释放
    val centerPage by remember { derivedStateOf { listState.firstVisibleItemIndex } }
    LaunchedEffect(doc, centerPage) {
        val d = doc ?: return@LaunchedEffect
        if (d.pageCount <= 0) return@LaunchedEffect
        val center = centerPage.coerceIn(0, d.pageCount - 1)
        val from = (center - PDF_WIN_RADIUS).coerceAtLeast(0)
        val to = (center + PDF_WIN_RADIUS).coerceAtMost(d.pageCount - 1)
        bitmaps.keys
            .filter { it < from - PDF_WIN_RADIUS - 2 || it > to + PDF_WIN_RADIUS + 2 }
            .forEach { bitmaps.remove(it)?.let { bmp -> runCatching { bmp.recycle() } } }
        for (i in from..to) {
            if (bitmaps.containsKey(i)) continue
            val bmp = d.renderPage(i) ?: continue
            bitmaps[i] = bmp
        }
    }

    Scaffold(
        containerColor = SfColors.Surface,
        topBar = {
            TopAppBar(
                title = { Text(entry.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = L10n.t(R.string.s_5f411223ca),
                        )
                    }
                },
            )
        },
    ) { padding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .background(SfColors.SurfaceTint),
        ) {
            val d = doc
            when {
                phase == 3 -> Column(
                    modifier = Modifier.align(Alignment.Center),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(Dimens.Space3),
                ) {
                    Text(error ?: L10n.t(R.string.s_1b4d0cd413), fontSize = 13.sp, color = SfColors.Error)
                    PrimaryConfirmButton(L10n.t(R.string.s_a9e636982d)) {
                        openEntryExternally(context, viewModel, entry)
                    }
                }
                phase == 2 && d != null -> {
                    LazyColumn(
                        state = listState,
                        modifier = Modifier
                            .fillMaxSize()
                            // 捏合（仅双指消费，单指竖拖留给滚动）+ 双击复位
                            .pointerInput(Unit) { detectPinch { zoomChange -> scale = (scale * zoomChange).coerceIn(1f, 4f) } }
                            .pointerInput(Unit) {
                                detectTapGestures(onDoubleTap = { scale = if (scale > 1.2f) 1f else 2f })
                            }
                            .graphicsLayer { scaleX = scale; scaleY = scale },
                        verticalArrangement = Arrangement.spacedBy(Dimens.Space3),
                        contentPadding = PaddingValues(Dimens.Space4),
                    ) {
                        items(d.pageCount, key = { it }) { index ->
                            val (wPt, hPt) = d.pageSizes[index]
                            PdfPageItem(
                                bitmap = bitmaps[index],
                                aspect = wPt.toFloat() / hPt.toFloat(),
                                pageNumber = index + 1,
                            )
                        }
                    }
                    // 页数徽标（底部居中胶囊）
                    Text(
                        L10n.t(R.string.s_5660c3acf0, (d.pageCount)),
                        fontSize = 11.sp,
                        color = SfColors.OnSurfaceVariant,
                        modifier = Modifier
                            .align(Alignment.BottomCenter)
                            .padding(bottom = Dimens.Space3)
                            .background(SfColors.SearchFieldBg, RoundedCornerShape(10.dp))
                            .padding(horizontal = 10.dp, vertical = 3.dp),
                    )
                }
                else -> Column(
                    modifier = Modifier.align(Alignment.Center),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(Dimens.Space2),
                ) {
                    CircularProgressIndicator(modifier = Modifier.size(36.dp))
                    Text(
                        if (phase == 0) L10n.t(R.string.s_a060fa75e7) else L10n.t(R.string.s_5bd5a2e741),
                        fontSize = 13.sp,
                        color = SfColors.OnSurfaceVariant,
                    )
                    if (phase == 0 && progress > 0) {
                        LinearProgressIndicator(
                            progress = { progress / 100f },
                            modifier = Modifier.widthIn(max = 180.dp),
                        )
                        Text("$progress%", fontSize = 11.sp, color = SfColors.Outline)
                    }
                }
            }
        }
    }
}

/** 单页：已渲染出位图则展示，否则等比占位（loading + 页码）。 */
@Composable
private fun PdfPageItem(bitmap: Bitmap?, aspect: Float, pageNumber: Int) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(2.dp),
        shadowElevation = 2.dp,
        color = androidx.compose.ui.graphics.Color.White,
    ) {
        if (bitmap != null) {
            Image(
                bitmap = bitmap.asImageBitmap(),
                contentDescription = L10n.t(R.string.s_42c30c5461, (pageNumber)),
                modifier = Modifier
                    .fillMaxWidth()
                    .aspectRatio(aspect),
                contentScale = ContentScale.FillWidth,
            )
        } else {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .aspectRatio(aspect),
                contentAlignment = Alignment.Center,
            ) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(Dimens.Space2),
                ) {
                    CircularProgressIndicator(modifier = Modifier.size(24.dp), strokeWidth = 2.dp)
                    Text(
                        L10n.t(R.string.s_42c30c5461, (pageNumber)),
                        fontSize = 11.sp,
                        color = SfColors.OnSurfaceVariant,
                    )
                }
            }
        }
    }
}

/** 仅双指及以上才消费的捏合检测：单指拖动不拦截，留给 LazyColumn 竖向滚动。 */
private suspend fun androidx.compose.ui.input.pointer.PointerInputScope.detectPinch(
    onZoom: (Float) -> Unit,
) {
    awaitEachGesture {
        awaitFirstDown(requireUnconsumed = false)
        var prevDistance = -1f
        while (true) {
            val event = awaitPointerEvent()
            val pressed = event.changes.filter { it.pressed }
            if (pressed.isEmpty()) break
            if (pressed.size >= 2) {
                val distance = (pressed[0].position - pressed[1].position).let {
                    kotlin.math.hypot(it.x, it.y)
                }
                if (prevDistance > 0f && distance > 0f) {
                    onZoom(distance / prevDistance)
                    pressed.forEach { if (it.positionChanged()) it.consume() }
                }
                prevDistance = distance
            } else {
                prevDistance = -1f
            }
        }
    }
}

// ---- 无法预览格式的占位页 ----

/**
 * 无法应用内渲染的文档格式占位页（doc/xls/ppt/文本等）：
 * 类型图标 + 名称/元信息 + 「使用其他应用打开」入口（FileProvider / 流式 Provider）。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DocPreviewPage(
    viewModel: VfsViewModel,
    entry: Entry,
    onBack: () -> Unit,
) {
    val context = LocalContext.current
    Scaffold(
        containerColor = SfColors.Surface,
        topBar = {
            TopAppBar(
                title = { Text(entry.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = L10n.t(R.string.s_5f411223ca),
                        )
                    }
                },
            )
        },
    ) { padding ->
        Box(
            modifier = Modifier.fillMaxSize().padding(padding),
            contentAlignment = Alignment.Center,
        ) {
            Column(
                modifier = Modifier.widthIn(max = Adaptive.DetailsSingleMaxWidth).padding(Dimens.Space6),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(Dimens.Space2),
            ) {
                Icon(
                    FileIcon.of(entry),
                    contentDescription = null,
                    modifier = Modifier.size(56.dp),
                    tint = if (entry.kind == EntryKind.DIRECTORY) SfColors.PrimaryWarm else SfColors.OnSurfaceVariant,
                )
                Spacer(Modifier.height(Dimens.Space2))
                Text(
                    entry.name,
                    fontSize = 15.sp,
                    fontWeight = androidx.compose.ui.text.font.FontWeight.Medium,
                    color = SfColors.OnSurface,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(docMetaOf(entry), fontSize = 11.sp, color = SfColors.OnSurfaceVariant)
                Spacer(Modifier.height(Dimens.Space2))
                Text(L10n.t(R.string.s_a775c7f05c), fontSize = 13.sp, color = SfColors.OnSurfaceVariant)
                Spacer(Modifier.height(Dimens.Space2))
                PrimaryConfirmButton(
                    label = L10n.t(R.string.s_a9e636982d),
                    modifier = Modifier.height(44.dp),
                ) {
                    openEntryExternally(context, viewModel, entry)
                }
            }
        }
    }
}

/** 占位页元信息行：大小 · 修改时间（与列表行副标题同源）。 */
private fun docMetaOf(entry: Entry): String {
    val parts = mutableListOf(formatSize(entry.size.toLong()))
    entry.modifiedMs?.let {
        parts += DateFormat.getDateInstance(DateFormat.SHORT, Locale.getDefault()).format(Date(it))
    }
    return parts.joinToString(" · ")
}
