package com.superfiles.app.ui

import com.superfiles.app.L10n

import android.os.Environment
import android.os.StatFs
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
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
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.ArrowOutward
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Cloud
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.PhoneAndroid
import androidx.compose.material.icons.outlined.BusinessCenter
import androidx.compose.material.icons.outlined.CloudDone
import androidx.compose.material.icons.outlined.ContactPage
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.MoreHoriz
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Star
import androidx.compose.material.icons.outlined.TableChart
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.superfiles.app.R
import com.superfiles.core.Entry
import com.superfiles.core.RecentOpen
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Calendar
import java.util.Locale

/**
 * 首页——Figma「superfiles」稿《首页 · 栖档》（node 2:3507，design/figma/01-首页-栖档.png）
 * 的 1:1 骨架还原。当前为静态样例数据，M1 起接 VfsViewModel/索引统计/最近列表。
 *
 * 取色与间距对齐 tokens.json（SfColors / Dimens）；稿中 22/13/10 等非栅值按
 * docs/06 §2 约定 snap 到 4 基栅（分别落 Space6/Space3/Space2）。
 * 字体：Noto Sans SC 是 Android 中文默认字体，直接系统默认；数字暂用系统数字，
 * 与稿中 Inter 的差异在 v0.2 评估是否 bundled。
 */

// ---- 稿内实测的组件固定尺寸（非 grid 值，暂缓进 Dimens，随 tokens v0.2 定夺） ----
// 适配约定：凡是「内容决定的」尺寸一律 heightIn/widthIn 下限语义，不写死上限，
// 以兼容系统字体放大（fontScale）与任意屏宽（折叠外屏 ~280dp → 平板 840dp+）。
private val AvatarSize = 38.dp
private val UsageBarHeight = 5.dp
private val FolderCardHeight = 94.dp

// ---- 展示模型（接真实状态前的样例，内容照抄 Figma 稿） ----

data class FolderShortcut(
    val icon: ImageVector,
    val tint: Color,
    val name: String,
    val count: String,
    /** 点击卡片时的类型过滤集合（全树扩展名匹配，小写无点）。 */
    val exts: Set<String>,
)

data class UsageSegment(val weight: Float, val color: Color)

data class HomeSamples(
    val folders: List<FolderShortcut>,
)

/** 首页「我的文件夹」的真实数据项（收藏目录）。 */
data class FavoriteFolder(val entry: Entry, val location: String)

/** 首页「我的收藏」行（目录或文件）。 */
data class FavoriteItem(val entry: Entry, val location: String)

/** 渲染用的文件夹卡（收藏优先，空时回退样例）。 */
private data class FolderCardData(
    val name: String,
    val subtitle: String,
    val icon: ImageVector,
    val tint: Color,
    val onClick: () -> Unit,
)

/** 默认样例（颜色取自当前色板，故必须在组合上下文构造——data class 默认值做不到这一点）。 */
@Composable
private fun defaultHomeSamples() = HomeSamples(
    folders = listOf(
        // 类型集合来自产品口径：个人文档=csv/txt；工作资料=pdf/doc/docx/ppt/pptx/xls/xlsx/md；
        // 图片=jpeg/jpg/png/heic/heif/webp/gif/bmp + 相机 RAW
        FolderShortcut(
            Icons.Outlined.ContactPage, SfColors.Primary, L10n.t(R.string.s_21cbf71ba5), L10n.t(R.string.s_cebf51f9fa),
            exts = setOf("csv", "txt"),
        ),
        FolderShortcut(
            Icons.Outlined.BusinessCenter, SfColors.PrimaryWarm, L10n.t(R.string.s_4cd16ed63f), L10n.t(R.string.s_03c2fddca1),
            exts = setOf("pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "md"),
        ),
        FolderShortcut(
            Icons.Outlined.PhotoLibrary, SfColors.Success, L10n.t(R.string.s_0d15abc2ec), L10n.t(R.string.s_3f598839f6),
            exts = setOf(
                "jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "bmp",
                "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "raw",
            ),
        ),
    ),
)

/** 设备存储用量（StatFs 读 /data 卷，无需权限）。 */
data class HomeUsage(
    val used: String,
    val rest: String,
    val percentLabel: String,
    val fraction: Float,
    val segments: List<UsageSegment>,
)

/** 时段问候：5–11 上午 / 11–14 中午 / 14–18 下午 / 18–23 晚上 / 其余 夜深了。 */
private fun greetingByHour(hour: Int = Calendar.getInstance().get(Calendar.HOUR_OF_DAY)): String =
    when (hour) {
        in 5..10 -> L10n.t(R.string.s_cad057e2af)
        in 11..13 -> L10n.t(R.string.s_1a194c806d)
        in 14..17 -> L10n.t(R.string.s_8c9bdf7d38)
        in 18..22 -> L10n.t(R.string.s_6ab1f1775c)
        else -> L10n.t(R.string.s_1609d6fb55)
    }

/**
 * 时段问候的"后半句"：每个时段一组文案，按天轮换——同一天同一时段稳定，
 * 不同日子/不同时段都不同。
 */
private fun greetingTail(
    hour: Int = Calendar.getInstance().get(Calendar.HOUR_OF_DAY),
    daySeed: Int = Calendar.getInstance().get(Calendar.DAY_OF_YEAR),
): String {
    val pool = when (hour) {
        in 5..10 -> listOf(
            L10n.t(R.string.s_e8754849f8),
            L10n.t(R.string.s_2561611557),
            L10n.t(R.string.s_318676908a),
        )
        in 11..13 -> listOf(
            L10n.t(R.string.s_44a07f9176),
            L10n.t(R.string.s_36811e19a7),
        )
        in 14..17 -> listOf(
            L10n.t(R.string.s_f8e63c7730),
            L10n.t(R.string.s_15676fe90a),
        )
        in 18..22 -> listOf(
            L10n.t(R.string.s_7b20ba0f33),
            L10n.t(R.string.s_e33cb7f2b1),
        )
        else -> listOf(
            L10n.t(R.string.s_d139a88130),
            L10n.t(R.string.s_ef83ec3df9),
        )
    }
    return pool[Math.floorMod(daySeed, pool.size)]
}

/** GiB 格式化（Android 存储口径）：已用保留 1 位小数，总量取整。 */
private fun formatGb(bytes: Long, decimals: Int = 1): String =
    String.format(Locale.US, "%.${decimals}f", bytes.toDouble() / (1L shl 30))

/** 读取 /data 卷的真实用量；失败时回退占位。主题色随 LocalSfPalette 切换。 */
@Composable
private fun rememberDeviceUsage(): HomeUsage {
    val usageColor = SfColors.Primary
    return remember(usageColor) {
        runCatching {
            val stat = StatFs(Environment.getDataDirectory().absolutePath)
            val total = stat.totalBytes
            val used = total - stat.availableBytes
            val fraction = (used.toDouble() / total).toFloat().coerceIn(0f, 1f)
            HomeUsage(
                used = formatGb(used),
                rest = "GB / ${formatGb(total, 0)} GB",
                percentLabel = L10n.t(R.string.s_af2e0bc98c, (String.format(Locale.US, "%.1f", fraction * 100))),
                fraction = fraction,
                // 分类三色段需要 StorageStatsManager + 使用情况访问权限，随 M1 存储管理落地
                segments = listOf(UsageSegment(1f, usageColor)),
            )
        }.getOrElse {
            HomeUsage("--", "GB / -- GB", "", 0f, listOf(UsageSegment(1f, usageColor)))
        }
    }
}

@Composable
fun HomeScreen(
    modifier: Modifier = Modifier,
    samples: HomeSamples = defaultHomeSamples(),
    recent: List<RecentOpen> = emptyList(),
    onOpenFiles: () -> Unit = {},
    onSearch: () -> Unit = {},
    onOpenFolder: (FolderShortcut) -> Unit = {},
    onOpenRecent: (RecentOpen) -> Unit = {},
    onRecentActions: (RecentOpen) -> Unit = {},
    onShareEntries: (List<Entry>) -> Unit = {},
    onOpenSharedStorage: () -> Unit = {},
    scanFraction: Float? = null,
    scanDone: Boolean = false,
    networkCount: Int = 0,
    onOpenNetwork: () -> Unit = {},
    networkMounts: List<com.superfiles.app.NetworkMountStatus> = emptyList(),
    onOpenMount: (com.superfiles.app.NetworkMountStatus) -> Unit = {},
    onDeleteMount: (com.superfiles.app.NetworkMountStatus) -> Unit = {},
    onDeleteEntry: (Entry) -> Unit = {},
    onManageNetwork: () -> Unit = {},
    favorites: List<FavoriteItem> = emptyList(),
    onOpenFavoriteItem: (FavoriteItem) -> Unit = {},
    onManageFavorites: () -> Unit = {},
    onOpenAppStorage: () -> Unit = {},
    nickname: String = L10n.t(R.string.s_0ed27cbb38),
    avatarChar: String = L10n.t(R.string.s_d9d28cb2a0),
) {
    var showStorageSheet by remember { mutableStateOf(false) }
    // 待确认删除的网络存储连接（长按行 / 向左滑动行触发）
    var pendingDeleteMount by remember { mutableStateOf<com.superfiles.app.NetworkMountStatus?>(null) }
    // 最近打开：长按进入多选 + 左滑删除 + 滑动多选
    val recentSelection = remember { RecentSelectionState() }
    val recentDragTracker = remember { DragSelectTracker() }
    // 自适应（docs/06 §7）：
    // - 窄窗（手机竖屏）：沿用 Figma 单列，480dp 限宽居中；
    // - 宽窗（横屏手机 / 平板 / 折叠展开）：双列铺开，避免两侧大片留白。
    // 双列只重排区块归属，组件内部尺寸不变，竖屏像素级不变。
    val wide = isWideLayout()
    Box(modifier = modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
        if (wide) {
            Row(
                modifier = Modifier
                    .widthIn(max = Adaptive.HomeWideMaxWidth)
                    .fillMaxWidth()
                    .fillMaxHeight()
                    .padding(horizontal = Dimens.Space6),
                horizontalArrangement = Arrangement.spacedBy(Dimens.Space6),
            ) {
                // 左列：问候 / 搜索 / 用量 / 本地存储
                Column(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxHeight()
                        .verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(Dimens.Space6),
                ) {
                    Spacer(Modifier.height(Dimens.Space1))
                    HomeOverviewSection(
                        nickname = nickname,
                        avatarChar = avatarChar,
                        onSearch = onSearch,
                        scanFraction = scanFraction,
                        scanDone = scanDone,
                        networkCount = networkCount,
                        onOpenNetwork = onOpenNetwork,
                        onManageClick = { showStorageSheet = true },
                    )
                    LocalStorageSection(
                        onOpenSharedStorage = onOpenSharedStorage,
                        onOpenAppStorage = onOpenAppStorage,
                    )
                    Spacer(Modifier.height(Dimens.Space1))
                }
                // 右列：网络存储 / 收藏 / 最近打开
                Column(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxHeight()
                        .verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(Dimens.Space6),
                ) {
                    Spacer(Modifier.height(Dimens.Space1))
                    NetworkMountsSection(
                        networkMounts = networkMounts,
                        onOpenMount = onOpenMount,
                        onManageNetwork = onManageNetwork,
                        onDeleteRequest = { pendingDeleteMount = it },
                    )
                    FavoritesSection(
                        favorites = favorites,
                        onOpenFavoriteItem = onOpenFavoriteItem,
                        onManageFavorites = onManageFavorites,
                        onDeleteEntry = onDeleteEntry,
                    )
                    SectionHeader(title = L10n.t(R.string.s_382399a9a1), action = L10n.t(R.string.s_4a7fea713c), onActionClick = onOpenFiles)
                    RecentFilesColumn(
                        recent = recent,
                        onOpenRecent = onOpenRecent,
                        onRecentActions = onRecentActions,
                        onDeleteEntry = onDeleteEntry,
                        selection = recentSelection,
                        dragTracker = recentDragTracker,
                    )
                    Spacer(Modifier.height(Dimens.Space1))
                }
            }
        } else {
            Column(
                modifier = Modifier
                    .widthIn(max = Adaptive.HomeColumnMaxWidth)
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = Dimens.Space6), // safe-margin 合同
                verticalArrangement = Arrangement.spacedBy(Dimens.Space6), // 稿中 22 → snap
            ) {
                Spacer(Modifier.height(Dimens.Space1))
                HomeOverviewSection(
                    nickname = nickname,
                    avatarChar = avatarChar,
                    onSearch = onSearch,
                    scanFraction = scanFraction,
                    scanDone = scanDone,
                    networkCount = networkCount,
                    onOpenNetwork = onOpenNetwork,
                    onManageClick = { showStorageSheet = true },
                )
                LocalStorageSection(
                    onOpenSharedStorage = onOpenSharedStorage,
                    onOpenAppStorage = onOpenAppStorage,
                )
                NetworkMountsSection(
                    networkMounts = networkMounts,
                    onOpenMount = onOpenMount,
                    onManageNetwork = onManageNetwork,
                    onDeleteRequest = { pendingDeleteMount = it },
                )
                FavoritesSection(
                    favorites = favorites,
                    onOpenFavoriteItem = onOpenFavoriteItem,
                    onManageFavorites = onManageFavorites,
                    onDeleteEntry = onDeleteEntry,
                )
                SectionHeader(title = L10n.t(R.string.s_382399a9a1), action = L10n.t(R.string.s_4a7fea713c), onActionClick = onOpenFiles)
                RecentFilesColumn(
                    recent = recent,
                    onOpenRecent = onOpenRecent,
                    onRecentActions = onRecentActions,
                    onDeleteEntry = onDeleteEntry,
                    selection = recentSelection,
                    dragTracker = recentDragTracker,
                )
                Spacer(Modifier.height(Dimens.Space1))
            }
        }

        // 最近打开的多选操作条：全选 + 分享（批量发送）
        if (recentSelection.mode) {
            RecentSelectionBar(
                count = recentSelection.ids.size,
                onSelectAll = { recentSelection.selectAll(recent.map { it.entry.id }) },
                onShare = {
                    val entries = recent
                        .filter { it.entry.id in recentSelection.ids }
                        .map { it.entry }
                    if (entries.isNotEmpty()) {
                        recentSelection.clear()
                        onShareEntries(entries)
                    }
                },
                onCancel = { recentSelection.clear() },
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(Dimens.Space4),
            )
        }
    }

    if (showStorageSheet) {
        StorageSheet(
            onDismiss = { showStorageSheet = false },
            onOpenFiles = {
                showStorageSheet = false
                onOpenFiles()
            },
            onOpenShared = onOpenSharedStorage,
        )
    }

    pendingDeleteMount?.let { mount ->
        DangerConfirmDialog(
            title = L10n.t(R.string.s_ed4613d9b9),
            message = L10n.t(R.string.s_d10ef8e3eb, (mount.config.name)),
            confirmLabel = L10n.t(R.string.s_86048b4fea),
            onConfirm = {
                pendingDeleteMount = null
                onDeleteMount(mount)
            },
            onCancel = { pendingDeleteMount = null },
        )
    }
}

// ---- 首页分区：单列（竖屏）与双列（横屏/大屏）共用同一份实现 ----

@Composable
private fun HomeOverviewSection(
    nickname: String,
    avatarChar: String,
    onSearch: () -> Unit,
    scanFraction: Float?,
    scanDone: Boolean,
    networkCount: Int,
    onOpenNetwork: () -> Unit,
    onManageClick: () -> Unit,
) {
    GreetingHeader(nickname = nickname, avatarChar = avatarChar)
    SearchEntryBar(placeholder = L10n.t(R.string.s_1f526b56a8), onClick = onSearch)
    UsageCard(
        usage = rememberDeviceUsage(),
        scanFraction = scanFraction,
        scanDone = scanDone,
        networkCount = networkCount,
        onOpenNetwork = onOpenNetwork,
        onManageClick = onManageClick,
    )
}

@Composable
private fun LocalStorageSection(
    onOpenSharedStorage: () -> Unit,
    onOpenAppStorage: () -> Unit,
) {
    SectionHeader(title = L10n.t(R.string.s_5e2bb608f9))
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(Dimens.Space2),
    ) {
        RootCard(
            name = L10n.t(R.string.s_5e2bb608f9),
            subtitle = L10n.t(R.string.s_c2b9f4b9fc),
            icon = Icons.Outlined.PhoneAndroid,
            tint = SfColors.Primary,
            modifier = Modifier.weight(1f),
            onClick = onOpenSharedStorage,
        )
        RootCard(
            name = L10n.t(R.string.s_99f7a465ec),
            subtitle = L10n.t(R.string.s_79abfee53f),
            icon = Icons.Outlined.Folder,
            tint = SfColors.PrimaryWarm,
            modifier = Modifier.weight(1f),
            onClick = onOpenAppStorage,
        )
    }
}

/** 我的网络存储：单卡行列表（N 个连接都不碎行；与收藏/最近打开同容器语言）。 */
@Composable
private fun NetworkMountsSection(
    networkMounts: List<com.superfiles.app.NetworkMountStatus>,
    onOpenMount: (com.superfiles.app.NetworkMountStatus) -> Unit,
    onManageNetwork: () -> Unit,
    onDeleteRequest: (com.superfiles.app.NetworkMountStatus) -> Unit,
) {
    if (networkMounts.isEmpty()) return
    SectionHeader(title = L10n.t(R.string.s_6b8409e709), action = L10n.t(R.string.s_08b55fea3c), onActionClick = onManageNetwork)
    ListSectionCard {
        networkMounts.forEachIndexed { index, mount ->
            NetworkMountRow(
                mount = mount,
                onClick = { onOpenMount(mount) },
                onDeleteRequest = { onDeleteRequest(mount) },
            )
            if (index < networkMounts.lastIndex) RowDivider()
        }
    }
}

/** 我的收藏：快捷预览（完整管理在「管理」页，底部不再单独占 Tab）。 */
@Composable
private fun FavoritesSection(
    favorites: List<FavoriteItem>,
    onOpenFavoriteItem: (FavoriteItem) -> Unit,
    onManageFavorites: () -> Unit,
    onDeleteEntry: (Entry) -> Unit,
) {
    if (favorites.isEmpty()) return
    SectionHeader(title = L10n.t(R.string.s_975ff67ee1), action = L10n.t(R.string.s_08b55fea3c), onActionClick = onManageFavorites)
    ListSectionCard {
        val shown = favorites.take(5)
        shown.forEachIndexed { index, item ->
            SwipeRevealRow(
                onDelete = { onDeleteEntry(item.entry) },
                contentPadding = androidx.compose.foundation.layout.PaddingValues(
                    horizontal = Dimens.Space4,
                ),
            ) {
                FileListRow(
                    badge = fileBadgeOf(item.entry),
                    name = item.entry.name,
                    meta = item.location,
                    onClick = { onOpenFavoriteItem(item) },
                )
            }
            if (index < shown.lastIndex) RowDivider()
        }
    }
}

// ---- 欢迎区：品牌 + 问候 + 头像 ----

@Composable
private fun GreetingHeader(nickname: String, avatarChar: String) {
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        // weight(1f)：窄屏（折叠外屏/超大字体）下文本自动换行收缩，不挤出头像
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(Dimens.Space1),
        ) {
            // 品牌名：手写体 superfiles（Caveat，res/font/caveat.ttf，OFL 许可）
            Text(
                "superfiles",
                fontSize = 32.sp,
                fontFamily = FontFamily(Font(R.font.caveat, weight = FontWeight.Bold)),
                color = SfColors.OnSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                if (nickname.isBlank()) {
                    "${greetingByHour()}。${greetingTail()}"
                } else {
                    "${greetingByHour()}，$nickname。${greetingTail()}"
                },
                fontSize = 11.sp,
                color = SfColors.OnSurfaceVariant,
            )
        }
        Spacer(Modifier.width(Dimens.Space3))
        Box(
            modifier = Modifier.size(AvatarSize).clip(CircleShape).background(SfColors.AvatarBg),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                avatarChar.ifBlank { L10n.t(R.string.s_1681525453) },
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
                color = SfColors.PrimaryWarm,
            )
        }
    }
}

// ---- 存储空间卡 ----

@Composable
private fun UsageCard(
    usage: HomeUsage,
    scanFraction: Float?,
    scanDone: Boolean,
    networkCount: Int,
    onOpenNetwork: () -> Unit,
    onManageClick: () -> Unit,
) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(Dimens.RadiusL),
        color = SfColors.SurfaceTint,
    ) {
        Column(
            modifier = Modifier.padding(Dimens.Space4),
            verticalArrangement = Arrangement.spacedBy(Dimens.Space3),
        ) {
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
                Column(verticalArrangement = Arrangement.spacedBy(Dimens.Space1)) {
                    Text(L10n.t(R.string.s_5e2bb608f9), fontSize = 11.sp, color = SfColors.UsageDeep)
                    Row(
                        verticalAlignment = Alignment.Bottom,
                        horizontalArrangement = Arrangement.spacedBy(Dimens.Space1),
                    ) {
                        Text(usage.used, fontSize = 24.sp, fontWeight = FontWeight.Medium, color = SfColors.UsageDeep)
                        Text(usage.rest, fontSize = 11.sp, color = SfColors.Primary)
                    }
                }
                Spacer(Modifier.weight(1f))
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(Dimens.Space1),
                    modifier = Modifier
                        .clip(RoundedCornerShape(Dimens.RadiusS))
                        .clickable(onClick = onManageClick) // 存储管理 → 「我的」Tab（设置骨架 M1）
                        .padding(Dimens.Space1),
                ) {
                    Text(L10n.t(R.string.s_08b55fea3c), fontSize = 11.sp, color = SfColors.Primary)
                    Icon(
                        Icons.Outlined.ArrowOutward,
                        contentDescription = null,
                        modifier = Modifier.size(Dimens.Space4),
                        tint = SfColors.Primary,
                    )
                }
            }
            UsageBar(fraction = usage.fraction, segments = usage.segments)
            // 网络存储入口（已使用行上方）：点击选择 WebDAV/SFTP/Samba 等
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(Dimens.RadiusS))
                    .clickable(onClick = onOpenNetwork)
                    .padding(vertical = 2.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    Icons.Outlined.Cloud,
                    contentDescription = null,
                    modifier = Modifier.size(Dimens.Space4),
                    tint = SfColors.Primary,
                )
                Spacer(Modifier.width(Dimens.Space1))
                Text(
                    if (networkCount > 0) L10n.t(R.string.s_32890a42e9, (networkCount)) else L10n.t(R.string.s_5d4c75d1bb),
                    fontSize = 12.sp,
                    color = SfColors.Primary,
                )
                Spacer(Modifier.weight(1f))
                Icon(
                    Icons.Outlined.ChevronRight,
                    contentDescription = null,
                    modifier = Modifier.size(Dimens.Space4),
                    tint = SfColors.Outline,
                )
            }
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(usage.percentLabel, fontSize = 10.sp, color = SfColors.Primary)
                Spacer(Modifier.weight(1f))
                ScanStatus(scanFraction = scanFraction, scanDone = scanDone)
            }
        }
    }
}

/**
 * 索引扫描状态：扫描中 = 饼图 + 百分比；完成 = 绿色 ✓「索引已更新」；
 * 未扫描过 = 云端同步样式（稿内原样）。扫描完全在后台线程，前台无阻塞。
 */
@Composable
private fun ScanStatus(scanFraction: Float?, scanDone: Boolean) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Dimens.Space1),
    ) {
        when {
            scanFraction != null -> {
                PieProgress(fraction = scanFraction)
                Text(
                    L10n.t(R.string.s_33e6a5b4e3, ((scanFraction * 100).toInt())),
                    fontSize = 10.sp,
                    color = SfColors.Primary,
                )
            }
            scanDone -> {
                Icon(
                    Icons.Outlined.CheckCircle,
                    contentDescription = L10n.t(R.string.s_0641df6a2d),
                    modifier = Modifier.size(Dimens.Space3),
                    tint = SfColors.Success,
                )
                Text(L10n.t(R.string.s_0641df6a2d), fontSize = 10.sp, color = SfColors.Success)
            }
            else -> {
                Icon(
                    Icons.Outlined.CloudDone,
                    contentDescription = null,
                    modifier = Modifier.size(Dimens.Space3),
                    tint = SfColors.Primary,
                )
                Text(L10n.t(R.string.s_e741e93c58), fontSize = 10.sp, color = SfColors.Primary)
            }
        }
    }
}

/** 小号饼图（12dp）：灰底圆 + 主色扇形，随进度动画增长。 */
@Composable
private fun PieProgress(fraction: Float) {
    val animated by animateFloatAsState(
        targetValue = fraction,
        animationSpec = tween(durationMillis = 250),
        label = "scan-pie",
    )
    // 组合上下文取色（Canvas 绘制 lambda 里不能读 CompositionLocal）
    val trackColor = SfColors.UsageTrack
    val pieColor = SfColors.Primary
    Canvas(modifier = Modifier.size(12.dp)) {
        drawCircle(color = trackColor)
        drawArc(
            color = pieColor,
            startAngle = -90f,
            sweepAngle = 360f * animated,
            useCenter = true,
        )
    }
}

/** 三段式用量条：轨道 + 已用部分按段权重填充，段间缝隙露出轨道色（稿中 3px 间距）。 */
@Composable
private fun UsageBar(fraction: Float, segments: List<UsageSegment>) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(UsageBarHeight)
            .clip(CircleShape)
            .background(SfColors.UsageTrack),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(fraction).fillMaxHeight().clip(CircleShape),
            horizontalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            segments.forEach { segment ->
                Box(Modifier.weight(segment.weight).fillMaxHeight().background(segment.color))
            }
        }
    }
}

// ---- 分区标题 ----

@Composable
private fun SectionHeader(
    title: String,
    action: String? = null,
    onActionClick: (() -> Unit)? = null,
) {
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(title, fontSize = 17.sp, fontWeight = FontWeight.Bold, color = SfColors.OnSurface)
        Spacer(Modifier.weight(1f))
        if (action != null && onActionClick != null) {
            // 触控合同：热区 ≥40dp（裸文字仅 ~17dp，实测多次点不中）；
            // 主色表明可点——弱化色曾被误认为纯标签（「管理看起来没作用」）
            Text(
                action,
                fontSize = 12.sp,
                color = SfColors.Primary,
                modifier = Modifier
                    .clip(RoundedCornerShape(Dimens.RadiusPill))
                    .clickable(onClick = onActionClick)
                    .padding(horizontal = Dimens.Space3, vertical = Dimens.Space1),
            )
        }
    }
}

// ---- 我的文件夹：横排三卡（稿中卡间距 10 → snap Space2） ----

/** 本地根目录入口卡（固定两张：本地存储 / 应用存储）。 */
@Composable
private fun RootCard(
    name: String,
    subtitle: String,
    icon: ImageVector,
    tint: Color,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    Surface(
        onClick = onClick,
        modifier = modifier.heightIn(min = FolderCardHeight),
        shape = RoundedCornerShape(Dimens.RadiusM),
        color = SfColors.SurfaceCard,
    ) {
        Column(
            modifier = Modifier.padding(Dimens.Space3),
            verticalArrangement = Arrangement.spacedBy(Dimens.Space2),
        ) {
            Icon(icon, contentDescription = null, tint = tint)
            Column(verticalArrangement = Arrangement.spacedBy(Dimens.Space1)) {
                Text(
                    name,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Medium,
                    color = SfColors.OnSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    subtitle,
                    fontSize = 9.sp,
                    color = SfColors.OnSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

/** 网络存储列表行：协议图标 + 名称/连接状态 + chevron；左滑或长按可移除连接。 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun NetworkMountRow(
    mount: com.superfiles.app.NetworkMountStatus,
    onClick: () -> Unit,
    onDeleteRequest: () -> Unit,
) {
    val online = mount.rootId != null
    val haptics = LocalHapticFeedback.current
    SwipeRevealRow(
        onDelete = onDeleteRequest,
        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = Dimens.Space4),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .combinedClickable(
                    onClick = onClick,
                    onLongClick = {
                        haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                        onDeleteRequest()
                    },
                )
                .padding(vertical = Dimens.Space3),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Dimens.Space3),
        ) {
            Icon(networkProtocolIcon(mount.config.protocol), contentDescription = null, tint = SfColors.Primary)
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text(
                    mount.config.name,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium,
                    color = SfColors.OnSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    if (online) {
                        L10n.t(R.string.s_c3ca1bad89, (mount.config.protocol.uppercase()))
                    } else {
                        L10n.t(R.string.s_0f537842f6, (mount.config.protocol.uppercase()))
                    },
                    fontSize = 11.sp,
                    color = if (online) SfColors.Success else SfColors.Error,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Icon(
                Icons.Outlined.ChevronRight,
                contentDescription = null,
                modifier = Modifier.size(Dimens.Space4),
                tint = SfColors.Outline,
            )
        }
    }
}

@Composable
private fun FolderCardsRow(cards: List<FolderCardData>) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(Dimens.Space2),
    ) {
        cards.forEach { card ->
            Surface(
                onClick = card.onClick,
                // 高度下限对齐稿中 94dp；内容超高时自适应，避免 CJK 行高裁切
                modifier = Modifier.weight(1f).heightIn(min = FolderCardHeight),
                shape = RoundedCornerShape(Dimens.RadiusM),
                color = SfColors.SurfaceCard,
            ) {
                Column(
                    modifier = Modifier.padding(Dimens.Space3),
                    verticalArrangement = Arrangement.spacedBy(Dimens.Space2),
                ) {
                    Icon(card.icon, contentDescription = null, tint = card.tint)
                    Column(verticalArrangement = Arrangement.spacedBy(Dimens.Space1)) {
                        Text(
                            card.name,
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Medium,
                            color = SfColors.OnSurface,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Text(
                            card.subtitle,
                            fontSize = 9.sp,
                            color = SfColors.OnSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
        }
    }
}

// ---- 最近打开：真实数据（索引 recent_opens 表），与浏览/筛选页同款 FileListRow ----

/** 最近打开的多选状态（首页局部，不干扰文件浏览页的批量选择）。 */
private class RecentSelectionState {
    var mode by mutableStateOf(false)
    var ids by mutableStateOf<Set<String>>(emptySet())

    fun enter(id: String) {
        mode = true
        ids = setOf(id)
    }

    fun toggle(id: String) {
        val next = if (id in ids) ids - id else ids + id
        ids = next
        mode = next.isNotEmpty()
    }

    fun add(id: String) {
        if (id !in ids) {
            ids = ids + id
            mode = true
        }
    }

    fun selectAll(all: List<String>) {
        ids = all.toSet()
        mode = ids.isNotEmpty()
    }

    fun clear() {
        mode = false
        ids = emptySet()
    }
}

@Composable
private fun RecentFilesColumn(
    recent: List<RecentOpen>,
    onOpenRecent: (RecentOpen) -> Unit,
    onRecentActions: (RecentOpen) -> Unit,
    onDeleteEntry: (Entry) -> Unit,
    selection: RecentSelectionState,
    dragTracker: DragSelectTracker,
) {
    if (recent.isEmpty()) {
        Text(
            L10n.t(R.string.s_63e36b5dda),
            fontSize = 12.sp,
            color = SfColors.OnSurfaceVariant,
            modifier = Modifier.padding(vertical = Dimens.Space2),
        )
        return
    }
    ListSectionCard {
        recent.forEachIndexed { index, item ->
            val selected = item.entry.id in selection.ids
            SwipeRevealRow(
                onDelete = { onDeleteEntry(item.entry) },
                contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = Dimens.Space4),
                enabled = !selection.mode,
            ) {
                FileListRow(
                    badge = fileBadgeOf(item.entry),
                    name = item.entry.name,
                    meta = "${formatSize(item.entry.size.toLong())} · ${relativeTime(item.openedMs.toLong())}",
                    selected = selected,
                    modifier = Modifier.dragSelectable(
                        id = item.entry.id,
                        tracker = dragTracker,
                    ) { selection.add(it) },
                    onClick = {
                        if (selection.mode) selection.toggle(item.entry.id) else onOpenRecent(item)
                    },
                    onLongClick = {
                        if (!selection.mode) selection.enter(item.entry.id)
                    },
                    leading = {
                        if (selection.mode) SelectionCircle(selected)
                    },
                    trailing = {
                        if (!selection.mode) {
                            CompactIconButton(
                                Icons.Outlined.MoreHoriz,
                                L10n.t(R.string.s_fff96edebc),
                                tint = SfColors.Outline,
                                onClick = { onRecentActions(item) },
                            )
                        }
                    },
                )
            }
            if (index < recent.lastIndex) RowDivider()
        }
    }
}

// ---- 列表区块容器（网络存储/收藏/最近打开共用）：单卡 + 行间分隔线 ----

/** 最近打开的多选操作条：已选数 + 全选 + 分享 + 退出。 */
@Composable
private fun RecentSelectionBar(
    count: Int,
    onSelectAll: () -> Unit,
    onShare: () -> Unit,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(Dimens.RadiusM),
        color = SfColors.SurfaceCard,
        shadowElevation = 8.dp,
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = Dimens.Space4, vertical = Dimens.Space2),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Dimens.Space2),
        ) {
            Text(
                L10n.t(R.string.s_1e06ae0e46, (count)),
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium,
                color = SfColors.OnSurface,
            )
            Spacer(Modifier.weight(1f))
            TextButton(onClick = onSelectAll) {
                Text(L10n.t(R.string.s_66eeacd93a), fontSize = 13.sp, color = SfColors.OnSurfaceVariant)
            }
            PrimaryConfirmButton(L10n.t(R.string.s_c31f48f84e), enabled = count > 0, onClick = onShare)
            CompactIconButton(Icons.Outlined.Close, L10n.t(R.string.s_6be27193bc), onClick = onCancel)
        }
    }
}

/** 行列表统一容器：RadiusM 白卡把一组行「圈」成一块，替代裸行直接落在页面底色上。 */
@Composable
/** 打开时间的人话格式：今天/昨天 HH:mm，更早 M月d日 HH:mm，跨年补年份。 */
private fun relativeTime(ms: Long): String {
    val t = Instant.ofEpochMilli(ms).atZone(ZoneId.systemDefault())
    val day = t.toLocalDate()
    val today = LocalDate.now()
    val hhmm = DateTimeFormatter.ofPattern("HH:mm", Locale.getDefault()).format(t)
    return when {
        day == today -> L10n.t(R.string.s_65a77ef0bb, (hhmm))
        day == today.minusDays(1) -> L10n.t(R.string.s_45691b0845, (hhmm))
        day.year == today.year -> L10n.t(R.string.s_3ac5d3ef72, (day.monthValue), (day.dayOfMonth), (hhmm))
        else -> "${day.year}/${day.monthValue}/${day.dayOfMonth} $hhmm"
    }
}

@Preview(showBackground = true, name = "手机 · Figma 402", widthDp = 402, heightDp = 900, backgroundColor = 0xFFF8F7F4)
@Preview(showBackground = true, name = "折叠外屏 280", widthDp = 280, heightDp = 640, backgroundColor = 0xFFF8F7F4)
@Preview(showBackground = true, name = "横屏手机 800×360（双列）", widthDp = 800, heightDp = 360, backgroundColor = 0xFFF8F7F4)
@Preview(showBackground = true, name = "平板 840（双列限宽）", widthDp = 840, heightDp = 900, backgroundColor = 0xFFF8F7F4, fontScale = 1.3f)
@Preview(
    showBackground = true,
    name = "手机 · 深色",
    widthDp = 402,
    heightDp = 900,
    backgroundColor = 0xFF1A1916,
    uiMode = android.content.res.Configuration.UI_MODE_NIGHT_YES,
)
@Composable
private fun HomeScreenPreview() {
    SuperFilesTheme { HomeScreen() }
}
