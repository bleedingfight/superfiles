package com.superfiles.app.ui

import com.superfiles.app.L10n
import com.superfiles.app.R

import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.CloudOff
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.CreateNewFolder
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.DriveFileMove
import androidx.compose.material.icons.outlined.FolderZip
import androidx.compose.material.icons.outlined.QrCode2
import androidx.compose.material.icons.outlined.SelectAll
import androidx.compose.material.icons.outlined.Send
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Star
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.superfiles.app.BrowserState
import com.superfiles.app.VfsViewModel
import com.superfiles.core.Entry
import com.superfiles.core.EntryKind
import java.text.DateFormat
import java.util.Date
import java.util.Locale

/** 批量操作的待选对话框。 */
private enum class BatchDialog { Copy, Move, Compress, Delete, Send }

/**
 * M0 browser: single pane, tap to enter a folder, every row ends with a
 * "⋯" actions button (与首页 FileRow 尾缀一致) opening the M3 action sheet
 * （复制/详情/压缩/上传/打开方式/重命名/删除）.
 *
 * M1 增量：长按进入多选模式（选择顶栏 + 底部批量操作条：复制/移动/压缩/删除），
 * 实时列举失败时回退索引缓存并展示过期标记横幅。
 *
 * Android TV support comes from the same composable once focus handling lands
 * in M5; the list is already D-pad navigable because it uses standard M3 items.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FileBrowserScreen(
    viewModel: VfsViewModel = viewModel(),
    // 由 AppRoot 持有：预览页/详情页会把这个 composable 移出组合，
    // 状态放在这里才能保证「预览退出后回到原来的滚动位置」。
    scrollStates: MutableMap<String, LazyListState> = remember { mutableMapOf() },
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    // 滑动多选：记录各行窗口位置，长按后拖动可连续选中
    val dragTracker = remember { DragSelectTracker() }
    // 每个目录/分类独立记忆滚动位置：进入子目录或预览后再返回时回到原位置
    // 平板/折叠展开（≥840dp）：左列表 + 右预览双栏。点文件先选中预览，
    // 「打开文件」再交给外部应用；目录仍是单击进入。
    val expanded = isExpandedLayout()
    var previewId by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(state.currentId) { previewId = null }
    val previewEntry = if (!expanded) {
        null
    } else {
        state.entries.firstOrNull { it.id == previewId }
            ?: state.entries.firstOrNull { it.kind == EntryKind.FILE }
            ?: state.entries.firstOrNull()
    }

    var showCreateDialog by remember { mutableStateOf(false) }
    var showOverflowMenu by remember { mutableStateOf(false) }
    var editingPath by remember { mutableStateOf(false) }
    var pathDraft by remember { mutableStateOf("") }
    var batchDialog by remember { mutableStateOf<BatchDialog?>(null) }
    var showReceive by remember { mutableStateOf(false) }
    // 错误/提示的 Snackbar 已提升到 AppRoot 全局层（任意 Tab 即时可见）

    Scaffold(
        topBar = {
            if (state.selectionMode) {
                // 多选顶栏（screens.md §1 变体）：标题 = 已选数，左侧退出，右侧全选
                TopAppBar(
                    title = { Text(L10n.t(R.string.s_1e06ae0e46, (state.selectedIds.size))) },
                    navigationIcon = {
                        IconButton(onClick = viewModel::clearSelection) {
                            Icon(Icons.Default.Close, contentDescription = L10n.t(R.string.s_6be27193bc))
                        }
                    },
                    actions = {
                        IconButton(onClick = viewModel::selectAllVisible) {
                            Icon(Icons.Outlined.SelectAll, contentDescription = L10n.t(R.string.s_66eeacd93a))
                        }
                    },
                )
            } else {
                Column {
                    TopAppBar(
                        title = {
                            if (editingPath) {
                                // 可编辑路径栏：输入绝对路径回车直达（/data/data、/storage/emulated/0/...）
                                BasicTextField(
                                    value = pathDraft,
                                    onValueChange = { pathDraft = it },
                                    singleLine = true,
                                    textStyle = TextStyle(
                                        fontSize = 15.sp,
                                        color = MaterialTheme.colorScheme.onSurface,
                                    ),
                                    cursorBrush = SolidColor(SfColors.Primary),
                                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Go),
                                    keyboardActions = KeyboardActions(onGo = {
                                        editingPath = false
                                        viewModel.navigateToPath(pathDraft)
                                    }),
                                    modifier = Modifier.fillMaxWidth(),
                                )
                            } else {
                                val editable = state.title.trim().startsWith("/")
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    modifier = Modifier
                                        .clickable(enabled = editable) {
                                            pathDraft = state.title
                                            editingPath = true
                                        }
                                        .padding(vertical = 4.dp),
                                ) {
                                    Text(
                                        text = state.title.ifBlank { "Super Files" },
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                        modifier = Modifier.weight(1f, fill = false),
                                    )
                                    if (editable) {
                                        Spacer(Modifier.width(6.dp))
                                        Icon(
                                            Icons.Outlined.Edit,
                                            contentDescription = L10n.t(R.string.s_b386730b06),
                                            modifier = Modifier.size(13.dp),
                                            tint = MaterialTheme.colorScheme.outline,
                                        )
                                    }
                                }
                            }
                        },
                        navigationIcon = {
                            when {
                                state.filterExts.isNotEmpty() ->
                                    IconButton(onClick = viewModel::clearFilter) {
                                        Icon(Icons.Default.Close, contentDescription = L10n.t(R.string.s_b62b9fc7be))
                                    }
                                state.canGoUp ->
                                    IconButton(onClick = viewModel::goUp) {
                                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = L10n.t(R.string.s_0683aced6c))
                                    }
                                state.rootKind != com.superfiles.app.BrowserRoot.AppStorage ->
                                    IconButton(onClick = viewModel::backToParentRoot) {
                                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = L10n.t(R.string.s_c3b78d3062))
                                    }
                            }
                        },
                        actions = {
                            if (editingPath) {
                                IconButton(onClick = {
                                    editingPath = false
                                    viewModel.navigateToPath(pathDraft)
                                }) { Icon(Icons.Outlined.Check, contentDescription = L10n.t(R.string.s_7653297de3)) }
                                IconButton(onClick = { editingPath = false }) {
                                    Icon(Icons.Default.Close, contentDescription = L10n.t(R.string.s_625fb26b4b))
                                }
                            } else {
                                // 路径栏星标：收藏/取消收藏当前目录
                                IconButton(onClick = viewModel::toggleFavoriteCurrent) {
                                    Icon(
                                        Icons.Outlined.Star,
                                        contentDescription = L10n.t(R.string.s_d74091b014),
                                        tint = if (state.isCurrentFavorite) {
                                            SfColors.PrimaryWarm
                                        } else {
                                            SfColors.OnSurfaceVariant
                                        },
                                    )
                                }
                                // 顶部「⋯」：新建文件夹 + 显示隐藏文件开关（. 开头默认隐藏）
                                Box {
                                IconButton(onClick = { showOverflowMenu = true }) {
                                    Icon(Icons.Default.MoreVert, contentDescription = L10n.t(R.string.s_0ec9eaf9c3))
                                }
                                DropdownMenu(
                                    expanded = showOverflowMenu,
                                    onDismissRequest = { showOverflowMenu = false },
                                ) {
                                    DropdownMenuItem(
                                        text = { Text(L10n.t(R.string.s_f3a485dffd)) },
                                        leadingIcon = { Icon(Icons.Outlined.CreateNewFolder, contentDescription = null) },
                                        onClick = {
                                            showOverflowMenu = false
                                            showCreateDialog = true
                                        },
                                    )
                                    DropdownMenuItem(
                                        text = { Text(L10n.t(R.string.s_957858f63b)) },
                                        leadingIcon = { Icon(Icons.Outlined.Download, contentDescription = null) },
                                        onClick = {
                                            showOverflowMenu = false
                                            showReceive = true
                                        },
                                    )
                                    DropdownMenuItem(
                                        text = { Text(if (state.showHidden) L10n.t(R.string.s_1a7735f92a) else L10n.t(R.string.s_124d905403)) },
                                        leadingIcon = {
                                            if (state.showHidden) Icon(Icons.Outlined.Check, contentDescription = null)
                                        },
                                        onClick = {
                                            showOverflowMenu = false
                                            viewModel.setShowHidden(!state.showHidden)
                                        },
                                    )
                                }
                                }
                            }
                        },
                    )
                    val searchFocusRequester = remember { FocusRequester() }
                    val keyboardController = LocalSoftwareKeyboardController.current
                    LaunchedEffect(state.searchFocusRequest) {
                        if (state.searchFocusRequest) {
                            searchFocusRequester.requestFocus()
                            keyboardController?.show()
                            viewModel.consumeSearchFocus()
                        }
                    }
                    // 与首页同款搜索框（SearchBar.kt 单一视觉源）；作用域随页面变化：
                    // 筛选页 = 在「该类型」内搜索，普通浏览/首页入口 = 全盘搜索。
                    SearchFieldBar(
                        query = state.searchQuery,
                        onQueryChange = viewModel::search,
                        placeholder = state.filterLabel?.let { L10n.t(R.string.s_8b84b0f55a, (it)) } ?: L10n.t(R.string.s_61437e8012),
                        modifier = Modifier.padding(horizontal = Dimens.Space6, vertical = Dimens.Space2),
                        focusRequester = searchFocusRequester,
                    )
                }
            }
        },
        // 索引由「进入目录即后台扫描」自动维护（进度显示在首页用量卡），
        // 不再提供独立 FAB 入口。
    ) { padding ->
        // 结果视图（搜索/类型筛选）的副标题改为「所在位置」
        val inResultView = state.searchQuery.isNotBlank() || state.filterLabel != null
        Box(modifier = Modifier.fillMaxSize().padding(padding)) {
            when {
                // 搜索中已有结果时不整屏清空（避免连击搜索时闪白），只加顶部细进度条
                state.loading && state.entries.isEmpty() ->
                    CircularProgressIndicator(Modifier.align(Alignment.Center))
                state.entries.isEmpty() -> EmptyState(state, Modifier.align(Alignment.Center))
                else -> Row(Modifier.fillMaxSize()) {
                    Column(
                        modifier = Modifier
                            .weight(if (expanded) 0.45f else 1f)
                            .fillMaxSize(),
                    ) {
                    if (state.loading) {
                        LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                    }
                    // M1 离线浏览：实时列举失败回退索引缓存 + 过期标记（docs/01 §7）
                    state.offlineCacheMs?.let { ms -> OfflineBanner(ms) }
                    // 方案 A（docs/06 §2.6）：整组一张白卡 + 行间发丝线，卡片随内容滚动；
                    // 卡内行仍是 FileListRow 的 74dp 平铺密度，只是多了边界。
                    LazyColumn(
                        state = scrollStates.getOrPut(
                            // 分类结果和普通目录分开记：两者 currentId 相同但列表不同
                            state.filterLabel?.let { "filter:$it" } ?: state.currentId,
                        ) { LazyListState() },
                        modifier = Modifier
                            // 宽窗走双栏（列表占左栏）；更窄时按可读宽度居中限宽
                            .then(
                                if (expanded) {
                                    Modifier.fillMaxSize()
                                } else {
                                    Modifier
                                        .widthIn(max = Adaptive.ListMaxWidth)
                                        .fillMaxSize()
                                        .align(Alignment.CenterHorizontally)
                                },
                            )
                            .padding(horizontal = Dimens.Space4),
                        contentPadding = PaddingValues(top = Dimens.Space2, bottom = Dimens.Space6),
                    ) {
                    itemsIndexed(state.entries, key = { _, entry -> entry.id }) { index, entry ->
                        val isPreview = expanded && !state.selectionMode && previewEntry?.id == entry.id
                        val selected = entry.id in state.selectedIds || isPreview
                        ListGroupItem(
                            first = index == 0,
                            last = index == state.entries.lastIndex,
                        ) {
                        SwipeRevealRow(
                            onDelete = { viewModel.deleteEntries(listOf(entry)) },
                            contentPadding = PaddingValues(horizontal = Dimens.Space4),
                            enabled = !state.selectionMode,
                        ) {
                        FileListRow(
                            badge = fileBadgeOf(entry),
                            name = entry.name,
                            // 搜索/类型筛选结果：副标题展示「所在位置」，区分不同目录的同名文件
                            meta = if (inResultView) {
                                state.locationProvider?.invoke(entry) ?: ""
                            } else {
                                subtitle(entry)
                            },
                            selected = selected,
                            modifier = Modifier.dragSelectable(
                                id = entry.id,
                                tracker = dragTracker,
                            ) { viewModel.addSelection(entry) },
                            onClick = {
                                if (state.selectionMode) {
                                    viewModel.toggleSelection(entry)
                                } else if (entry.kind == EntryKind.DIRECTORY) {
                                    previewId = null
                                    viewModel.openEntry(entry)
                                } else if (expanded) {
                                    // 双栏：先选中在右栏预览，「打开文件」再外发
                                    previewId = entry.id
                                } else {
                                    // 可预览文档（pdf/office/文本）进应用内预览；其余外部打开
                                    openEntryPrimary(context, viewModel, entry)
                                }
                            },
                            onLongClick = {
                                if (!state.selectionMode) viewModel.enterSelection(entry)
                            },
                            leading = {
                                if (state.selectionMode) SelectionCircle(selected)
                            },
                            trailing = {
                                if (!state.selectionMode) {
                                    CompactIconButton(
                                        Icons.Default.MoreHoriz,
                                        L10n.t(R.string.s_fff96edebc),
                                        onClick = { viewModel.showActions(entry) },
                                    )
                                }
                            },
                        )
                        }
                        if (index < state.entries.lastIndex) RowDivider()
                        }
                    }
                    }
                }
                if (expanded) {
                    // 分隔线 + 右栏预览（≥840dp）
                    Box(
                        modifier = Modifier
                            .fillMaxHeight()
                            .width(0.5.dp)
                            .background(SfColors.Outline.copy(alpha = 0.35f)),
                    )
                    FilePreviewPane(
                        entry = previewEntry,
                        viewModel = viewModel,
                        location = state.title,
                        modifier = Modifier
                            .weight(0.55f)
                            .fillMaxHeight(),
                        onOpen = { target ->
                            if (target.kind == EntryKind.DIRECTORY) {
                                viewModel.openEntry(target)
                            } else {
                                openEntryPrimary(context, viewModel, target)
                            }
                        },
                        onShare = { target -> viewModel.startShare(listOf(target)) },
                        onMore = { target -> viewModel.showActions(target) },
                    )
                }
            }
            }

            // 多选模式底部批量操作条（M1）
            if (state.selectionMode) {
                SelectionActionBar(
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .padding(Dimens.Space4),
                    onCopy = { batchDialog = BatchDialog.Copy },
                    onMove = { batchDialog = BatchDialog.Move },
                    onCompress = { batchDialog = BatchDialog.Compress },
                    onDelete = { batchDialog = BatchDialog.Delete },
                    onSend = { batchDialog = BatchDialog.Send },
                    onShare = {
                        val sel = viewModel.selectedEntries()
                        viewModel.clearSelection()
                        viewModel.startShare(sel)
                    },
                )
            }
        }

    }

    // 「⋯」操作面板与其余弹窗由全局 FileActionsHost（AppRoot 挂载）承载，
    // 这里只保留新建文件夹 + 批量操作弹窗。
    if (showCreateDialog) {
        CreateFolderDialog(
            onDismiss = { showCreateDialog = false },
            onCreate = { name ->
                showCreateDialog = false
                viewModel.createFolder(name)
            },
        )
    }

    val selected = viewModel.selectedEntries()
    val selectedIds = selected.map { it.id }
    when (batchDialog) {
        BatchDialog.Copy -> DestPickerDialog(
            viewModel = viewModel,
            title = L10n.t(R.string.s_310012635f, (selected.size)),
            confirmLabel = L10n.t(R.string.s_92cc5af208),
            onDismiss = { batchDialog = null },
            onPick = { dest ->
                batchDialog = null
                viewModel.clearSelection()
                viewModel.startTransfer(selectedIds, dest.id, move = false)
            },
        )
        BatchDialog.Move -> DestPickerDialog(
            viewModel = viewModel,
            title = L10n.t(R.string.s_97b2cb9b97, (selected.size)),
            confirmLabel = L10n.t(R.string.s_13b54eda03),
            onDismiss = { batchDialog = null },
            onPick = { dest ->
                batchDialog = null
                viewModel.clearSelection()
                viewModel.startTransfer(selectedIds, dest.id, move = true)
            },
        )
        BatchDialog.Compress -> CompressDialog(
            defaultName = L10n.t(R.string.s_62205f7a09),
            nameKey = selectedIds.sorted(),
            collectDirs = viewModel::collectDirs,
            onDismiss = { batchDialog = null },
            onConfirm = { name, dest, deflate ->
                batchDialog = null
                viewModel.clearSelection()
                viewModel.compressEntries(selectedIds, dest, name, deflate)
            },
        )
        BatchDialog.Send -> LocalSendPeerPicker(
            viewModel = viewModel,
            entries = selected,
            onDismiss = { batchDialog = null },
        )
        BatchDialog.Delete -> DangerConfirmDialog(
            title = L10n.t(R.string.s_2f4aaddde3),
            message = L10n.t(R.string.s_20609cb28e, (selected.size)),
            confirmLabel = L10n.t(R.string.s_2f4aaddde3),
            onConfirm = {
                batchDialog = null
                viewModel.deleteEntries(selected)
            },
            onCancel = { batchDialog = null },
        )
        null -> Unit
    }

    // ---- 接收文件（ADR 0005）：粘贴链接 → 清单确认 → 进度 ----

    if (showReceive) {
        ReceiveUrlDialog(
            onDismiss = { showReceive = false },
            onFetch = { url ->
                showReceive = false
                viewModel.fetchShareManifest(url)
            },
        )
    }

    state.incomingShare?.let { manifest ->
        SfDialog(
            onDismissRequest = viewModel::dismissIncomingShare,
            title = L10n.t(R.string.s_0edbbb853d, (manifest.files.size)),
            actions = {
                SafeCancelButton(onClick = viewModel::dismissIncomingShare)
                PrimaryConfirmButton(L10n.t(R.string.s_211474ed84), onClick = viewModel::receiveFiles)
            },
        ) {
            ListSectionCard {
                LazyColumn(modifier = Modifier.heightIn(max = 320.dp)) {
                    itemsIndexed(manifest.files, key = { _, f -> f.relUrl }) { index, f ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = Dimens.Space4, vertical = Dimens.Space2),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                f.name,
                                fontSize = 14.sp,
                                color = SfColors.OnSurface,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.weight(1f),
                            )
                            Text(
                                formatSize(f.size),
                                fontSize = 11.sp,
                                color = SfColors.OnSurfaceVariant,
                            )
                        }
                        if (index < manifest.files.lastIndex) RowDivider(start = Dimens.Space4)
                    }
                }
            }
        }
    }

    state.receive?.let { r ->
        SfDialog(
            onDismissRequest = {},
            title = L10n.t(R.string.s_d68be7993a, (r.filesDone), (r.filesTotal)),
            dismissOnBackPress = false,
            dismissOnClickOutside = false,
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(Dimens.Space2)) {
                LinearProgressIndicator(
                    progress = {
                        if (r.bytesTotal == 0L) 0f else (r.bytesDone.toFloat() / r.bytesTotal).coerceIn(0f, 1f)
                    },
                    modifier = Modifier.fillMaxWidth(),
                )
                Text(
                    "${r.currentName} · ${formatSize(r.bytesDone)} / ${formatSize(r.bytesTotal)}",
                    fontSize = 11.sp,
                    color = SfColors.OnSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }

}

/** 「接收文件」第一步：粘贴分享链接。 */
@Composable
private fun ReceiveUrlDialog(onDismiss: () -> Unit, onFetch: (String) -> Unit) {
    var url by remember { mutableStateOf("") }
    SfDialog(
        onDismissRequest = onDismiss,
        title = L10n.t(R.string.s_82d7f31661),
        actions = {
            SafeCancelButton(onClick = onDismiss)
            PrimaryConfirmButton(L10n.t(R.string.s_f9701a2c93), enabled = url.isNotBlank()) { onFetch(url.trim()) }
        },
    ) {
        SfInputField(
            value = url,
            onValueChange = { url = it },
            placeholder = L10n.t(R.string.s_56416c094f),
            onDone = { if (url.isNotBlank()) onFetch(url.trim()) },
        )
    }
}

/** 多选底部操作条：复制 / 移动 / 压缩 / 分享 / 删除。 */
@Composable
private fun SelectionActionBar(
    modifier: Modifier = Modifier,
    onCopy: () -> Unit,
    onMove: () -> Unit,
    onCompress: () -> Unit,
    onShare: () -> Unit,
    onSend: () -> Unit,
    onDelete: () -> Unit,
) {
    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(Dimens.RadiusM),
        color = SfColors.SurfaceCard,
        tonalElevation = 0.dp,
        shadowElevation = 8.dp,
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = Dimens.Space3, vertical = Dimens.Space1),
            horizontalArrangement = Arrangement.SpaceEvenly,
        ) {
            BatchAction(Icons.Outlined.ContentCopy, L10n.t(R.string.s_79d3abe929), onCopy)
            BatchAction(Icons.Outlined.DriveFileMove, L10n.t(R.string.s_68d982a1cc), onMove)
            BatchAction(Icons.Outlined.FolderZip, L10n.t(R.string.s_6612548ad8), onCompress)
            BatchAction(Icons.Outlined.QrCode2, L10n.t(R.string.s_c31f48f84e), onShare)
            BatchAction(Icons.Outlined.Send, L10n.t(R.string.s_1535fcfa4c), onSend)
            BatchAction(Icons.Outlined.Delete, L10n.t(R.string.s_2f4aaddde3), onDelete, tint = SfColors.Error)
        }
    }
}

@Composable
private fun BatchAction(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    onClick: () -> Unit,
    tint: androidx.compose.ui.graphics.Color = SfColors.OnSurface,
) {
    Column(
        modifier = Modifier
            .clickable(onClick = onClick)
            .padding(horizontal = Dimens.Space3, vertical = Dimens.Space2),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Icon(icon, contentDescription = label, tint = tint, modifier = Modifier.size(22.dp))
        Text(label, fontSize = 11.sp, color = tint)
    }
}

/** 离线缓存横幅：列表来自索引缓存（断网/服务不可达），附上次更新时间。 */
@Composable
private fun OfflineBanner(ms: Long?) {
    val time = ms?.let {
        DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT, Locale.getDefault())
            .format(Date(it))
    } ?: L10n.t(R.string.s_9418d7cb5e)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(SfColors.SearchFieldBg)
            .padding(horizontal = Dimens.Space4, vertical = Dimens.Space2),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Dimens.Space2),
    ) {
        Icon(
            Icons.Outlined.CloudOff,
            contentDescription = null,
            modifier = Modifier.size(14.dp),
            tint = SfColors.OnSurfaceVariant,
        )
        Text(
            L10n.t(R.string.s_cd6ed2f6a1, (time)),
            fontSize = 11.sp,
            color = SfColors.OnSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun EmptyState(state: BrowserState, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Dimens.Space2),
    ) {
        Text(L10n.t(R.string.s_1b074a58c2), style = MaterialTheme.typography.titleMedium)
        Text(
            if (state.searchQuery.isBlank()) {
                if (state.filterExts.isNotEmpty()) L10n.t(R.string.s_7fcac721a7) else L10n.t(R.string.s_1edde9a227)
            } else {
                L10n.t(R.string.s_e704685af8, (state.searchQuery))
            },
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun CreateFolderDialog(onDismiss: () -> Unit, onCreate: (String) -> Unit) {
    var name by remember { mutableStateOf("") }
    SfDialog(
        onDismissRequest = onDismiss,
        title = L10n.t(R.string.s_f3a485dffd),
        actions = {
            SafeCancelButton(onClick = onDismiss)
            PrimaryConfirmButton(L10n.t(R.string.s_d9ac9228e8), enabled = name.isNotBlank()) { onCreate(name.trim()) }
        },
    ) {
        // 与搜索框同款外观（SearchBar.kt 单一视觉源）
        SfInputField(
            value = name,
            onValueChange = { name = it },
            placeholder = L10n.t(R.string.s_a98473f2a6),
            onDone = { if (name.isNotBlank()) onCreate(name.trim()) },
        )
    }
}

/**
 * 平板/折叠展开（≥840dp）的右栏预览：缩略图 + 名称/大小 + 打开/分享/更多。
 * 图片/PDF/视频首帧复用详情页的加载器；远端文件回退类型图标。
 */
@Composable
private fun FilePreviewPane(
    entry: Entry?,
    viewModel: VfsViewModel,
    location: String,
    modifier: Modifier = Modifier,
    onOpen: (Entry) -> Unit,
    onShare: (Entry) -> Unit,
    onMore: (Entry) -> Unit,
) {
    if (entry == null) {
        Box(modifier = modifier, contentAlignment = Alignment.Center) {
            Text(L10n.t(R.string.s_f66f892d63), fontSize = 12.sp, color = SfColors.OnSurfaceVariant)
        }
        return
    }
    val context = LocalContext.current
    val preview by produceState(DetailsPreview(), entry.id) {
        value = loadDetailsPreview(context, viewModel, entry)
    }
    Column(
        modifier = modifier
            .verticalScroll(rememberScrollState())
            .padding(Dimens.Space6),
        verticalArrangement = Arrangement.spacedBy(Dimens.Space4),
    ) {
        Surface(
            shape = RoundedCornerShape(Dimens.RadiusL),
            color = SfColors.SurfaceTint,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 220.dp)
                    .padding(Dimens.Space4),
                contentAlignment = Alignment.Center,
            ) {
                val bitmap = preview.bitmap
                if (bitmap != null) {
                    Image(
                        bitmap = bitmap.asImageBitmap(),
                        contentDescription = L10n.t(R.string.s_fa23767b5a),
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(max = 420.dp)
                            .clip(RoundedCornerShape(Dimens.RadiusM)),
                        contentScale = ContentScale.Fit,
                    )
                } else {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(Dimens.Space2),
                    ) {
                        Icon(
                            FileIcon.of(entry),
                            contentDescription = null,
                            modifier = Modifier.size(56.dp),
                            tint = if (entry.kind == EntryKind.DIRECTORY) {
                                SfColors.PrimaryWarm
                            } else {
                                SfColors.OnSurfaceVariant
                            },
                        )
                        Text(
                            if (entry.kind == EntryKind.DIRECTORY) L10n.t(R.string.s_1f4c1042ed) else L10n.t(R.string.s_2a0c4740f1),
                            fontSize = 11.sp,
                            color = SfColors.OnSurfaceVariant,
                        )
                    }
                }
            }
        }
        Text(
            entry.name,
            fontSize = 18.sp,
            fontWeight = androidx.compose.ui.text.font.FontWeight.Medium,
            color = SfColors.OnSurface,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        Text(subtitle(entry), fontSize = 12.sp, color = SfColors.OnSurfaceVariant)
        if (location.isNotBlank()) {
            Text(
                location,
                fontSize = 11.sp,
                color = SfColors.OnSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (entry.kind == EntryKind.FILE) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Dimens.Space2),
            ) {
                PrimaryConfirmButton(
                    label = L10n.t(R.string.s_6cfd8797ec),
                    modifier = Modifier.weight(1f),
                    onClick = { onOpen(entry) },
                )
                TextButton(onClick = { onShare(entry) }) { Text(L10n.t(R.string.s_c31f48f84e)) }
                TextButton(onClick = { onMore(entry) }) { Text(L10n.t(R.string.s_0ec9eaf9c3)) }
            }
        } else {
            PrimaryConfirmButton(
                label = L10n.t(R.string.s_b00f8cb915),
                modifier = Modifier.fillMaxWidth(),
                onClick = { onOpen(entry) },
            )
        }
    }
}

private fun subtitle(entry: Entry): String {
    if (entry.kind == EntryKind.DIRECTORY) return L10n.t(R.string.s_1f4c1042ed)
    val parts = mutableListOf(formatSize(entry.size.toLong()))
    entry.mime?.let { parts += it.substringAfter('/') }
    entry.modifiedMs?.let {
        parts += DateFormat.getDateInstance(DateFormat.SHORT, Locale.getDefault()).format(Date(it))
    }
    return parts.joinToString(" · ")
}

internal fun formatSize(bytes: Long): String {
    if (bytes < 1024) return "$bytes B"
    val units = listOf("KB", "MB", "GB", "TB")
    var value = bytes.toDouble()
    var index = -1
    while (value >= 1024 && index < units.lastIndex) {
        value /= 1024
        index++
    }
    return String.format(Locale.US, "%.1f %s", value, units[index])
}
