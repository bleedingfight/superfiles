package com.superfiles.app.ui

import com.superfiles.app.L10n
import com.superfiles.app.R

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AccountCircle
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.Star
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.NavigationRailItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.superfiles.app.BrowserRoot
import com.superfiles.app.ShareIntakeBus
import com.superfiles.app.VfsViewModel

/**
 * 应用根骨架——Figma 稿「主导航」的 4 Tab 合同：首页 / 文件 / 收藏 / 我的。
 * 首页 = HomeScreen（Figma 还原）；文件 = 现有 M0 浏览器；收藏/我的为占位，
 * 随 screens.md 第一批（设置）与 M2（收藏聚合）落地。
 */
private enum class AppTab(@androidx.annotation.StringRes val labelRes: Int, val icon: ImageVector) {
    Home(R.string.s_db1c89e0f6, Icons.Outlined.Home),
    Files(R.string.s_2a0c4740f1, Icons.Outlined.Folder),
    Mine(R.string.s_07b1811842, Icons.Outlined.AccountCircle),
}

@Composable
fun AppRoot(vfsViewModel: VfsViewModel = viewModel()) {
    var tab by rememberSaveable { mutableStateOf(AppTab.Home) }
    val browserState by vfsViewModel.state.collectAsStateWithLifecycle()
    val pendingShare by ShareIntakeBus.pending.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val activity = remember { context.findActivity() }
    var lastBackAt by remember { mutableStateOf(0L) }
    var showNetworkSheet by remember { mutableStateOf(false) }
    var showFavoritesPage by remember { mutableStateOf(false) }
    var showTransfersPage by remember { mutableStateOf(false) }
    var showLocalSendPage by remember { mutableStateOf(false) }
    val snackbarHostState = remember { SnackbarHostState() }

    // App 退到后台：前台浮层不可见了，自动转后台（否则没有 FGS 保活）
    val lifecycleOwner = androidx.lifecycle.compose.LocalLifecycleOwner.current
    androidx.compose.runtime.DisposableEffect(lifecycleOwner) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == androidx.lifecycle.Lifecycle.Event.ON_STOP) {
                vfsViewModel.promoteForegroundTransfers()
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    // 全局提示：notice/error 在任意 Tab 立即弹出（不再积压到切页时才显示）
    LaunchedEffect(browserState.notice) {
        browserState.notice?.let { msg ->
            snackbarHostState.showSnackbar(msg)
            vfsViewModel.dismissNotice()
        }
    }
    LaunchedEffect(browserState.error) {
        browserState.error?.let { msg ->
            snackbarHostState.showSnackbar(msg)
            vfsViewModel.dismissError()
        }
    }

    // 返回手势（系统左滑/返回键）分层处理：筛选 → 上级目录 → 存储根 → 首页 Tab → 双击退出。
    // 浏览层的三个分支只在「文件」Tab 消费：否则在首页/我的上滑返回会被用户
    // 看不见的浏览器状态（子目录/其他存储根）层层吞掉，永远到不了退出层。
    BackHandler {
        when {
            // 详情页是顶层整页：返回先退出详情
            browserState.details != null -> vfsViewModel.dismissDetails()
            showTransfersPage -> showTransfersPage = false
            showFavoritesPage -> showFavoritesPage = false
            showLocalSendPage -> showLocalSendPage = false
            // 多选模式优先退出多选（不触发目录回退）
            tab == AppTab.Files && browserState.selectionMode -> vfsViewModel.clearSelection()
            tab == AppTab.Files && browserState.filterExts.isNotEmpty() -> vfsViewModel.clearFilter()
            tab == AppTab.Files && browserState.canGoUp -> vfsViewModel.goUp()
            tab == AppTab.Files && browserState.rootKind != BrowserRoot.AppStorage -> vfsViewModel.backToParentRoot()
            tab != AppTab.Home -> tab = AppTab.Home
            else -> {
                val now = android.os.SystemClock.elapsedRealtime()
                if (now - lastBackAt <= 2000L) {
                    activity?.finish()
                } else {
                    lastBackAt = now
                    android.widget.Toast.makeText(context, L10n.t(R.string.s_37148d3a28), android.widget.Toast.LENGTH_SHORT).show()
                }
            }
        }
    }
    // 自适应（docs/06 §7）：横屏手机 / 平板把底部导航换成侧栏，把高度还给内容。
    val useRail = useNavigationRail()
    val showNavigation =
        !showFavoritesPage && !showTransfersPage && !showLocalSendPage && browserState.details == null

    Scaffold(
        containerColor = SfColors.Surface,
        snackbarHost = { SnackbarHost(snackbarHostState) },
        bottomBar = {
            // 详情页自带底栏（分享/下载/更多），不叠加主导航
            if (showNavigation && !useRail) {
                NavigationBar(
                    containerColor = SfColors.SurfaceCard,
                    tonalElevation = 0.dp, // 稿中底栏为纯白无投影
                ) {
                    AppTab.entries.forEach { item ->
                        val selected = tab == item
                        NavigationBarItem(
                            selected = selected,
                            onClick = { tab = item },
                            icon = {
                                Icon(item.icon, contentDescription = L10n.t(item.labelRes), modifier = Modifier.size(22.dp))
                            },
                            label = {
                                Text(
                                    L10n.t(item.labelRes),
                                    fontSize = 10.sp,
                                    fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal,
                                )
                            },
                            colors = NavigationBarItemDefaults.colors(
                                selectedIconColor = SfColors.Primary,
                                selectedTextColor = SfColors.Primary,
                                indicatorColor = SfColors.SurfaceTint,
                                unselectedIconColor = SfColors.Outline,
                                unselectedTextColor = SfColors.OnSurfaceVariant,
                            ),
                        )
                    }
                }
            }
        },
    ) { padding ->
        Row(modifier = Modifier.fillMaxSize().padding(padding)) {
            if (showNavigation && useRail) {
                // 侧栏条目纵向居中（上下等分留白），与底栏共用同一套选中色。
                // 外层 Row 已消费 Scaffold 的系统栏 inset，侧栏不再重复加内边距。
                NavigationRail(
                    containerColor = SfColors.SurfaceCard,
                    windowInsets = WindowInsets(0, 0, 0, 0),
                ) {
                    Spacer(Modifier.weight(1f))
                    AppTab.entries.forEach { item ->
                        val selected = tab == item
                        NavigationRailItem(
                            selected = selected,
                            onClick = { tab = item },
                            icon = {
                                Icon(item.icon, contentDescription = L10n.t(item.labelRes), modifier = Modifier.size(22.dp))
                            },
                            label = {
                                Text(
                                    L10n.t(item.labelRes),
                                    fontSize = 10.sp,
                                    fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal,
                                )
                            },
                            colors = NavigationRailItemDefaults.colors(
                                selectedIconColor = SfColors.Primary,
                                selectedTextColor = SfColors.Primary,
                                indicatorColor = SfColors.SurfaceTint,
                                unselectedIconColor = SfColors.Outline,
                                unselectedTextColor = SfColors.OnSurfaceVariant,
                            ),
                        )
                    }
                    Spacer(Modifier.weight(1f))
                }
            }
            Box(modifier = Modifier.weight(1f).fillMaxSize()) {
                val details = browserState.details
                if (details != null) {
                    // 文件详情整页（design/figma/04，M1 批量/分享/传输的汇聚入口）
                    DetailsPage(
                        viewModel = vfsViewModel,
                        details = details,
                        onBack = vfsViewModel::dismissDetails,
                    )
                } else if (showTransfersPage) {
                    TransferCenterScreen(
                        viewModel = vfsViewModel,
                        onBack = { showTransfersPage = false },
                    )
                } else if (showLocalSendPage) {
                    LocalSendScreen(
                        viewModel = vfsViewModel,
                        onBack = { showLocalSendPage = false },
                        onOpenDest = {
                            vfsViewModel.openLocalSendFolder()
                            showLocalSendPage = false
                            tab = AppTab.Files
                        },
                        onOpenFiles = {
                            showLocalSendPage = false
                            tab = AppTab.Files
                        },
                    )
                } else if (showFavoritesPage) {
                    FavoritesPage(
                        viewModel = vfsViewModel,
                        onBack = { showFavoritesPage = false },
                        onOpenDirectory = {
                            showFavoritesPage = false
                            tab = AppTab.Files
                        },
                    )
                } else when (tab) {
                    AppTab.Home ->
                        HomeScreen(
                            recent = browserState.recent,
                            scanFraction = browserState.scanFraction,
                            scanDone = browserState.scanDone,
                            onSearch = {
                                vfsViewModel.requestSearchFocus()
                                tab = AppTab.Files
                            },
                            onOpenFiles = { tab = AppTab.Files },
                            onOpenFolder = { folder ->
                                vfsViewModel.applyTypeFilter(folder.name, folder.exts)
                                tab = AppTab.Files
                            },
                            // 统一打开入口：本地直开；网络挂载条目异步下载后打开
                            onOpenRecent = { item ->
                                openEntryFile(context, vfsViewModel, item.entry, chooser = false)
                            },
                            onRecentActions = { item -> vfsViewModel.showActions(item.entry) },
                            onShareEntries = { entries -> vfsViewModel.startShare(entries) },
                            onOpenSharedStorage = {
                                vfsViewModel.switchRoot(BrowserRoot.SharedStorage)
                                tab = AppTab.Files
                            },
                            networkCount = browserState.networkMounts.size,
                            onOpenNetwork = { showNetworkSheet = true },
                            networkMounts = browserState.networkMounts,
                            onOpenMount = { mount ->
                                vfsViewModel.openMount(mount)
                                tab = AppTab.Files
                            },
                            onDeleteMount = { mount -> vfsViewModel.removeNetworkMount(mount) },
                            onDeleteEntry = { entry -> vfsViewModel.deleteEntries(listOf(entry)) },
                            onManageNetwork = { showNetworkSheet = true },
                            favorites = remember(browserState.favorites, browserState.favoriteLocations) {
                                browserState.favorites.map { fav ->
                                    FavoriteItem(
                                        fav.entry,
                                        browserState.favoriteLocations[fav.entry.id] ?: "",
                                    )
                                }
                            },
                            onOpenFavoriteItem = { item ->
                                if (item.entry.kind == com.superfiles.core.EntryKind.DIRECTORY) {
                                    vfsViewModel.openEntry(item.entry)
                                    tab = AppTab.Files
                                } else {
                                    openEntryFile(context, vfsViewModel, item.entry, chooser = false)
                                }
                            },
                            onManageFavorites = { showFavoritesPage = true },
                            nickname = browserState.userNickname,
                            avatarChar = browserState.userAvatarChar,
                            onOpenAppStorage = {
                                vfsViewModel.switchRoot(BrowserRoot.AppStorage)
                                tab = AppTab.Files
                            },
                        )
                    AppTab.Files -> FileBrowserScreen(viewModel = vfsViewModel)
                    AppTab.Mine -> MineScreen(
                        viewModel = vfsViewModel,
                        onOpenTransfers = { showTransfersPage = true },
                        onOpenLocalSend = { showLocalSendPage = true },
                    )
                }
                // 「⋯」操作面板全局宿主：首页最近列表与文件页共用同一套菜单/弹窗
                FileActionsHost(vfsViewModel)
            }
        }
    }

    // 复制/移动的前台进度浮层（带「终止 / 后台传输」）
    ForegroundTransferOverlay(vfsViewModel)

    if (showNetworkSheet) {
        NetworkSheet(
            viewModel = vfsViewModel,
            onDismiss = { showNetworkSheet = false },
            onBrowse = { mount ->
                showNetworkSheet = false
                vfsViewModel.openMount(mount)
                tab = AppTab.Files
            },
        )
    }

    // 系统分享面板 → superfiles：先让用户选目标目录，再流式导入。
    if (pendingShare.isNotEmpty()) {
        DestPickerDialog(
            viewModel = vfsViewModel,
            title = L10n.t(R.string.s_5101ba25fd),
            confirmLabel = L10n.t(R.string.s_cc807e6872),
            onDismiss = { ShareIntakeBus.consume() },
            onPick = { node ->
                val uris = pendingShare
                ShareIntakeBus.consume()
                vfsViewModel.importSharedUris(uris, node.id, node.name)
            },
        )
    }

    browserState.shareImport?.let { imp ->
        SfDialog(
            onDismissRequest = {},
            title = L10n.t(R.string.s_828da2e20a),
            dismissOnBackPress = false,
            dismissOnClickOutside = false,
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(Dimens.Space2)) {
                androidx.compose.material3.LinearProgressIndicator(
                    progress = {
                        if (imp.total <= 0) 0f else imp.done.toFloat() / imp.total
                    },
                    modifier = Modifier.fillMaxWidth(),
                )
                Text(
                    "${imp.done}/${imp.total} · ${imp.destName}",
                    fontSize = 11.sp,
                    color = SfColors.OnSurfaceVariant,
                )
            }
        }
    }
}

/** 从任意 Context 找到宿主 Activity（退出提示用）。 */
private tailrec fun android.content.Context.findActivity(): android.app.Activity? = when (this) {
    is android.app.Activity -> this
    is android.content.ContextWrapper -> baseContext.findActivity()
    else -> null
}

/** 占位屏，遵循 EmptyState 合同（docs/06 §4：40 弱化图标 + 主/辅文案 + space-2）。 */
@Composable
private fun TodoPlaceholder(icon: ImageVector, title: String, hint: String) {
    Column(
        modifier = Modifier.fillMaxSize(),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(icon, contentDescription = null, modifier = Modifier.size(40.dp), tint = SfColors.Outline)
        Spacer(Modifier.height(Dimens.Space2))
        Text(title, fontSize = 15.sp, fontWeight = FontWeight.Medium, color = SfColors.OnSurface)
        Spacer(Modifier.height(Dimens.Space2))
        Text(hint, fontSize = 13.sp, color = SfColors.OnSurfaceVariant)
    }
}
