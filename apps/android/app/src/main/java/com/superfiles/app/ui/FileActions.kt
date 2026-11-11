package com.superfiles.app.ui

import com.superfiles.app.L10n

import android.content.Context
import android.content.Intent
import android.webkit.MimeTypeMap
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CloudUpload
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.DriveFileMove
import androidx.compose.material.icons.outlined.DriveFileRenameOutline
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.FolderZip
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.OpenInNew
import androidx.compose.material.icons.outlined.QrCode2
import androidx.compose.material.icons.outlined.Star
import androidx.compose.material.icons.outlined.Send
import androidx.compose.material.icons.outlined.Storage
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.runtime.getValue
import androidx.compose.ui.draw.clip
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import com.superfiles.app.EntryDetails
import com.superfiles.app.R
import com.superfiles.core.Entry
import com.superfiles.core.EntryKind
import java.io.File
import java.text.DateFormat
import java.util.Date
import java.util.Locale
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily

/** 对话框「取消」：纯文字按钮（与主操作实心按钮形成主次层级）。 */
@Composable
internal fun SafeCancelButton(label: String = L10n.t(R.string.s_625fb26b4b), onClick: () -> Unit) {
    TextButton(onClick = onClick) {
        Text(label, fontSize = 13.sp, color = SfColors.OnSurfaceVariant)
    }
}

/** 对话框「危险确认」：实心错误红底白字（与蓝色取消形成安全/危险的直观对比）。 */
@Composable
internal fun DangerConfirmButton(label: String, onClick: () -> Unit) {
    androidx.compose.material3.Button(
        onClick = onClick,
        shape = androidx.compose.foundation.shape.RoundedCornerShape(Dimens.RadiusS),
        colors = androidx.compose.material3.ButtonDefaults.buttonColors(
            containerColor = SfColors.Error,
            contentColor = Color.White,
        ),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 14.dp, vertical = 6.dp),
    ) { Text(label, fontSize = 13.sp) }
}

/** 品牌风迷你开关：38×22 胶囊，主色/轨道灰 + 白色旋钮滑动动画。 */
@Composable
internal fun SfSwitch(checked: Boolean, onCheckedChange: (Boolean) -> Unit) {
    val offset by androidx.compose.animation.core.animateDpAsState(
        targetValue = if (checked) 18.dp else 2.dp,
        animationSpec = androidx.compose.animation.core.tween(160),
        label = "sf-switch",
    )
    val trackColor = if (checked) SfColors.Primary else SfColors.UsageTrack
    androidx.compose.foundation.layout.Box(
        modifier = Modifier
            .size(width = 38.dp, height = 22.dp)
            .clip(androidx.compose.foundation.shape.CircleShape)
            .background(trackColor)
            .clickable { onCheckedChange(!checked) },
    ) {
        androidx.compose.foundation.layout.Box(
            modifier = Modifier
                .offset(x = offset, y = 2.dp)
                .size(18.dp)
                .clip(androidx.compose.foundation.shape.CircleShape)
                .background(Color.White),
        )
    }
}

/** 行内紧凑图标按钮：36dp 触摸区 + 20dp 图标（与行首 24dp 描边图标视觉一致）。 */
@Composable
internal fun CompactIconButton(
    icon: ImageVector,
    contentDescription: String,
    tint: Color = SfColors.OnSurfaceVariant,
    onClick: () -> Unit,
) {
    androidx.compose.material3.IconButton(
        onClick = onClick,
        modifier = Modifier.size(32.dp),
    ) {
        Icon(icon, contentDescription = contentDescription, modifier = Modifier.size(20.dp), tint = tint)
    }
}

/** 「⋯」操作面板的动作集合（M1 落地项；上传复用「目标选择器 + 引擎复制」）。 */
enum class FileAction { Favorite, IndexPin, Copy, Move, Share, SendNearby, Details, Compress, Upload, OpenWith, Rename, Delete }

/** 操作面板主体（由 `ModalBottomSheet` 承载）。 */
@Composable
fun FileActionSheet(
    entry: Entry,
    uploadEnabled: Boolean,
    isFavorite: Boolean,
    onAction: (FileAction) -> Unit,
) {
    Column(modifier = Modifier.fillMaxWidth().padding(bottom = Dimens.Space4)) {
        // 头部：文件名 + 元信息（与列表行同源，风格对齐首页 FileRow）
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = Dimens.Space6, vertical = Dimens.Space3),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Dimens.Space3),
        ) {
            Icon(
                FileIcon.of(entry),
                contentDescription = null,
                tint = if (entry.kind == EntryKind.DIRECTORY) SfColors.Primary else SfColors.OnSurfaceVariant,
            )
            Column {
                Text(entry.name, fontSize = 14.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis, color = SfColors.OnSurface)
                Text(actionSheetSubtitle(entry), fontSize = 11.sp, color = SfColors.OnSurfaceVariant)
            }
        }
        HorizontalDivider(modifier = Modifier.padding(vertical = Dimens.Space2))
        ActionRow(
            Icons.Outlined.Star,
            if (isFavorite) L10n.t(R.string.s_f22cec2866) else L10n.t(R.string.s_ae336cd047),
            tint = if (isFavorite) SfColors.PrimaryWarm else SfColors.OnSurface,
        ) { onAction(FileAction.Favorite) }
        if (entry.kind == EntryKind.DIRECTORY) {
            ActionRow(Icons.Outlined.Storage, L10n.t(R.string.s_537a7b5f71)) { onAction(FileAction.IndexPin) }
        }
        ActionRow(Icons.Outlined.ContentCopy, L10n.t(R.string.s_e52ea7a274)) { onAction(FileAction.Copy) }
        ActionRow(Icons.Outlined.DriveFileMove, L10n.t(R.string.s_5c4c1e6183)) { onAction(FileAction.Move) }
        if (entry.kind == EntryKind.FILE) {
            ActionRow(Icons.Outlined.QrCode2, L10n.t(R.string.s_c31f48f84e)) { onAction(FileAction.Share) }
            ActionRow(Icons.Outlined.Send, L10n.t(R.string.s_2649a76d45)) { onAction(FileAction.SendNearby) }
        }
        ActionRow(Icons.Outlined.Info, L10n.t(R.string.s_4bcc9a5a9a)) { onAction(FileAction.Details) }
        ActionRow(Icons.Outlined.FolderZip, L10n.t(R.string.s_dfad586dbd)) { onAction(FileAction.Compress) }
        ActionRow(
            Icons.Outlined.CloudUpload,
            if (uploadEnabled) L10n.t(R.string.s_d5a73b0c7f) else L10n.t(R.string.s_394def90e8),
            enabled = uploadEnabled,
        ) { onAction(FileAction.Upload) }
        if (entry.kind == EntryKind.FILE) {
            ActionRow(Icons.Outlined.OpenInNew, L10n.t(R.string.s_14aecbce66)) { onAction(FileAction.OpenWith) }
        }
        ActionRow(Icons.Outlined.DriveFileRenameOutline, L10n.t(R.string.s_c8ce4b36cb)) { onAction(FileAction.Rename) }
        ActionRow(Icons.Outlined.Delete, L10n.t(R.string.s_2f4aaddde3), tint = SfColors.Error) { onAction(FileAction.Delete) }
    }
}

@Composable
private fun ActionRow(
    icon: ImageVector,
    label: String,
    tint: Color = SfColors.OnSurface,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    val effective = if (enabled) tint else tint.copy(alpha = 0.38f)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = Dimens.Space6),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Dimens.Space4),
    ) {
        Icon(icon, contentDescription = null, tint = effective)
        Text(label, fontSize = 14.sp, color = effective)
    }
}

private fun actionSheetSubtitle(entry: Entry): String {
    if (entry.kind == EntryKind.DIRECTORY) return L10n.t(R.string.s_1f4c1042ed)
    val parts = mutableListOf(formatSize(entry.size.toLong()))
    entry.mime?.let { parts += it.substringAfter('/') }
    return parts.joinToString(" · ")
}

// ---- 重命名 ----

@Composable
fun RenameDialog(entry: Entry, onDismiss: () -> Unit, onConfirm: (String) -> Unit) {
    var name by remember(entry.id) { mutableStateOf(entry.name) }
    SfDialog(
        onDismissRequest = onDismiss,
        title = L10n.t(R.string.s_c8ce4b36cb),
        actions = {
            SafeCancelButton(onClick = onDismiss)
            PrimaryConfirmButton(
                L10n.t(R.string.s_38cf16f220),
                enabled = name.isNotBlank() && name != entry.name,
            ) { onConfirm(name) }
        },
    ) {
        SfInputField(
            value = name,
            onValueChange = { name = it },
            placeholder = L10n.t(R.string.s_e4decf94e2),
            onDone = { if (name.isNotBlank() && name != entry.name) onConfirm(name) },
        )
    }
}

// ---- 目录选择器（复制/压缩共用） ----

@Composable
fun DirPickerDialog(
    title: String,
    collectDirs: suspend () -> List<Entry>,
    onDismiss: () -> Unit,
    onPick: (Entry) -> Unit,
) {
    val dirs by produceState<List<Entry>?>(initialValue = null) { value = collectDirs() }
    var picked by remember { mutableStateOf<Entry?>(null) }
    SfDialog(
        onDismissRequest = onDismiss,
        title = title,
        actions = {
            SafeCancelButton(onClick = onDismiss)
            PrimaryConfirmButton(L10n.t(R.string.s_38cf16f220), enabled = picked != null) { picked?.let(onPick) }
        },
    ) {
        when (val list = dirs) {
            null -> Box(
                modifier = Modifier.fillMaxWidth().height(120.dp),
                contentAlignment = Alignment.Center,
            ) { CircularProgressIndicator() }
            else -> ListSectionCard {
                LazyColumn(modifier = Modifier.heightIn(max = 320.dp)) {
                    itemsIndexed(list, key = { _, dir -> dir.id }) { index, dir ->
                        val selected = picked?.id == dir.id
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .heightIn(min = 52.dp)
                                .background(if (selected) SfColors.SurfaceTint else Color.Transparent)
                                .clickable { picked = dir }
                                .padding(horizontal = Dimens.Space3, vertical = Dimens.Space1),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(Dimens.Space2),
                        ) {
                            Icon(Icons.Outlined.Folder, contentDescription = null, tint = SfColors.PrimaryWarm)
                            Text(
                                dir.name,
                                fontSize = 14.sp,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                color = SfColors.OnSurface,
                                modifier = Modifier.weight(1f),
                            )
                        }
                        if (index < list.lastIndex) RowDivider(start = Dimens.Space4)
                    }
                }
            }
        }
    }
}

// ---- 压缩（名称 / 方式 / 目标目录） ----

@Composable
fun CompressDialog(
    defaultName: String,
    nameKey: Any,
    collectDirs: suspend () -> List<Entry>,
    onDismiss: () -> Unit,
    onConfirm: (name: String, dest: Entry, deflate: Boolean) -> Unit,
) {
    var name by remember(nameKey) { mutableStateOf(defaultName) }
    var deflate by remember { mutableStateOf(true) }
    val dirs by produceState<List<Entry>?>(initialValue = null) { value = collectDirs() }
    var dest by remember { mutableStateOf<Entry?>(null) }

    SfDialog(
        onDismissRequest = onDismiss,
        title = L10n.t(R.string.s_dfad586dbd),
        actions = {
            SafeCancelButton(onClick = onDismiss)
            PrimaryConfirmButton(
                L10n.t(R.string.s_3fa7bf4827),
                enabled = name.isNotBlank() && dest != null,
            ) { dest?.let { onConfirm(name.trim(), it, deflate) } }
        },
    ) {
        Column(
            modifier = Modifier
                .imePadding()
                .heightIn(max = 480.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(Dimens.Space3),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(Dimens.Space1)) {
                Text(L10n.t(R.string.s_cbdebbbd6c), fontSize = 11.sp, color = SfColors.OnSurfaceVariant)
                SfInputField(
                    value = name,
                    onValueChange = { name = it },
                    placeholder = L10n.t(R.string.s_313fd34061),
                )
            }
            Column {
                Text(L10n.t(R.string.s_d4d85dafca), fontSize = 11.sp, color = SfColors.OnSurfaceVariant)
                OptionRow(L10n.t(R.string.s_ba04063016), deflate) { deflate = true }
                OptionRow(L10n.t(R.string.s_9d2e334ea2), !deflate) { deflate = false }
            }
            Column(verticalArrangement = Arrangement.spacedBy(Dimens.Space1)) {
                Text(L10n.t(R.string.s_f30726cf8d), fontSize = 11.sp, color = SfColors.OnSurfaceVariant)
                when (val list = dirs) {
                    null -> Box(
                        modifier = Modifier.fillMaxWidth().height(96.dp),
                        contentAlignment = Alignment.Center,
                    ) { CircularProgressIndicator() }
                    else -> ListSectionCard {
                        LazyColumn(modifier = Modifier.heightIn(max = 180.dp)) {
                            itemsIndexed(list, key = { _, dir -> dir.id }) { index, dir ->
                                val selected = dest?.id == dir.id
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .heightIn(min = 48.dp)
                                        .background(if (selected) SfColors.SurfaceTint else Color.Transparent)
                                        .clickable { dest = dir }
                                        .padding(horizontal = Dimens.Space2),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(Dimens.Space2),
                                ) {
                                    Icon(
                                        if (selected) Icons.Outlined.CheckCircle else Icons.Outlined.Folder,
                                        contentDescription = null,
                                        tint = if (selected) SfColors.Primary else SfColors.PrimaryWarm,
                                    )
                                    Text(
                                        dir.name,
                                        fontSize = 14.sp,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                        color = SfColors.OnSurface,
                                        modifier = Modifier.weight(1f),
                                    )
                                }
                                if (index < list.lastIndex) RowDivider(start = Dimens.Space4)
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun OptionRow(label: String, selected: Boolean, onSelect: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 40.dp)
            .clickable(onClick = onSelect),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Dimens.Space2),
    ) {
        RadioButton(selected = selected, onClick = onSelect)
        Text(label, fontSize = 14.sp, color = SfColors.OnSurface)
    }
}

// ---- 同名冲突确认（复制/移动；design/screens.md §2：文件名 + 三操作 + 全部应用） ----

@Composable
fun ConflictDialog(
    prompt: com.superfiles.app.ConflictPrompt,
    onResolve: (com.superfiles.core.ConflictPolicy, Boolean) -> Unit,
    onCancel: () -> Unit,
) {
    // 每一项冲突独立记住勾选状态
    var applyToAll by remember(prompt.index) { mutableStateOf(true) }
    SfDialog(
        onDismissRequest = onCancel,
        title = L10n.t(R.string.s_2d1a0f5464),
        actions = {
            SafeCancelButton(L10n.t(R.string.s_cbda75e84b), onClick = onCancel)
            Spacer(Modifier.weight(1f))
            TextButton(onClick = {
                onResolve(com.superfiles.core.ConflictPolicy.SKIP, applyToAll)
            }) { Text(L10n.t(R.string.s_92636e8c8f), fontSize = 13.sp, color = SfColors.OnSurfaceVariant) }
            TextButton(onClick = {
                onResolve(com.superfiles.core.ConflictPolicy.RENAME, applyToAll)
            }) { Text(L10n.t(R.string.s_c8ce4b36cb), fontSize = 13.sp, color = SfColors.OnSurfaceVariant) }
            DangerConfirmButton(L10n.t(R.string.s_e09fea40f7)) {
                onResolve(com.superfiles.core.ConflictPolicy.OVERWRITE, applyToAll)
            }
        },
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(Dimens.Space3)) {
            SfDialogMessage("「${prompt.name}」")
            if (prompt.total > 1) {
                Text(
                    L10n.t(R.string.s_2b34a481df, (prompt.index), (prompt.total)),
                    fontSize = 11.sp,
                    color = SfColors.OnSurfaceVariant,
                )
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(Dimens.Space3),
                ) {
                    SfSwitch(checked = applyToAll, onCheckedChange = { applyToAll = it })
                    Text(L10n.t(R.string.s_c8b462f975), fontSize = 13.sp, color = SfColors.OnSurface)
                }
            }
        }
    }
}

// ---- 打开（FileProvider 外发） ----

private fun viewIntent(context: Context, file: File, name: String): Intent {
    val ext = name.substringAfterLast('.', "").lowercase()
    val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "*/*"
    val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
    return Intent(Intent.ACTION_VIEW)
        .setDataAndType(uri, mime)
        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
}

/** 行内单击的默认行为：交给系统默认打开程序（无默认时系统自出选择器）。 */
internal fun openFileDefault(context: Context, file: File, name: String): Boolean =
    runCatching {
        context.startActivity(viewIntent(context, file, name))
    }.isSuccess

/** 「⋯ → 打开方式」：默认程序打不开/想换程序时的强制选择器兜底。 */
internal fun openWithApp(context: Context, file: File, name: String) {
    runCatching { context.startActivity(Intent.createChooser(viewIntent(context, file, name), L10n.t(R.string.s_14aecbce66))) }
}

/**
 * 统一「打开」入口：本地文件直开；网络挂载文件先异步下载到缓存（同大小/时间复用）再交付。
 * `chooser=true` 走「打开方式」选择器。
 */
internal fun openEntryFile(
    context: Context,
    viewModel: com.superfiles.app.VfsViewModel,
    entry: Entry,
    chooser: Boolean,
) {
    fun deliver(file: File) {
        val ok = if (chooser) {
            openWithApp(context, file, entry.name)
            true
        } else {
            openFileDefault(context, file, entry.name)
        }
        if (ok) {
            viewModel.recordOpen(entry)
        } else {
            viewModel.notice(L10n.t(R.string.s_d0b586db3b, (entry.name)))
        }
    }
    if (viewModel.isLocalEntry(entry)) {
        val file = viewModel.localFileOf(entry)
        if (file != null) deliver(file) else viewModel.notice(L10n.t(R.string.s_df86c859dc))
    } else {
        // 远端（WebDAV/SMB/SFTP）：流式 ContentProvider，外部应用按需 Range 读取——
        // 不落盘、不整包下载（PDF 翻页/视频 seek 都是一次偏移读）
        com.superfiles.app.SfLog.i("open remote: ${entry.name} (${entry.id})")
        val uri = com.superfiles.app.stream.RemoteFileProvider.uriFor(entry.id)
        val mime = entry.mime
            ?: MimeTypeMap.getSingleton()
                .getMimeTypeFromExtension(entry.name.substringAfterLast('.', "").lowercase())
            ?: "*/*"
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, mime)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        val started = runCatching {
            context.startActivity(
                if (chooser) Intent.createChooser(intent, L10n.t(R.string.s_14aecbce66)) else intent,
            )
        }.isSuccess
        if (started) {
            viewModel.recordOpen(entry)
        } else {
            viewModel.notice(L10n.t(R.string.s_d0b586db3b, (entry.name)))
        }
    }
}


/**
 * 统一目标选择器（复制/移动共用）：根列表 = 应用存储 / 本地存储 / 各网络挂载，
 * 可逐层下钻；确认时把「当前所在目录」作为目标（因此需至少进入一层）。
 */
@Composable
fun DestPickerDialog(
    viewModel: com.superfiles.app.VfsViewModel,
    title: String,
    confirmLabel: String,
    onDismiss: () -> Unit,
    onPick: (com.superfiles.app.DestNode) -> Unit,
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val stack = remember { androidx.compose.runtime.mutableStateListOf<Pair<String?, String>>(null to L10n.t(R.string.s_c2b9f4b9fc)) }
    val currentId = stack.last().first
    val stackKey = currentId to stack.size
    // 目录列表用普通状态承载：只有「进入新一层」才清空闪加载态；
    // 后台刷新（dirTick）静默替换旧列表，避免每次点目录都闪一下白屏。
    var nodes by remember { mutableStateOf<List<com.superfiles.app.DestNode>?>(null) }
    var loadedKey by remember { mutableStateOf<Pair<String?, Int>?>(null) }
    var loading by remember { mutableStateOf(false) }

    // 分享/复制进来时可能还在恢复网络挂载：重试一次，并让 roots 随挂载状态刷新。
    LaunchedEffect(Unit) { viewModel.retryDisconnectedMounts() }
    LaunchedEffect(stackKey, state.dirTick, state.networkMounts) {
        if (loadedKey != stackKey) {
            // 新一层：清空并进入加载态（缓存命中时只有极短一瞬）
            nodes = null
            loading = true
        }
        val result = if (currentId == null) viewModel.destRoots() else viewModel.destChildren(currentId)
        // 防御：目录已切换则丢弃旧结果
        if (stackKey == (stack.last().first to stack.size)) {
            nodes = result
            loadedKey = stackKey
            loading = false
        }
    }

    // 视觉与首页同源（docs/06）：暖底容器 + 白色分组卡 + 发丝线分隔 +
    // 14w500 文件名 / 11 次信息；目录徽章复用首页目录色（AvatarBg + PrimaryWarm）。
    SfDialog(
        onDismissRequest = onDismiss,
        title = title,
        showCloseButton = true,
        actions = {
            SafeCancelButton(onClick = onDismiss)
            PrimaryConfirmButton(confirmLabel, enabled = currentId != null) {
                currentId?.let {
                    onPick(com.superfiles.app.DestNode(it, stack.last().second, ""))
                }
            }
        },
    ) {
                // 面包屑 + 上一级：一级时只有「根目录」，下钻后出现圆角返回键
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(Dimens.Space2),
                ) {
                    if (stack.size > 1) {
                        Box(
                            modifier = Modifier
                                .size(28.dp)
                                .clip(RoundedCornerShape(Dimens.RadiusS))
                                .background(SfColors.SearchFieldBg)
                                .clickable { stack.removeAt(stack.lastIndex) },
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(
                                Icons.AutoMirrored.Filled.ArrowBack,
                                contentDescription = L10n.t(R.string.s_0683aced6c),
                                modifier = Modifier.size(16.dp),
                                tint = SfColors.OnSurfaceVariant,
                            )
                        }
                    }
                    Text(
                        stack.joinToString(" / ") { it.second },
                        fontSize = 12.sp,
                        color = SfColors.OnSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }

                if (state.networkMounts.isEmpty()) {
                    Text(
                        L10n.t(R.string.s_5d11064379),
                        fontSize = 11.sp,
                        color = SfColors.OnSurfaceVariant,
                        modifier = Modifier.padding(top = Dimens.Space1),
                    )
                }

                Spacer(Modifier.height(Dimens.Space2))

                when {
                    nodes == null -> Box(
                        modifier = Modifier.fillMaxWidth().height(120.dp),
                        contentAlignment = Alignment.Center,
                    ) { CircularProgressIndicator() }
                    nodes.orEmpty().isEmpty() -> ListSectionCard {
                        Box(
                            modifier = Modifier.fillMaxWidth().height(72.dp),
                            contentAlignment = Alignment.Center,
                        ) {
                            Text(L10n.t(R.string.s_2b4b539ac9), fontSize = 13.sp, color = SfColors.OnSurfaceVariant)
                        }
                    }
                    else -> ListSectionCard {
                        val list = nodes.orEmpty()
                        LazyColumn(modifier = Modifier.heightIn(max = 300.dp)) {
                            itemsIndexed(list, key = { _, node -> node.id }) { index, node ->
                                DestPickerRow(
                                    name = node.name,
                                    subtitle = node.subtitle,
                                    enabled = !loading,
                                    onClick = {
                                        // 同一层忽略重复点击：防连点把「本地存储」层层压进面包屑
                                        if (node.id != currentId) {
                                            loading = true
                                            stack.add(node.id to node.name)
                                        }
                                    },
                                )
                                if (index < list.lastIndex) RowDivider(start = 68.dp)
                            }
                        }
                    }
                }
    }
}

/** 目标目录行：与首页 FileListRow 同一套字号/色板，但行高 56 更适合选择器。 */
@Composable
private fun DestPickerRow(
    name: String,
    subtitle: String,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = Dimens.Space4, vertical = Dimens.Space1)
            .heightIn(min = 56.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Dimens.Space3),
    ) {
        Box(
            modifier = Modifier
                .size(40.dp)
                .clip(RoundedCornerShape(Dimens.RadiusS))
                .background(SfColors.AvatarBg),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                Icons.Outlined.Folder,
                contentDescription = null,
                modifier = Modifier.size(20.dp),
                tint = SfColors.PrimaryWarm,
            )
        }
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                name,
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
                color = SfColors.OnSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                subtitle,
                fontSize = 11.sp,
                color = SfColors.OnSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}


/** 统一的危险确认对话框：说明文字包在圆角信息卡内；文字取消 + 实心红确认。 */
@Composable
internal fun DangerConfirmDialog(
    title: String,
    message: String,
    confirmLabel: String,
    onConfirm: () -> Unit,
    onCancel: () -> Unit,
) {
    SfDialog(
        onDismissRequest = onCancel,
        title = title,
        actions = {
            SafeCancelButton(onClick = onCancel)
            DangerConfirmButton(confirmLabel, onConfirm)
        },
    ) {
        SfDialogMessage(message)
    }
}

// ---- 就近分享（ADR 0005）：二维码 + 链接，关闭即焚 ----

/** zxing 生成二维码 Bitmap（失败返回 null，UI 退化为纯链接展示）。 */
private fun qrBitmapOf(content: String, sizePx: Int): android.graphics.Bitmap? = runCatching {
    val bits = com.google.zxing.qrcode.QRCodeWriter().encode(
        content,
        com.google.zxing.BarcodeFormat.QR_CODE,
        sizePx,
        sizePx,
    )
    android.graphics.Bitmap.createBitmap(sizePx, sizePx, android.graphics.Bitmap.Config.RGB_565)
        .apply {
            for (x in 0 until sizePx) {
                for (y in 0 until sizePx) {
                    setPixel(x, y, if (bits[x, y]) android.graphics.Color.BLACK else android.graphics.Color.WHITE)
                }
            }
        }
}.getOrNull()

@Composable
fun ShareDialog(
    info: com.superfiles.core.ShareInfo,
    onStop: () -> Unit,
) {
    val qr = remember(info.url) { qrBitmapOf(info.url, 640) }
    val context = androidx.compose.ui.platform.LocalContext.current
    val clipboard = remember(context) {
        context.getSystemService(android.content.ClipboardManager::class.java)
    }
    var copied by remember(info.url) { mutableStateOf(false) }
    val wordmark = FontFamily(Font(R.font.caveat, weight = FontWeight.Bold))

    SfDialog(
        onDismissRequest = onStop, // 关闭即停止分享（即焚）
    ) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            // 品牌字标：对应 Figma 稿右侧的 “QRcode generator” 字标，右侧控件区省略
            Text("superfiles", fontFamily = wordmark, fontSize = 30.sp, color = SfColors.OnSurface)
            Text(
                L10n.t(R.string.s_5046151ab0),
                fontSize = 10.sp,
                color = SfColors.OnSurfaceVariant,
                letterSpacing = 2.sp,
            )

            Spacer(Modifier.height(Dimens.Space6))

            // 中间大二维码：与下方主按钮/次操作行同宽，整块铺满内容区
            Surface(
                modifier = Modifier.fillMaxWidth().aspectRatio(1f),
                shape = RoundedCornerShape(Dimens.RadiusL),
                color = Color.White,
            ) {
                if (qr != null) {
                    androidx.compose.foundation.Image(
                        bitmap = qr.asImageBitmap(),
                        contentDescription = L10n.t(R.string.s_2dc98e4ae5),
                        modifier = Modifier.fillMaxSize().padding(Dimens.Space4),
                    )
                } else {
                    Box(
                        modifier = Modifier.fillMaxSize(),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            Icons.Outlined.QrCode2,
                            contentDescription = null,
                            modifier = Modifier.size(48.dp),
                            tint = SfColors.Outline,
                        )
                    }
                }
            }

            Spacer(Modifier.height(Dimens.Space3))

            Text(
                L10n.t(R.string.s_be55d64c20, (info.fileCount)),
                fontSize = 11.sp,
                color = SfColors.OnSurfaceVariant,
            )

            Spacer(Modifier.height(Dimens.Space6))

            // 对应 Figma 底部 Download 按钮 → 改为「分享」（走系统分享面板）
            PrimaryConfirmButton(
                L10n.t(R.string.s_c31f48f84e),
                modifier = Modifier.fillMaxWidth().height(48.dp),
            ) {
                val send = Intent(Intent.ACTION_SEND).apply {
                    type = "text/plain"
                    putExtra(Intent.EXTRA_SUBJECT, L10n.t(R.string.s_404d1f130d))
                    putExtra(Intent.EXTRA_TEXT, info.url)
                }
                runCatching {
                    context.startActivity(Intent.createChooser(send, L10n.t(R.string.s_6122f7b929)))
                }
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                TextButton(onClick = {
                    clipboard?.setPrimaryClip(
                        android.content.ClipData.newPlainText(L10n.t(R.string.s_6122f7b929), info.url),
                    )
                    copied = true
                }) {
                    Text(
                        if (copied) L10n.t(R.string.s_2eac575ee8) else L10n.t(R.string.s_879058ce06),
                        fontSize = 12.sp,
                        color = if (copied) SfColors.Success else SfColors.Primary,
                    )
                }
                TextButton(onClick = onStop) {
                    Text(L10n.t(R.string.s_2283b1ef7f), fontSize = 12.sp, color = SfColors.Error)
                }
            }
        }
    }
}
