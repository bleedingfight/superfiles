package com.superfiles.app.ui

import com.superfiles.app.L10n
import com.superfiles.app.R

import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.DriveFileMove
import androidx.compose.material.icons.outlined.DriveFileRenameOutline
import androidx.compose.material.icons.outlined.Sell
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material.icons.outlined.Star
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.superfiles.app.BrowserRoot
import com.superfiles.app.EntryDetails
import com.superfiles.app.VfsViewModel
import com.superfiles.core.Entry
import com.superfiles.core.EntryKind
import java.text.DateFormat
import java.util.Date
import java.util.Locale
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * 文件详情页（design/figma/04-文件详情-山屿品牌提案.png，node 2:3817）：
 * 预览卡（图片/PDF/视频缩略图，PDF 附页码、视频附时长）→ 标题区（名称 + 类型 chip
 * + 大小/页数/类型）→ 元信息卡（所在位置可跳转 / 修改时间 / 存储状态）→ 标签行
 * （占位）→ 操作区（重命名/移动/删除）→ 底栏（分享文件 / 下载到本地 / 更多）。
 *
 * 标签系统尚无基础设施（M3+ 再做），按稿放一个置灰的「＋ 添加」占位；
 * 创建时间字段不在 VFS 契约内（Entry 只有 modified_ms），暂不显示该行。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DetailsPage(
    viewModel: VfsViewModel,
    details: EntryDetails,
    onBack: () -> Unit,
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val entry = details.entry
    val isFavorite = entry.id in state.favoriteIds

    var renameTarget by remember { mutableStateOf(false) }
    var moveTarget by remember { mutableStateOf(false) }
    var deleteTarget by remember { mutableStateOf(false) }

    val preview by produceState(DetailsPreview(), entry.id) {
        value = loadDetailsPreview(context, viewModel, entry)
    }

    Scaffold(
        containerColor = SfColors.Surface,
        topBar = {
            TopAppBar(
                title = { Text(L10n.t(R.string.s_e6fc1cd75c)) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = L10n.t(R.string.s_5f411223ca))
                    }
                },
                actions = {
                    IconButton(onClick = { viewModel.toggleFavorite(entry) }) {
                        Icon(
                            if (isFavorite) Icons.Filled.Star else Icons.Outlined.Star,
                            contentDescription = if (isFavorite) L10n.t(R.string.s_f22cec2866) else L10n.t(R.string.s_ae336cd047),
                            tint = if (isFavorite) SfColors.PrimaryWarm else SfColors.OnSurfaceVariant,
                        )
                    }
                },
            )
        },
        bottomBar = {
            DetailsBottomBar(
                viewModel = viewModel,
                entry = entry,
                onMore = {
                    viewModel.dismissDetails()
                    viewModel.showActions(entry)
                },
            )
        },
    ) { padding ->
        // 自适应（docs/06 §7）：宽窗 = 左预览 / 右信息双列；窄窗 = 单列 640dp。
        Box(
            modifier = Modifier.fillMaxSize().padding(padding),
            contentAlignment = Alignment.TopCenter,
        ) {
            if (isWideLayout()) {
                Row(
                    modifier = Modifier
                        .widthIn(max = Adaptive.DetailsWideMaxWidth)
                        .fillMaxSize()
                        .padding(horizontal = Dimens.Space6),
                    horizontalArrangement = Arrangement.spacedBy(Dimens.Space6),
                ) {
                    Column(
                        modifier = Modifier
                            .weight(1f)
                            .fillMaxHeight()
                            .verticalScroll(rememberScrollState()),
                        verticalArrangement = Arrangement.spacedBy(Dimens.Space4),
                    ) {
                        PreviewCard(entry = entry, preview = preview)
                    }
                    Column(
                        modifier = Modifier
                            .weight(1f)
                            .fillMaxHeight()
                            .verticalScroll(rememberScrollState()),
                        verticalArrangement = Arrangement.spacedBy(Dimens.Space4),
                    ) {
                        TitleZone(entry = entry, preview = preview)
                        MetaCard(
                            state = state,
                            entry = entry,
                            location = details.path,
                            onOpenLocation = {
                                viewModel.dismissDetails()
                                viewModel.openParentOf(entry)
                            },
                        )
                        TagsRow()
                        ActionsRow(
                            onRename = { renameTarget = true },
                            onMove = { moveTarget = true },
                            onDelete = { deleteTarget = true },
                        )
                        Spacer(Modifier.height(Dimens.Space2))
                    }
                }
            } else {
                Column(
                    modifier = Modifier
                        .widthIn(max = Adaptive.DetailsSingleMaxWidth)
                        .fillMaxSize()
                        .verticalScroll(rememberScrollState())
                        .padding(horizontal = Dimens.Space6),
                    verticalArrangement = Arrangement.spacedBy(Dimens.Space4),
                ) {
                    PreviewCard(entry = entry, preview = preview)
                    TitleZone(entry = entry, preview = preview)
                    MetaCard(
                        state = state,
                        entry = entry,
                        location = details.path,
                        onOpenLocation = {
                            viewModel.dismissDetails()
                            viewModel.openParentOf(entry)
                        },
                    )
                    TagsRow()
                    ActionsRow(
                        onRename = { renameTarget = true },
                        onMove = { moveTarget = true },
                        onDelete = { deleteTarget = true },
                    )
                    Spacer(Modifier.height(Dimens.Space2))
                }
            }
        }
    }

    // 复用既有对话框（与「⋯」菜单同一套文案与样式）
    if (renameTarget) {
        RenameDialog(
            entry = entry,
            onDismiss = { renameTarget = false },
            onConfirm = { name ->
                renameTarget = false
                onBack()
                viewModel.renameEntry(entry, name)
            },
        )
    }
    if (moveTarget) {
        DestPickerDialog(
            viewModel = viewModel,
            title = L10n.t(R.string.s_5c4c1e6183),
            confirmLabel = L10n.t(R.string.s_13b54eda03),
            onDismiss = { moveTarget = false },
            onPick = { dest ->
                moveTarget = false
                onBack()
                viewModel.startTransfer(listOf(entry.id), dest.id, move = true)
            },
        )
    }
    if (deleteTarget) {
        DangerConfirmDialog(
            title = L10n.t(R.string.s_2f4aaddde3),
            message = L10n.t(R.string.s_6cb5cdaeda, (entry.name)),
            confirmLabel = L10n.t(R.string.s_2f4aaddde3),
            onConfirm = {
                deleteTarget = false
                onBack()
                viewModel.delete(entry)
            },
            onCancel = { deleteTarget = false },
        )
    }
}

// ---- 预览卡 ----

/** 详情页预览数据：位图（可空）+ PDF 页数 / 视频时长。 */
internal data class DetailsPreview(
    val bitmap: android.graphics.Bitmap? = null,
    val pageCount: Int? = null,
    val durationMs: Long? = null,
)

@Composable
private fun PreviewCard(entry: Entry, preview: DetailsPreview) {
    Surface(
        shape = RoundedCornerShape(Dimens.RadiusL),
        color = SfColors.SurfaceTint,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 200.dp)
                .padding(Dimens.Space3),
            contentAlignment = Alignment.Center,
        ) {
            val bitmap = preview.bitmap
            if (bitmap != null) {
                Image(
                    bitmap = bitmap.asImageBitmap(),
                    contentDescription = L10n.t(R.string.s_fa23767b5a),
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(max = 360.dp)
                        .clip(RoundedCornerShape(Dimens.RadiusM)),
                    contentScale = ContentScale.Fit,
                )
            } else {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(Dimens.Space2),
                    modifier = Modifier.padding(vertical = Dimens.Space8),
                ) {
                    Icon(
                        FileIcon.of(entry),
                        contentDescription = null,
                        modifier = Modifier.size(56.dp),
                        tint = if (entry.kind == EntryKind.DIRECTORY) SfColors.PrimaryWarm else SfColors.OnSurfaceVariant,
                    )
                    Text(
                        if (entry.kind == EntryKind.DIRECTORY) L10n.t(R.string.s_1f4c1042ed) else extLabel(entry),
                        fontSize = 11.sp,
                        color = SfColors.OnSurfaceVariant,
                    )
                }
            }
            // 页码 / 时长 chip（稿中右下角白胶囊）
            val chip = when {
                preview.pageCount != null -> "1 / ${preview.pageCount}"
                preview.durationMs != null -> formatDuration(preview.durationMs)
                else -> null
            }
            chip?.let {
                Surface(
                    shape = RoundedCornerShape(Dimens.RadiusPill),
                    color = SfColors.SurfaceCard,
                    modifier = Modifier
                        .align(Alignment.BottomEnd)
                        .padding(Dimens.Space2),
                ) {
                    Text(
                        it,
                        fontSize = 11.sp,
                        color = SfColors.OnSurface,
                        modifier = Modifier.padding(horizontal = Dimens.Space3, vertical = Dimens.Space1),
                    )
                }
            }
        }
    }
}

// ---- 标题区：名称 + 类型 chip + 元信息副标题 ----

@Composable
private fun TitleZone(entry: Entry, preview: DetailsPreview) {
    Column(verticalArrangement = Arrangement.spacedBy(Dimens.Space2)) {
        Row(verticalAlignment = Alignment.Top) {
            Text(
                entry.name,
                fontSize = 18.sp,
                fontWeight = FontWeight.Medium,
                color = SfColors.OnSurface,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            val badge = fileBadgeOf(entry)
            badge.ext?.let { ext ->
                Spacer(Modifier.width(Dimens.Space3))
                Surface(
                    shape = RoundedCornerShape(Dimens.RadiusS),
                    color = badge.bg,
                ) {
                    Text(
                        ext,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = badge.fg,
                        modifier = Modifier.padding(horizontal = Dimens.Space2, vertical = 3.dp),
                    )
                }
            }
        }
        val parts = if (entry.kind == EntryKind.DIRECTORY) {
            listOf(L10n.t(R.string.s_1f4c1042ed))
        } else {
            buildList {
                add(formatSize(entry.size.toLong()))
                preview.pageCount?.let { add(L10n.t(R.string.s_7188e77d6c, (it))) }
                preview.durationMs?.let { add(formatDuration(it)) }
                entry.mime?.substringAfter('/')?.let { add(it) }
            }
        }
        Text(
            parts.joinToString(" · "),
            fontSize = 12.sp,
            color = SfColors.OnSurfaceVariant,
        )
    }
}

// ---- 元信息卡 ----

@Composable
private fun MetaCard(
    state: com.superfiles.app.BrowserState,
    entry: Entry,
    location: String,
    onOpenLocation: () -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(Dimens.RadiusM),
        color = SfColors.SurfaceCard,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier.padding(Dimens.Space4),
            verticalArrangement = Arrangement.spacedBy(Dimens.Space3),
        ) {
            MetaRow(
                label = L10n.t(R.string.s_4aca948c7c),
                value = location,
                onClick = onOpenLocation,
            )
            MetaRow(
                label = L10n.t(R.string.s_1303e638b5),
                value = formatDateTime(entry.modifiedMs),
            )
            MetaRow(
                label = L10n.t(R.string.s_a460134bfa),
                value = storageStatus(state.rootKind),
            )
        }
    }
}

@Composable
private fun MetaRow(label: String, value: String, onClick: (() -> Unit)? = null) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, fontSize = 12.sp, color = SfColors.OnSurfaceVariant)
        Spacer(Modifier.weight(1f))
        Text(
            value,
            fontSize = 13.sp,
            color = SfColors.OnSurface,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

private fun storageStatus(root: BrowserRoot): String = when (root) {
    BrowserRoot.AppStorage -> L10n.t(R.string.s_d74312f8f1)
    BrowserRoot.SharedStorage -> L10n.t(R.string.s_ab11d7d493)
    BrowserRoot.System -> L10n.t(R.string.s_5b2137e40d)
    BrowserRoot.Network -> L10n.t(R.string.s_c2d8a5b395)
}

// ---- 标签行（占位：标签系统尚无基础设施） ----

@Composable
private fun TagsRow() {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Dimens.Space2),
    ) {
        Icon(
            Icons.Outlined.Sell,
            contentDescription = null,
            modifier = Modifier.size(16.dp),
            tint = SfColors.Outline,
        )
        Surface(
            shape = RoundedCornerShape(Dimens.RadiusPill),
            color = SfColors.SearchFieldBg,
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(horizontal = Dimens.Space3, vertical = Dimens.Space1),
            ) {
                Icon(
                    Icons.Outlined.Add,
                    contentDescription = null,
                    modifier = Modifier.size(12.dp),
                    tint = SfColors.OnSurfaceVariant.copy(alpha = 0.5f),
                )
                Spacer(Modifier.width(2.dp))
                Text(
                    L10n.t(R.string.s_736eaaaec5),
                    fontSize = 11.sp,
                    color = SfColors.OnSurfaceVariant.copy(alpha = 0.5f),
                )
            }
        }
    }
}

// ---- 操作区：重命名 / 移动 / 删除 ----

@Composable
private fun ActionsRow(
    onRename: () -> Unit,
    onMove: () -> Unit,
    onDelete: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(Dimens.Space2),
    ) {
        ActionCard(Icons.Outlined.DriveFileRenameOutline, L10n.t(R.string.s_c8ce4b36cb), Modifier.weight(1f), onClick = onRename)
        ActionCard(Icons.Outlined.DriveFileMove, L10n.t(R.string.s_68d982a1cc), Modifier.weight(1f), onClick = onMove)
        ActionCard(Icons.Outlined.Delete, L10n.t(R.string.s_2f4aaddde3), Modifier.weight(1f), tint = SfColors.Error, onClick = onDelete)
    }
}

@Composable
private fun ActionCard(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    modifier: Modifier = Modifier,
    tint: Color = SfColors.OnSurface,
    onClick: () -> Unit,
) {
    Surface(
        onClick = onClick,
        modifier = modifier.heightIn(min = 60.dp),
        shape = RoundedCornerShape(Dimens.RadiusM),
        color = SfColors.SurfaceCard,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
            modifier = Modifier.padding(vertical = Dimens.Space3),
        ) {
            Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
            Spacer(Modifier.height(4.dp))
            Text(label, fontSize = 11.sp, color = tint)
        }
    }
}

// ---- 底栏：分享文件 / 下载 / 更多 ----

@Composable
private fun DetailsBottomBar(
    viewModel: VfsViewModel,
    entry: Entry,
    onMore: () -> Unit,
) {
    val canDownload = entry.kind == EntryKind.FILE && !viewModel.isLocalEntry(entry)
    Surface(color = SfColors.Surface, tonalElevation = 2.dp) {
        Box(modifier = Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            Row(
                modifier = Modifier
                    .widthIn(max = Adaptive.DetailsWideMaxWidth)
                    .fillMaxWidth()
                    .padding(horizontal = Dimens.Space6, vertical = Dimens.Space3),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Dimens.Space4),
            ) {
                Button(
                    onClick = { viewModel.startShare(listOf(entry)) },
                    modifier = Modifier.weight(1f).heightIn(min = 44.dp),
                    shape = RoundedCornerShape(Dimens.RadiusS),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = SfColors.Primary,
                        contentColor = Color.White,
                    ),
                ) {
                    Icon(Icons.Outlined.Share, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(Dimens.Space2))
                    Text(L10n.t(R.string.s_4dc67882f7), fontSize = 14.sp)
                }
                BottomAction(
                    icon = Icons.Outlined.Download,
                    label = L10n.t(R.string.s_f26ef91424),
                    enabled = canDownload,
                    onClick = { viewModel.downloadToAppStorage(entry) },
                )
                BottomAction(
                    icon = Icons.Default.MoreHoriz,
                    label = L10n.t(R.string.s_0ec9eaf9c3),
                    enabled = true,
                    onClick = onMore,
                )
            }
        }
    }
}

@Composable
private fun BottomAction(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val alpha = if (enabled) 1f else 0.38f
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp),
        modifier = Modifier
            .clip(RoundedCornerShape(Dimens.RadiusS))
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = Dimens.Space2, vertical = Dimens.Space1),
    ) {
        Icon(
            icon,
            contentDescription = label,
            modifier = Modifier.size(22.dp),
            tint = SfColors.OnSurface.copy(alpha = alpha),
        )
        Text(label, fontSize = 10.sp, color = SfColors.OnSurfaceVariant.copy(alpha = alpha))
    }
}

// ---- 缩略图加载（图片 / PDF 首页 / 视频首帧；远端文件暂回退到类型图标） ----

internal suspend fun loadDetailsPreview(
    context: android.content.Context,
    viewModel: VfsViewModel,
    entry: Entry,
): DetailsPreview = withContext(Dispatchers.IO) {
    if (entry.kind != EntryKind.FILE || !viewModel.isLocalEntry(entry)) {
        return@withContext DetailsPreview()
    }
    val ext = entry.name.substringAfterLast('.', "").lowercase()
    val file = viewModel.localFileOf(entry) ?: return@withContext DetailsPreview()
    when (ext) {
        "pdf" -> runCatching {
            android.os.ParcelFileDescriptor.open(
                file,
                android.os.ParcelFileDescriptor.MODE_READ_ONLY,
            ).use { pfd ->
                android.graphics.pdf.PdfRenderer(pfd).use { renderer ->
                    val pages = renderer.pageCount
                    val bitmap = if (pages > 0) {
                        renderer.openPage(0).use { page ->
                            val width = 900
                            val height = (width.toFloat() * page.height / page.width).toInt().coerceAtLeast(1)
                            android.graphics.Bitmap.createBitmap(
                                width,
                                height,
                                android.graphics.Bitmap.Config.ARGB_8888,
                            ).also {
                                it.eraseColor(android.graphics.Color.WHITE)
                                page.render(it, null, null, android.graphics.pdf.PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                            }
                        }
                    } else {
                        null
                    }
                    DetailsPreview(bitmap = bitmap, pageCount = pages)
                }
            }
        }.getOrElse { DetailsPreview() }
        "jpg", "jpeg", "png", "webp", "gif", "bmp" ->
            DetailsPreview(bitmap = decodeSampledBitmap(file))
        "mp4", "mkv", "mov", "avi", "webm", "3gp" -> runCatching {
            val retriever = android.media.MediaMetadataRetriever()
            try {
                retriever.setDataSource(file.absolutePath)
                val frame = retriever.getFrameAtTime(0)
                val durationMs = retriever
                    .extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_DURATION)
                    ?.toLongOrNull()
                DetailsPreview(bitmap = frame, durationMs = durationMs)
            } finally {
                runCatching { retriever.release() }
            }
        }.getOrElse { DetailsPreview() }
        else -> DetailsPreview()
    }
}

/** 采样解码：最长边约 1080px，避免大图 OOM。 */
private fun decodeSampledBitmap(file: java.io.File): android.graphics.Bitmap? = runCatching {
    val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
    android.graphics.BitmapFactory.decodeFile(file.absolutePath, bounds)
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return@runCatching null
    var sample = 1
    while (bounds.outWidth / sample > 1080 || bounds.outHeight / sample > 1080) {
        sample *= 2
    }
    val options = android.graphics.BitmapFactory.Options().apply { inSampleSize = sample }
    android.graphics.BitmapFactory.decodeFile(file.absolutePath, options)
}.getOrNull()

private fun extLabel(entry: Entry): String {
    val ext = entry.name.substringAfterLast('.', "")
    return if (ext.isEmpty()) L10n.t(R.string.s_2a0c4740f1) else L10n.t(R.string.s_c582e2bc5c, (ext.uppercase(Locale.US)))
}

private fun formatDateTime(ms: Long?): String =
    ms?.let {
        DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT, Locale.getDefault())
            .format(Date(it))
    } ?: L10n.t(R.string.s_1622dc9b6b)

private fun formatDuration(ms: Long): String {
    val totalSeconds = (ms / 1000).coerceAtLeast(0)
    val hours = totalSeconds / 3600
    val minutes = (totalSeconds % 3600) / 60
    val seconds = totalSeconds % 60
    return if (hours > 0) {
        String.format(Locale.US, "%d:%02d:%02d", hours, minutes, seconds)
    } else {
        String.format(Locale.US, "%d:%02d", minutes, seconds)
    }
}
