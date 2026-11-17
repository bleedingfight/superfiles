package com.superfiles.app

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.superfiles.core.Capabilities
import com.superfiles.core.ConflictPolicy
import com.superfiles.core.Entry
import com.superfiles.core.EntryKind
import com.superfiles.core.FavoriteEntry
import com.superfiles.core.IndexProgressListener
import com.superfiles.core.PendingTransfer
import com.superfiles.app.search.LiteralQueryParser
import com.superfiles.app.search.NaturalLanguageQueryParser
import com.superfiles.app.search.QueryParser
import com.superfiles.app.search.SearchContext
import com.superfiles.app.search.SearchQuery
import com.superfiles.app.search.SortMode
import com.superfiles.core.RecentOpen
import com.superfiles.app.security.KeystoreCrypto
import com.superfiles.app.ui.isPreviewable
import com.superfiles.app.ui.openFileDefault
import com.superfiles.core.SfException
import com.superfiles.core.SuperFiles
import com.superfiles.core.TransferSnapshot
import com.superfiles.core.TransferState
import com.superfiles.core.ZipMethod
import com.superfiles.core.ZipProgressListener
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

/** 首页 5 类聚合的定义（扩展名与鸿蒙端保持一致）。 */
private val CATEGORY_DEFS: List<Triple<String, Int, Set<String>>> = listOf(
    Triple(
        "image", R.string.s_cat_image,
        setOf(
            "jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "bmp",
            "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "raw",
        ),
    ),
    Triple(
        "video", R.string.s_cat_video,
        setOf("mp4", "mkv", "mov", "webm", "m4v", "avi", "ts", "3gp", "wmv", "flv"),
    ),
    Triple(
        "doc", R.string.s_cat_doc,
        setOf("pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "md", "txt", "csv", "epub"),
    ),
    Triple(
        "audio", R.string.s_cat_audio,
        setOf("mp3", "flac", "wav", "aac", "ogg", "m4a", "wma", "ape"),
    ),
    Triple(
        "archive", R.string.s_cat_archive,
        setOf("zip", "rar", "7z", "tar", "gz", "bz2", "xz", "tgz"),
    ),
)


    /** 近邻传输收发条目：「已接收」清单 + 传输中心「近邻传输」分组共用。 */
    data class LocalSendReceived(
        val name: String,
        val sizeBytes: Long,
        val atMs: Long,
        /** true=收到 / false=发出（发出项仅进传输中心的近邻分组）。 */
        val incoming: Boolean = true,
        val peer: String? = null,
        /**
         * 单调递增序号（仅内存态，不持久化）：同刻同名条目 name/atMs/size 可能全部
         * 相同，列表 key 与「左滑移除单条」靠它精确定位，不会误伤兄弟条目。
         */
        val seq: Long = nextSeq++,
    ) {
        companion object {
            private var nextSeq = 0L
        }
    }

data class BrowserState(
    val rootId: String = "",
    val currentId: String = "",
    val title: String = "",
    val entries: List<Entry> = emptyList(),
    /** 搜索结果/类型筛选结果的显示位置（IO 线程预计算）。 */
    /**
     * 结果行「所在位置」解析器：只对可见行求值。上万条筛选结果不预先算路径，
     * 否则一次点击要额外花上百毫秒。
     */
    val locationProvider: ((Entry) -> String)? = null,
    val capabilities: Capabilities? = null,
    val canGoUp: Boolean = false,
    val loading: Boolean = false,
    val error: String? = null,
    val indexedCount: Long = 0,
    val searchQuery: String = "",
    /** 类型筛选（首页文件夹卡）：非空时 entries 为全树按扩展名过滤的结果。 */
    val filterLabel: String? = null,
    val filterExts: Set<String> = emptySet(),
    /** 一次性信号：请求搜索框获取焦点并弹出键盘（首页搜索入口 → 文件 Tab）。 */
    val searchFocusRequest: Boolean = false,
    /** 轻提示（Snackbar）：操作成功反馈。 */
    val notice: String? = null,
    /** 压缩进度（null = 空闲）。 */
    val compress: CompressState? = null,
    /** 文件详情弹窗内容（null = 关闭）。 */
    val details: EntryDetails? = null,
    /** 文档预览页（PDF 应用内渲染；doc/xls/ppt 系为占位页 + 外部打开入口；null = 关闭）。 */
    val docPreview: Entry? = null,
    /** 从首页进入文件页时的落脚目录；返回时直接回首页，而不是逐级上跳。 */
    val homeEntryRoot: String? = null,
    /** 首页分类聚合的实时数量（来自索引）。 */
    val categoryStats: List<CategoryStat> = emptyList(),
    /** 索引管理页：本地存储 + 已挂载网络存储的索引状态。 */
    val indexTargets: List<IndexTarget> = emptyList(),
    /** 当前正在建立索引的存储名（首页只显示百分比，索引管理页显示名字）。 */
    val scanLabel: String? = null,
    /** 当前扫描任务的根 id（索引管理页用它把进度标到对应存储行上）。 */
    val scanTargetId: String? = null,
    /** 最近打开（首页「最近打开」数据源，按打开时间倒序）。 */
    val recent: List<RecentOpen> = emptyList(),
    /** 「⋯」操作面板的目标（null = 关闭；任何页面共用同一套菜单）。 */
    val actionsTarget: Entry? = null,
    /** 当前浏览的存储根：应用沙盒 / 内部共享存储（全盘授权后可用）。 */
    val rootKind: BrowserRoot = BrowserRoot.AppStorage,
    /** 显示隐藏文件（. 开头默认隐藏；设置持久化在 SharedPreferences）。 */
    val showHidden: Boolean = false,
    /** 后台索引扫描进度（0..1；null = 未在扫描）。 */
    val scanFraction: Float? = null,
    /** 本轮生命周期内是否完成过扫描（完成后展示绿色 ✓）。 */
    val scanDone: Boolean = false,
    /** 已配置的网络存储连接（开机自动重连，点击进浏览）。 */
    val networkMounts: List<NetworkMountStatus> = emptyList(),
    /** 收藏（快捷访问标记，跨根合并）。 */
    val favorites: List<FavoriteEntry> = emptyList(),
    /** 收藏条目的显示位置：在 IO 线程预计算，Compose 里不再调用 FFI。 */
    val favoriteLocations: Map<String, String> = emptyMap(),
    val favoriteIds: Set<String> = emptySet(),
    val isCurrentFavorite: Boolean = false,
    /** 索引位置订阅。 */
    val indexPins: List<IndexPin> = emptyList(),
    /** 传输任务（引擎在 Rust runtime 中独立执行，UI 只做展示/控制）。 */
    val transfers: List<TransferSnapshot> = emptyList(),
    /** 实时速度（transferId → bytes/s；轮询差值 + EMA 平滑，仅 RUNNING 有值）。 */
    val transferRates: Map<String, Long> = emptyMap(),
    /**
     * 前台传输：复制/移动刚开始时只在 App 内显示进度浮层（带「终止 / 后台传输」），
     * 用户点「后台传输」（或 App 退到后台）后才进入传输中心 + 通知栏。
     */
    val foregroundTransfers: Set<String> = emptySet(),
    /** 上述任务里属于「移动」的 id（浮层标题显示 正在移动 vs 正在复制）。 */
    val foregroundMoves: Set<String> = emptySet(),
    /** 目录列举缓存刷新计数（选择器用它触发「缓存秒开 → 实时结果替换」）。 */
    val dirTick: Int = 0,
    /** 进程被杀后遗留的可恢复传输。 */
    val resumable: List<PendingTransfer> = emptyList(),
    /** 离线缓存标记：非空 = 当前列表来自索引缓存（实时列举失败），值为上次更新时间(epoch ms)。 */
    val offlineCacheMs: Long? = null,
    /** 多选模式（长按进入；返回键/清空退出）。 */
    val selectionMode: Boolean = false,
    val selectedIds: Set<String> = emptySet(),
    /** 复制/移动同名冲突的待决确认（null = 无待决项）。 */
    val conflictPrompt: ConflictPrompt? = null,
    /** 进行中的就近分享（null = 未分享；关闭它的 UI 时须调用 stopShare）。 */
    val shareInfo: com.superfiles.core.ShareInfo? = null,
    /** 收到的分享清单，等待用户确认下载（null = 无）。 */
    val incomingShare: ShareManifest? = null,
    /** 接收进度（null = 空闲）。 */
    val receive: ReceiveState? = null,
    /** 本地用户资料（问候语/头像使用）。 */
    val userNickname: String = L10n.t(R.string.s_0ed27cbb38),
    val userAvatarChar: String = L10n.t(R.string.s_d9d28cb2a0),
    /** LocalSend 近邻传输：运行状态、本机信息、发现的设备。 */
    val localSendRunning: Boolean = false,
    val localSendInfo: com.superfiles.core.LocalSendInfo? = null,
    val localSendPeers: List<com.superfiles.core.LocalSendPeer> = emptyList(),
    /** 近邻传输「已接收」清单（最新在前，会话内有效；行点击直达目录）。 */
    val localSendReceived: List<LocalSendReceived> = emptyList(),
    /** 近邻传输收发流水（传输中心「近邻传输」分组，含发出方向与对端名）。 */
    val localSendRecords: List<LocalSendReceived> = emptyList(),
    /** 无传输活动自动关闭（秒，0=永不）。 */
    val localSendIdleSecs: Long = 300L,
    val localSendErrors: List<String> = emptyList(),
    /** 最近一次发送失败原因（null = 无；用于发送面板内联展示）。 */
    val localSendSendError: String? = null,
    /** 开启近邻传输失败原因（null = 无）。 */
    val localSendStartError: String? = null,
    /** 实际接收目录（绝对路径；开启时确定，供 UI 展示/跳转）。 */
    val localSendDest: String = "",
    /** 接收位置的展示名（网络挂载时是连接名/目录名）。 */
    val localSendDestName: String = "",
    /** 系统分享导入进度（null = 空闲）。 */
    val shareImport: ShareImportState? = null,
    val localSendBusy: Boolean = false,
)

/** 可浏览的存储根。 */
enum class BrowserRoot { AppStorage, SharedStorage, System, Network }

/** 网络存储连接配置（持久化在 SharedPreferences；密码明文存储，M2 换 EncryptedSharedPreferences）。 */
data class NetworkMountConfig(
    val name: String,
    val protocol: String, // webdav / smb / sftp
    val host: String,
    val port: Int = 0,
    val share: String = "",
    val username: String = "",
    val password: String = "",
    /** S3 专用：region / 路径寻址 / 临时会话 token。 */
    val region: String = "",
    val pathStyle: Boolean = false,
    val sessionToken: String = "",
)

/** 一条网络存储的运行时状态。 */
data class NetworkMountStatus(
    val config: NetworkMountConfig,
    val rootId: String? = null,
    val error: String? = null,
)

/** 局域网扫描发现的 SMB 主机；shares 为空表示需凭据。 */
data class SmbHostInfo(val name: String, val host: String, val shares: List<String>)

/** 索引管理页的一行：一个存储（本地或网络挂载）及其索引状态。 */
data class IndexTarget(
    val id: String,
    val name: String,
    val kind: String,
    val entries: Long,
    val isLocal: Boolean,
    val mount: NetworkMountStatus? = null,
) {
    val indexed: Boolean get() = entries > 0
}

/** 存储清理项：应用存储下的一级文件/目录，按大小降序展示。 */
/** 首页分类聚合：图片/视频/文档/音频/压缩包。 */
data class CategoryStat(
    val key: String,
    val label: String,
    val exts: Set<String>,
    val count: Long,
)

data class CleanupItem(
    val path: String,
    val name: String,
    val size: Long,
    val isDir: Boolean,
)

/** 复制/移动的统一目标节点（根列表或子目录）。 */
data class DestNode(
    val id: String,
    val name: String,
    val subtitle: String,
)

/** 索引位置（用户显式授权的索引订阅，扫码成本由用户判断）。 */
data class IndexPin(
    val id: String,
    val name: String,
    val addedMs: Long,
    val entries: Long = -1,
    val lastScanMs: Long = 0,
)

/** 压缩进度（源字节消耗口径）。 */
data class CompressState(val done: Long, val total: Long)

/** 从系统分享面板导入文件的进度。 */
data class ShareImportState(val done: Int, val total: Int, val destName: String)

/** 一次同名冲突确认（批量复制/移动时 index/total 标记「第 N/M 项」，见 design/screens.md §2）。 */
data class ConflictPrompt(
    val name: String,
    val index: Int,
    val total: Int,
)

/** 接收方视角的分享清单条目（ADR 0005 manifest.json）。 */
data class ShareFileMeta(
    val name: String,
    val size: Long,
    val relUrl: String,
)

/** 待用户确认的分享（「接收文件」对话框第二步）。 */
data class ShareManifest(
    val baseUrl: String,
    val files: List<ShareFileMeta>,
)

/** 接收进度（null = 空闲；与 CompressState 同款的源字节/文件双口径）。 */
data class ReceiveState(
    val filesDone: Int = 0,
    val filesTotal: Int,
    val bytesDone: Long = 0,
    val bytesTotal: Long,
    val currentName: String = "",
)

/** 详情弹窗：Entry + 真实磁盘路径。 */
data class EntryDetails(val entry: Entry, val path: String)

/**
 * M0 view model: browse the app private storage through the Rust core.
 *
 * Every core call is blocking by design (see `crates/sfiles-ffi`), so it is
 * dispatched to `Dispatchers.IO`; the UI thread never touches the core.
 */
class VfsViewModel(application: Application) : AndroidViewModel(application) {

    private val appCore: SuperFiles = run {
        val root = File(application.filesDir, "storage").apply { mkdirs() }
        val index = File(application.filesDir, "index.sqlite")
        SuperFiles.open(root.absolutePath, index.absolutePath)
    }

    /** 共享存储根（懒创建；需要 MANAGE_EXTERNAL_STORAGE 授权）。 */
    private var sharedCore: SuperFiles? = null

    /** 全盘根 `/`：供路径栏直达任意绝对路径（权限不足的目录会在访问时报错）。 */
    private var systemCore: SuperFiles? = null

    private var core: SuperFiles = appCore

    /** LocalSend 近邻传输句柄/轮询/组播锁。 */
    private var localSendHandle: com.superfiles.core.LocalSendHandle? = null
    private var localSendPollJob: kotlinx.coroutines.Job? = null
    private var localSendMulticastLock: android.net.wifi.WifiManager.MulticastLock? = null
    private var localSendLastFileCount: Int = -1
    /** 接收到账对账：上轮接收目录内容的名字集合 + 是否已建立基线。 */
    private val localSendSeenNames: MutableSet<String> = mutableSetOf()
    private var localSendBaselineReady = false

    private val prefs =
        application.getSharedPreferences("ui", android.content.Context.MODE_PRIVATE)

    /**
     * 待扫描队列（id + 是否跳过冷却）；去重，按请求顺序串行执行。
     * 必须声明在 `init` 之前：`init` 会调用 [indexAccessibleRoots]。
     */
    private val scanQueue = ArrayDeque<ScanJob>()

    /** 扫描过程中分类计数的刷新节流（避免每个目录都查 5 次 count）。 */
    private var lastCategoryRefreshAt = 0L

    /**
     * 网络存储凭据加密：Android Keystore 托管 AES-256-GCM 密钥（平台原生，无第三方依赖），
     * 密文（iv:密文 base64）写入 SharedPreferences；Keystore 密钥不可导出，
     * 即使 root 拿出 xml 也无法离线解密（换机/重装即失效）。
     */
    /** 老版本明文迁移：明文 network_mounts → 加密 key，随后抹掉明文。 */
    private fun migratePlaintextMounts() {
        val legacy = prefs.getString(KEY_NETWORK_MOUNTS, null) ?: return
        if (prefs.getString(KEY_NETWORK_MOUNTS_ENC, null) == null) {
            runCatching { prefs.edit().putString(KEY_NETWORK_MOUNTS_ENC, KeystoreCrypto.encrypt(legacy)).apply() }
        }
        prefs.edit().remove(KEY_NETWORK_MOUNTS).apply()
    }

    private val _state = MutableStateFlow(
        BrowserState(
            rootId = core.rootId(),
            showHidden = prefs.getBoolean(KEY_SHOW_HIDDEN, false),
            localSendIdleSecs = prefs.getLong(KEY_LS_IDLE_SECS, 300L),
            // 上次生命周期曾完成过扫描 → 冷启动直接展示绿色 ✓
            // （冷却期内本轮不重新扫描，但"已更新"状态应跨启动保留；
            //  兼容旧版本只写过 scan_at_* 冷却键、没有 scan_done 标志的情况）
            scanDone = prefs.getBoolean(KEY_SCAN_DONE, false) ||
                prefs.all.keys.any { it.startsWith("scan_at_") },
            userNickname = prefs.getString(KEY_USER_NICKNAME, null)?.takeIf { it.isNotBlank() } ?: L10n.t(R.string.s_0ed27cbb38),
            userAvatarChar = avatarCharOf(
                prefs.getString(KEY_USER_NICKNAME, null)?.takeIf { it.isNotBlank() } ?: L10n.t(R.string.s_0ed27cbb38),
            ),
        ),
    )
    val state = _state.asStateFlow()

    /** 存储清理：应用存储一级条目（按大小降序）+ 扫描中标志。 */
    private val _cleanupItems = MutableStateFlow<List<CleanupItem>>(emptyList())
    val cleanupItems = _cleanupItems.asStateFlow()
    private val _cleanupScanning = MutableStateFlow(false)
    val cleanupScanning = _cleanupScanning.asStateFlow()
    private val _cleanupPath = MutableStateFlow<String?>(null)
    val cleanupPath = _cleanupPath.asStateFlow()

    /** 隐藏文件过滤：Entry.hidden 或 . 开头都算（含目录）。 */
    private fun visible(entries: List<Entry>): List<Entry> =
        if (_state.value.showHidden) {
            entries
        } else {
            entries.filter { !it.hidden && !it.name.startsWith(".") }
        }

    /** 切换「显示隐藏文件」并持久化，随后刷新当前视图。 */
    fun setShowHidden(show: Boolean) {
        prefs.edit().putBoolean(KEY_SHOW_HIDDEN, show).apply()
        _state.update { it.copy(showHidden = show) }
        refreshCurrent()
        // 分类数量与「显示隐藏文件」开关保持一致（隐藏文件默认不算）。
        refreshCategoryStats()
    }

    private val history = ArrayDeque<String>()

    init {
        // 应用内事件日志（环形文件，随诊断包导出）
        SfLog.init(application)
        SfLog.i("App start; externalStorageManager=${android.os.Environment.isExternalStorageManager()}")
        // LocalSend 组网深链（系统深链 / App 内扫码共用总线）
        viewModelScope.launch {
            LocalSendLinkBus.links.collect { link -> registerFromLocalSendLink(link) }
        }
        // 远端流式 Provider 共享同一个内核实例（挂载都在 appCore 上）
        com.superfiles.app.stream.RemoteFileProvider.appCore = appCore
        migratePlaintextMounts() // 旧版明文凭据 → 加密存储（一次性）
        // 已授权「所有文件访问」时以真实存储根为默认起点（用户视角合理），
        // 否则退回应用沙盒（M0 行为）。
        if (android.os.Environment.isExternalStorageManager()) {
            runCatching {
                SuperFiles.open(
                    android.os.Environment.getExternalStorageDirectory().absolutePath,
                    File(application.filesDir, "index-shared.sqlite").absolutePath,
                )
            }.onSuccess { shared ->
                sharedCore = shared
                core = shared
                _state.update { it.copy(rootKind = BrowserRoot.SharedStorage) }
            }
        }
        load(core.rootId()) // load() 内部会顺带触发一次后台扫描（带冷却）
        loadRecent()
        loadFavorites()
        _state.update { it.copy(indexPins = loadPins()) }
        restoreNetworkMounts()
        // 索引所有程序可访问的本地目录；网络存储只在用户指定后索引。
        indexAccessibleRoots()
        refreshCategoryStats()
        // 云盘 OAuth 授权完成（深链回调 → token 已保存）→ 挂载
        viewModelScope.launch {
            com.superfiles.app.cloud.CloudAuthBus.authDone.collect { providerId ->
                providerId?.let { mountCloudProvider(it) }
            }
        }
        // 云盘授权失败（loopback 回调里的错误）→ 顶部提示
        viewModelScope.launch {
            com.superfiles.app.cloud.CloudAuthBus.authError.collect { message ->
                message?.let {
                    notice(it)
                    com.superfiles.app.cloud.CloudAuthBus.authError.value = null
                }
            }
        }
        startTransferPolling()
        refreshResumable()
        // 网络挂载连上后再刷新索引位置（1s 缓冲，不阻塞启动）
        viewModelScope.launch {
            kotlinx.coroutines.delay(1500)
            refreshIndexPins()
        }
    }

    // ---- 收藏（快捷访问，纯标记零成本） ----

    private fun loadFavorites() {
        viewModelScope.launch {
            val (all, locations) = withContext(Dispatchers.IO) {
                val list = ArrayList<FavoriteEntry>()
                runCatching { appCore.favorites(200u) }.getOrNull()?.let { list += it }
                sharedCore?.let { c -> runCatching { c.favorites(200u) }.getOrNull()?.let { list += it } }
                systemCore?.let { c -> runCatching { c.favorites(200u) }.getOrNull()?.let { list += it } }
                val order = loadFavoriteOrder()
                val rank = order.withIndex().associate { (i, id) -> id to i }
                val sorted = list.distinctBy { it.entry.id }
                    .sortedWith(
                        compareBy<FavoriteEntry> { rank[it.entry.id] ?: Int.MAX_VALUE }
                            .thenByDescending { it.addedMs },
                    )
                // 主线程只读缓存：displayPath 是阻塞 FFI，必须在这里算完。
                sorted to sorted.associate { it.entry.id to locationOf(it.entry) }
            }
            _state.update { s ->
                s.copy(
                    favorites = all,
                    favoriteLocations = locations,
                    favoriteIds = all.map { it.entry.id }.toSet(),
                    isCurrentFavorite = all.any { it.entry.id == s.currentId },
                )
            }
        }
    }

    /** 收藏长按拖动排序：重排内存列表并把 id 顺序落盘。 */
    fun reorderFavorites(from: Int, to: Int) {
        val list = _state.value.favorites.toMutableList()
        if (from !in list.indices || to !in list.indices || from == to) return
        val item = list.removeAt(from)
        list.add(to, item)
        _state.update { it.copy(favorites = list) }
        saveFavoriteOrder(list.map { it.entry.id })
    }

    private fun loadFavoriteOrder(): List<String> = runCatching {
        val raw = prefs.getString("favorite_order", null) ?: return emptyList()
        val arr = org.json.JSONArray(raw)
        (0 until arr.length()).map { arr.getString(it) }
    }.getOrDefault(emptyList())

    private fun saveFavoriteOrder(ids: List<String>) {
        prefs.edit().putString("favorite_order", org.json.JSONArray(ids).toString()).apply()
    }

    fun toggleFavorite(entry: Entry) {
        viewModelScope.launch {
            val path = core.displayPath(entry.id)
            val target = coreForPath(path)?.first ?: core
            val isFav = _state.value.favoriteIds.contains(entry.id)
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    if (isFav) target.removeFavorite(entry.id) else target.addFavorite(entry.id)
                }
            }
            result
                .onSuccess {
                    loadFavorites()
                    isCurrentFavoriteChanged()
                    notice(if (isFav) L10n.t(R.string.s_e05a96855a, (entry.name)) else L10n.t(R.string.s_679109542d, (entry.name)))
                }
                .onFailure(::report)
        }
    }

    /** 路径栏星标：收藏/取消收藏当前所在目录。 */
    fun toggleFavoriteCurrent() {
        viewModelScope.launch {
            val id = _state.value.currentId
            if (id.isEmpty()) return@launch
            val entry = withContext(Dispatchers.IO) { runCatching { core.stat(id) }.getOrNull() }
                ?: return@launch
            toggleFavorite(entry)
        }
    }

    private fun isCurrentFavoriteChanged() {
        _state.update { s -> s.copy(isCurrentFavorite = s.favoriteIds.contains(s.currentId)) }
    }

    // ---- 索引位置（用户显式订阅；启动/手动刷新时增量扫描） ----

    fun addIndexPin(entry: Entry) {
        val pins = loadPins()
        if (pins.any { it.id == entry.id }) {
            notice(L10n.t(R.string.s_0d44e4e64f, (entry.name)))
            return
        }
        savePins(pins + IndexPin(entry.id, entry.name, System.currentTimeMillis()))
        _state.update { it.copy(indexPins = loadPins()) }
        notice(L10n.t(R.string.s_7b91783a93, (entry.name)))
        refreshIndexPins()
    }

    fun removeIndexPin(pin: IndexPin) {
        savePins(loadPins().filterNot { it.id == pin.id })
        _state.update { it.copy(indexPins = loadPins()) }
        notice(L10n.t(R.string.s_235346f3f4, (pin.name)))
    }

    /** 顺序刷新所有索引位置（增量；进度并入首页饼图）。 */
    fun refreshIndexPins() {
        val pins = loadPins()
        if (pins.isEmpty()) return
        viewModelScope.launch {
            _state.update { it.copy(scanFraction = 0f, scanDone = false) }
            for ((idx, pin) in pins.withIndex()) {
                val resolved = coreForPath(core.displayPath(pin.id)) ?: continue
                val target = resolved.first
                val started = System.currentTimeMillis()
                val result = withContext(Dispatchers.IO) {
                    runCatching {
                        target.indexDirWithProgress(
                            pin.id,
                            object : IndexProgressListener {
                                override fun onProgress(directories: ULong, entries: ULong, fraction: Float) {
                                    val overall = (idx + fraction.coerceIn(0f, 1f)) / pins.size
                                    _state.update {
                                        it.copy(scanFraction = overall.coerceIn(0f, 0.99f))
                                    }
                                }

                                override fun onFinished(total: ULong) = Unit
                            },
                        )
                    }
                }
                result.onSuccess { total ->
                    savePins(
                        loadPins().map { p ->
                            if (p.id == pin.id) {
                                p.copy(entries = total.toLong(), lastScanMs = started)
                            } else {
                                p
                            }
                        },
                    )
                }
            }
            _state.update { it.copy(scanFraction = null, scanDone = true, indexPins = loadPins()) }
        }
    }

    private fun loadPins(): List<IndexPin> = runCatching {
        val raw = prefs.getString(KEY_INDEX_PINS, null) ?: return emptyList()
        val arr = org.json.JSONArray(raw)
        (0 until arr.length()).map { i ->
            val o = arr.getJSONObject(i)
            IndexPin(
                id = o.getString("id"),
                name = o.getString("name"),
                addedMs = o.optLong("added"),
                entries = o.optLong("entries", -1),
                lastScanMs = o.optLong("last", 0),
            )
        }
    }.getOrDefault(emptyList())

    private fun savePins(list: List<IndexPin>) {
        val arr = org.json.JSONArray()
        list.forEach { p ->
            arr.put(
                org.json.JSONObject().apply {
                    put("id", p.id)
                    put("name", p.name)
                    put("added", p.addedMs)
                    put("entries", p.entries)
                    put("last", p.lastScanMs)
                },
            )
        }
        prefs.edit().putString(KEY_INDEX_PINS, arr.toString()).apply()
    }

    // ---- 网络存储（WebDAV / SMB / SFTP）：配置持久化 + 启动重连 + 点击浏览 ----

    private fun mountOn(vfsCore: SuperFiles, cfg: NetworkMountConfig): String = when (cfg.protocol) {
        "webdav" -> vfsCore.mountWebdav(cfg.name, cfg.host, cfg.username, cfg.password)
        "smb" -> vfsCore.mountSmb(
            cfg.name,
            cfg.host,
            cfg.share,
            cfg.username,
            cfg.password,
            (cfg.port.takeIf { it > 0 } ?: 445).toUInt(),
        )
        "sftp" -> vfsCore.mountSftp(
            cfg.name,
            cfg.host,
            (cfg.port.takeIf { it > 0 } ?: 22).toUInt(),
            cfg.username,
            cfg.password,
        )
        "gdrive" -> {
            val provider = com.superfiles.app.cloud.CloudProviders.byId("google_drive")
                ?: error("google_drive")
            val client = provider.client ?: error("google_drive not configured")
            val token = com.superfiles.app.cloud.CloudAuthManager.loadToken(getApplication(), "google_drive")
                ?: error("google_drive not authorized")
            vfsCore.mountGoogleDrive(
                cfg.name,
                token.accessToken,
                token.refreshToken ?: "",
                client.clientId,
                client.clientSecret ?: "",
            )
        }
        "dropbox" -> {
            val provider = com.superfiles.app.cloud.CloudProviders.byId("dropbox")
                ?: error("dropbox")
            val client = provider.client ?: error("dropbox not configured")
            val token = com.superfiles.app.cloud.CloudAuthManager.loadToken(getApplication(), "dropbox")
                ?: error("dropbox not authorized")
            vfsCore.mountDropbox(
                cfg.name,
                token.accessToken,
                token.refreshToken ?: "",
                client.clientId,
                client.clientSecret ?: "",
            )
        }
        "onedrive" -> {
            val provider = com.superfiles.app.cloud.CloudProviders.byId("onedrive")
                ?: error("onedrive")
            val client = provider.client ?: error("onedrive not configured")
            val token = com.superfiles.app.cloud.CloudAuthManager.loadToken(getApplication(), "onedrive")
                ?: error("onedrive not authorized")
            vfsCore.mountCloud(
                "onedrive",
                cfg.name,
                token.accessToken,
                token.refreshToken ?: "",
                client.clientId,
                client.clientSecret ?: "",
            )
        }
        "s3" -> vfsCore.mountS3(
            cfg.name,
            cfg.host,
            cfg.region,
            cfg.share,
            cfg.username,
            cfg.password,
            cfg.sessionToken,
            cfg.pathStyle,
        )
        "pan115" -> {
            val provider = com.superfiles.app.cloud.CloudProviders.byId("pan115")
                ?: error("pan115")
            val client = provider.client ?: error("pan115 not configured")
            val token = com.superfiles.app.cloud.CloudAuthManager.loadToken(getApplication(), "pan115")
                ?: error("pan115 not authorized")
            vfsCore.mountCloud(
                "115",
                cfg.name,
                token.accessToken,
                token.refreshToken ?: "",
                client.clientId,
                client.clientSecret ?: "",
            )
        }
        else -> error(L10n.t(R.string.s_fcc1a15a43, (cfg.protocol)))
    }

    /** 启动时把上次保存的连接静默重连（失败保留错误状态，可手动重试）。 */
    private fun restoreNetworkMounts() {
        val configs = loadMountConfigs()
        if (configs.isEmpty()) return
        _state.update { it.copy(networkMounts = dedupeMounts(configs.map { c -> NetworkMountStatus(c) })) }
        viewModelScope.launch {
            val mountCore = openSystem() ?: appCore
            val statuses = withContext(Dispatchers.IO) {
                configs.map { cfg ->
                    runCatching { mountOn(mountCore, cfg) }
                        .fold(
                            onSuccess = { rootId ->
                                SfLog.i("mount restored: ${cfg.name}(${cfg.protocol}) -> $rootId")
                                NetworkMountStatus(cfg, rootId = rootId)
                            },
                            onFailure = {
                                SfLog.e("mount restore failed: ${cfg.name}(${cfg.protocol})", it)
                                NetworkMountStatus(cfg, error = friendlyError(it))
                            },
                        )
                }
            }
            _state.update { it.copy(networkMounts = dedupeMounts(statuses)) }
            // 网络/系统根的收藏行存在 systemCore 的索引里，而 init 里
            // loadFavorites() 早于挂载恢复（当时 systemCore 可能还没打开）。
            // 挂载连上后必须重载一次，否则重启后首页收藏里看不到它们。
            loadFavorites()
        }
    }

    /** `onResult(ok, 错误文案)`：失败原因回传给表单内联展示（Snackbar 会被弹层遮挡）。 */
    /**
     * 局域网自动发现 SMB：探测本机 /24 网段 445 端口 → 对在线主机尝试匿名枚举共享。
     * 结果供 UI 一键连接（匿名可用的直接挂载；需凭据的带到表单预填）。
     */
    fun scanLanSmb(onResult: (List<SmbHostInfo>?, String?) -> Unit) {
        viewModelScope.launch {
            val local = withContext(Dispatchers.IO) { localIpv4() }
            if (local == null) {
                onResult(null, L10n.t(R.string.s_f60eff0e7b))
                return@launch
            }
            val prefix = local.substringBeforeLast('.')
            val candidates = (1..254).map { "$prefix.$it" }.filterNot { it == local }
            val reachable = withContext(Dispatchers.IO) {
                coroutineScope {
                    candidates
                        .map { h ->
                            async(Dispatchers.IO) {
                                if (portOpen(h, 445, 300)) h else null
                            }
                        }
                        .awaitAll()
                }.filterNotNull()
            }
            val results = withContext(Dispatchers.IO) {
                reachable.map { h ->
                    // NetBIOS 主机名（NBNS UDP 137）；拿不到再兜底，IP 在行下方单独展示
                    val name = runCatching { appCore.smbNetbiosName(h) }.getOrNull() ?: "SMB 服务器"
                    val shares = runCatching {
                        withTimeout(6000) {
                            appCore.smbListShares(h, 445u, "", "")
                        }
                    }.getOrNull()
                    SmbHostInfo(name, h, shares ?: emptyList())
                }
            }
            onResult(
                results,
                if (results.isEmpty()) {
                    L10n.t(R.string.s_546968fec2)
                } else {
                    null
                },
            )
        }
    }

    private fun localIpv4(): String? = runCatching {
        java.net.NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback }
            .flatMap { it.inetAddresses.toList() }
            .filterIsInstance<java.net.Inet4Address>()
            .firstOrNull { !it.isLoopbackAddress && !it.isLinkLocalAddress }
            ?.hostAddress
    }.getOrNull()

    private fun portOpen(host: String, port: Int, timeoutMs: Int): Boolean = runCatching {
        java.net.Socket().use { it.connect(java.net.InetSocketAddress(host, port), timeoutMs) }
        true
    }.getOrDefault(false)

    /** 该主机上次成功使用的共享名（Samba 无法枚举时的贴心预填）。 */
    fun lastShareFor(host: String): String? = loadShareHistory()[host]

    private fun recordShareHistory(host: String, share: String) {
        val map = loadShareHistory().toMutableMap()
        map[host] = share
        val obj = org.json.JSONObject()
        map.forEach { (h, s) -> obj.put(h, s) }
        prefs.edit().putString(KEY_SMB_SHARE_HISTORY, obj.toString()).apply()
    }

    private fun loadShareHistory(): Map<String, String> = runCatching {
        val raw = prefs.getString(KEY_SMB_SHARE_HISTORY, null) ?: return emptyMap()
        val obj = org.json.JSONObject(raw)
        obj.keys().asSequence().associateWith { obj.getString(it) }
    }.getOrDefault(emptyMap())

    /** SMB 枚举共享（UI「列出共享」）：成功返回共享名列表，失败回传人话错误。 */
    fun listSmbShares(
        host: String,
        port: Int,
        username: String,
        password: String,
        onResult: (List<String>?, String?) -> Unit,
    ) {
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    appCore.smbListShares(
                        host,
                        (port.takeIf { it > 0 } ?: 445).toUInt(),
                        username,
                        password,
                    )
                }
            }
            result
                .onSuccess { onResult(it, null) }
                .onFailure {
                    android.util.Log.e("SuperFiles", "smb list shares failed", it)
                    onResult(null, friendlyError(it))
                }
        }
    }

    fun addNetworkMount(cfg: NetworkMountConfig, onResult: (Boolean, String?) -> Unit) {
        viewModelScope.launch {
            // SMB 预检：端口 TCP 可达性（比内核的 "Transport error" 更早、更可解释）
            if (cfg.protocol == "smb") {
                val smbPort = cfg.port.takeIf { it > 0 } ?: 445
                val reachable = withContext(Dispatchers.IO) {
                    runCatching {
                        java.net.Socket().use { socket ->
                            socket.connect(java.net.InetSocketAddress(cfg.host, smbPort), 3000)
                        }
                        true
                    }.getOrDefault(false)
                }
                if (!reachable) {
                    onResult(
                        false,
                        L10n.t(R.string.s_7f990ecdab, (cfg.host), (smbPort)),
                    )
                    return@launch
                }
            }
            val mountCore = openSystem() ?: appCore
            val result = withContext(Dispatchers.IO) { runCatching { mountOn(mountCore, cfg) } }
            result
                .onSuccess { rootId ->
                    saveMountConfigs(
                        loadMountConfigs().filterNot { it.name == cfg.name } + cfg,
                    )
                    if (cfg.protocol == "smb" && cfg.share.isNotBlank()) {
                        recordShareHistory(cfg.host, cfg.share)
                    }
                    _state.update { s ->
                        s.copy(
                            networkMounts = dedupeMounts(
                                s.networkMounts.filterNot { it.config.name == cfg.name } +
                                    NetworkMountStatus(cfg, rootId = rootId),
                            ),
                        )
                    }
                    notice(L10n.t(R.string.s_b4d8424037, (cfg.name)))
                    onResult(true, null)
                }
                .onFailure {
                    android.util.Log.e("SuperFiles", "mount failed", it)
                    onResult(false, friendlyError(it))
                }
        }
    }

    /** 云盘 OAuth 授权完成后的挂载：从 CloudAuthManager 读 token，构造配置并挂载。 */
    private fun mountCloudProvider(providerId: String) {
        val provider = com.superfiles.app.cloud.CloudProviders.byId(providerId) ?: return
        val protocol = when (providerId) {
            "google_drive" -> "gdrive"
            "dropbox" -> "dropbox"
            "onedrive" -> "onedrive"
            "pan115" -> "pan115"
            else -> return
        }
        val cfg = NetworkMountConfig(
            name = L10n.t(provider.displayNameRes),
            protocol = protocol,
            host = providerId,
        )
        addNetworkMount(cfg) { ok, err ->
            if (!ok) notice(err ?: "cloud mount failed")
        }
    }

    /**
     * 重命名网络存储（所有协议）：改配置 → 卸载旧挂载 → 以新名字重挂载。
     * 注意：挂载根 id 含名字，重命名后旧的收藏/索引位置引用会失效（重新添加即可）。
     */
    fun renameMount(status: NetworkMountStatus, newName: String) {
        val name = newName.trim()
        if (name.isEmpty() || name == status.config.name) return
        val old = status.config
        val updated = old.copy(name = name)
        viewModelScope.launch {
            val mountCore = openSystem() ?: appCore
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    status.rootId?.let { runCatching { mountCore.unmount(it) } }
                    mountOn(mountCore, updated)
                }
            }
            result
                .onSuccess { rootId ->
                    saveMountConfigs(loadMountConfigs().map { if (it.name == old.name) updated else it })
                    _state.update { s ->
                        s.copy(
                            networkMounts = s.networkMounts.map {
                                if (it.config.name == old.name) NetworkMountStatus(updated, rootId) else it
                            },
                        )
                    }
                    notice(L10n.t(R.string.s_f4f64b6654, (name)))
                }
                .onFailure { notice(L10n.t(R.string.s_0997a3c67f, (friendlyError(it)))) }
        }
    }

    /**
     * 编辑网络存储（名称/地址/凭据）：卸载旧挂载 → 以新配置重挂载并持久化。
     * 正在浏览该连接时，编辑成功后自动跟随到新的挂载根。
     */
    fun updateNetworkMount(
        status: NetworkMountStatus,
        cfg: NetworkMountConfig,
        onResult: (Boolean, String?) -> Unit,
    ) {
        val oldName = status.config.name
        val oldRoot = status.rootId
        viewModelScope.launch {
            val mountCore = openSystem() ?: appCore
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    oldRoot?.let { runCatching { mountCore.unmount(it) } }
                    mountOn(mountCore, cfg)
                }
            }
            result
                .onSuccess { rootId ->
                    saveMountConfigs(loadMountConfigs().map { if (it.name == oldName) cfg else it })
                    if (cfg.protocol == "smb" && cfg.share.isNotBlank()) {
                        recordShareHistory(cfg.host, cfg.share)
                    }
                    _state.update { s ->
                        s.copy(
                            networkMounts = s.networkMounts.map {
                                if (it.config.name == oldName) NetworkMountStatus(cfg, rootId) else it
                            },
                        )
                    }
                    val current = _state.value.currentId
                    if (oldRoot != null && (current == oldRoot || current.startsWith("$oldRoot/"))) {
                        history.clear()
                        load(rootId)
                    }
                    notice(L10n.t(R.string.s_6a62bcae24, (cfg.name)))
                    onResult(true, null)
                }
                .onFailure { err ->
                    SfLog.e("update mount failed: ${cfg.name}", err)
                    // 编辑失败：尽量恢复旧连接，避免原挂载被卸载后从列表消失
                    val restored = oldRoot?.let {
                        withContext(Dispatchers.IO) {
                            runCatching { mountOn(mountCore, status.config) }.getOrNull()
                        }
                    }
                    _state.update { s ->
                        s.copy(
                            networkMounts = s.networkMounts.map {
                                if (it.config.name == oldName) {
                                    if (restored != null) {
                                        NetworkMountStatus(status.config, restored)
                                    } else {
                                        NetworkMountStatus(status.config, error = friendlyError(err))
                                    }
                                } else {
                                    it
                                }
                            },
                        )
                    }
                    if (restored != null) {
                        oldRoot?.let { previous ->
                            val current = _state.value.currentId
                            if (current == previous || current.startsWith("$previous/")) {
                                history.clear()
                                load(restored)
                            }
                        }
                    }
                    onResult(false, friendlyError(err))
                }
        }
    }

    /** 长按拖动排序：重排内存列表并持久化（启动重连按此顺序）。 */
    fun reorderNetworkMounts(from: Int, to: Int) {
        val list = _state.value.networkMounts.toMutableList()
        if (from !in list.indices || to !in list.indices || from == to) return
        val item = list.removeAt(from)
        list.add(to, item)
        _state.update { it.copy(networkMounts = list) }
        saveMountConfigs(list.map { it.config })
    }

    fun removeNetworkMount(status: NetworkMountStatus) {
        val mountCore = systemCore ?: appCore
        status.rootId?.let { rootId -> runCatching { mountCore.unmount(rootId) } }
        saveMountConfigs(loadMountConfigs().filterNot { it.name == status.config.name })
        _state.update { s ->
            s.copy(networkMounts = s.networkMounts.filterNot { it.config.name == status.config.name })
        }
        notice(L10n.t(R.string.s_a7e46736df, (status.config.name)))
    }

    /** 点击网络存储列表项：切到对应挂载根浏览（挂载在 appCore 上）。 */
    fun openMount(status: NetworkMountStatus) {
        val rootId = status.rootId
        if (rootId == null) {
            notice(L10n.t(R.string.s_ba8b6a144c, (status.config.name), (status.error ?: L10n.t(R.string.s_0c0015c2d4))))
            return
        }
        core = openSystem() ?: appCore
        history.clear()
        _state.update {
            it.copy(
                rootKind = BrowserRoot.Network,
                filterLabel = null,
                filterExts = emptySet(),
                searchQuery = "",
                actionsTarget = null,
            )
        }
        load(rootId)
        loadFavorites()
    }

    private fun loadMountConfigs(): List<NetworkMountConfig> = runCatching {
        val raw = prefs.getString(KEY_NETWORK_MOUNTS_ENC, null)
            ?.let { KeystoreCrypto.decrypt(it) }
            ?: return emptyList()
        val arr = org.json.JSONArray(raw)
        (0 until arr.length()).map { i ->
            val o = arr.getJSONObject(i)
            NetworkMountConfig(
                name = o.getString("name"),
                protocol = o.getString("protocol"),
                host = o.getString("host"),
                port = o.optInt("port", 0),
                share = o.optString("share"),
                username = o.optString("username"),
                password = o.optString("password"),
            )
        }
    }.getOrDefault(emptyList())

    private fun saveMountConfigs(list: List<NetworkMountConfig>) {
        val arr = org.json.JSONArray()
        list.forEach { c ->
            arr.put(
                org.json.JSONObject().apply {
                    put("name", c.name)
                    put("protocol", c.protocol)
                    put("host", c.host)
                    put("port", c.port)
                    put("share", c.share)
                    put("username", c.username)
                    put("password", c.password)
                    put("region", c.region)
                    put("pathStyle", c.pathStyle)
                    put("sessionToken", c.sessionToken)
                },
            )
        }
        runCatching {
            prefs.edit().putString(KEY_NETWORK_MOUNTS_ENC, KeystoreCrypto.encrypt(arr.toString())).apply()
        }
    }

    // ---- 后台索引扫描（进目录即触发；与前台操作互不阻塞，扫描串行排队） ----

    private var scanning = false

    /** 扫描任务：`id` 可以是本地目录，也可以是网络挂载根（remote 仅手动触发）。 */
    private data class ScanJob(
        val id: String,
        val force: Boolean,
        val remote: Boolean = false,
        val label: String? = null,
    )

    /**
     * 自动扫描冷却（10 分钟，持久化）：避免反复进出同一目录、以及重启应用时
     * 重复全盘扫描；FAB 手动刷新不受限。
     */
    private fun scanCooldownKey(id: String) = "scan_at_$id"

    /**
     * `id` 属于哪个内核。索引必须写回它自己的库：共享存储的路径不能拿
     * appCore 去 list（会被 jail 拒绝），反之亦然。
     */
    private fun coreOwning(id: String): SuperFiles {
        if (!id.startsWith("/")) return openSystem() ?: appCore
        val sandbox = File(getApplication<Application>().filesDir, "storage").absolutePath
        val shared = android.os.Environment.getExternalStorageDirectory().absolutePath
        return when {
            id == sandbox || id.startsWith("$sandbox/") -> appCore
            id == shared || id.startsWith("$shared/") -> sharedCore ?: openShared() ?: appCore
            else -> systemCore ?: core
        }
    }

    /**
     * 索引所有程序可访问的本地目录：应用沙盒 + 共享存储。
     * 网络存储（WebDAV / SMB / S3 / 云盘）不在这里自动索引——只有用户显式
     * 添加「索引位置」之后才扫描（见 [refreshIndexPins]）。
     */
    fun indexAccessibleRoots(force: Boolean = false, label: String? = null) {
        scanInBackground(appCore.rootId(), force, label)
        sharedCore?.let { scanInBackground(it.rootId(), force, label) }
    }

    /**
     * 异步刷新索引：进度经 state.scanFraction 回流，完成后 scanDone=true（绿色 ✓）。
     * `force=true`（手动）忽略冷却。
     */
    fun scanInBackground(id: String, force: Boolean = false, label: String? = null) {
        // 远端 id 形如 `webdav://…`：绝不自动索引（用户在索引管理里手动建立）
        if (!id.startsWith("/")) return
        enqueueScan(ScanJob(id, force, label = label))
    }

    /**
     * 索引管理：为某个网络存储建立/重建索引。与本地扫描共用同一条串行队列：
     * 前台显示进度；离开页面/切到首页不打断（任务跑在 ViewModel 作用域）。
     */
    fun indexMountInBackground(rootId: String, label: String) {
        enqueueScan(ScanJob(rootId, force = true, remote = true, label = label))
    }

    private fun enqueueScan(job: ScanJob) {
        if (scanning) {
            if (scanQueue.none { it.id == job.id }) scanQueue.addLast(job)
            return
        }
        val now = System.currentTimeMillis()
        if (!job.force && !job.remote &&
            now - prefs.getLong(scanCooldownKey(job.id), 0L) < 10 * 60 * 1000L
        ) {
            return
        }
        startScan(job)
    }

    private fun startScan(job: ScanJob) {
        val id = job.id
        scanning = true
        val scanT0 = android.os.SystemClock.elapsedRealtime()
        android.util.Log.d("SuperFiles", "scan start $id")
        prefs.edit().putLong(scanCooldownKey(id), System.currentTimeMillis()).apply()
        _state.update {
            it.copy(
                scanFraction = 0f,
                scanDone = false,
                scanLabel = job.label,
                scanTargetId = job.id,
            )
        }
        viewModelScope.launch {
            val target = coreOwning(id)
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    val listener = object : IndexProgressListener {
                        override fun onProgress(directories: ULong, entries: ULong, fraction: Float) {
                            _state.update {
                                it.copy(scanFraction = fraction.coerceIn(0f, 0.99f))
                            }
                            // 本地扫描期间让首页分类数字跟着涨（最多 2s 刷一次）；
                            // 网络索引不影响本地分类计数，跳过。
                            if (!job.remote) {
                                val now = android.os.SystemClock.elapsedRealtime()
                                if (now - lastCategoryRefreshAt >= 2_000) {
                                    lastCategoryRefreshAt = now
                                    refreshCategoryStats()
                                }
                            }
                        }

                        override fun onFinished(total: ULong) = Unit
                    }
                    // 手动「重建」= 跳过 mtime 增量判断，整棵重新列举；
                    // 自动扫描（进目录/启动）仍然只扫变化的部分。
                    if (job.force) {
                        target.indexDirFullWithProgress(id, listener)
                    } else {
                        target.indexDirWithProgress(id, listener)
                    }
                }
            }
            scanning = false
            android.util.Log.d(
                "SuperFiles",
                "scan done $id in ${android.os.SystemClock.elapsedRealtime() - scanT0}ms -> " +
                    result.getOrNull().toString(),
            )
            result
                .onSuccess { total ->
                    prefs.edit().putBoolean(KEY_SCAN_DONE, true).apply()
                    _state.update {
                        it.copy(
                            scanFraction = null,
                            scanDone = true,
                            scanLabel = null,
                            scanTargetId = null,
                            indexedCount = total.toLong(),
                        )
                    }
                    refreshCategoryStats()
                    refreshIndexTargets()
                }
                .onFailure {
                    _state.update {
                        it.copy(scanFraction = null, scanLabel = null, scanTargetId = null)
                    }
                    if (it !is SfException.Cancelled) report(it)
                }
            // 队列里的下一个（串行，不并发抢 IO/数据库）
            while (scanQueue.isNotEmpty()) {
                val next = scanQueue.removeFirst()
                val now = System.currentTimeMillis()
                if (!next.force && !next.remote &&
                    now - prefs.getLong(scanCooldownKey(next.id), 0L) < 10 * 60 * 1000L
                ) {
                    continue
                }
                startScan(next)
                return@launch
            }
        }
    }

    private fun openShared(): SuperFiles? {
        sharedCore?.let { return it }
        if (!android.os.Environment.isExternalStorageManager()) {
            notice(L10n.t(R.string.s_08f4bba530))
            return null
        }
        val root = android.os.Environment.getExternalStorageDirectory()
        val index = File(getApplication<Application>().filesDir, "index-shared.sqlite")
        return runCatching { SuperFiles.open(root.absolutePath, index.absolutePath) }
            .onFailure {
                android.util.Log.e("SuperFiles", "open shared root failed", it)
                notice(L10n.t(R.string.s_cff11f1e87, (friendlyError(it))))
            }
            .getOrNull()
            ?.also { sharedCore = it }
    }

    private fun openSystem(): SuperFiles? {
        systemCore?.let { return it }
        val index = File(getApplication<Application>().filesDir, "index-system.sqlite")
        return runCatching { SuperFiles.open("/", index.absolutePath) }
            .onFailure {
                android.util.Log.e("SuperFiles", "open system root failed", it)
                notice(L10n.t(R.string.s_bad536e58e, (friendlyError(it))))
            }
            .getOrNull()
            ?.also {
                systemCore = it
                // 远端流式 Provider 读数走 systemCore（网络挂载都在它上面）
                com.superfiles.app.stream.RemoteFileProvider.appCore = it
            }
    }

    /**
     * 切换浏览根：应用沙盒 ⇄ 内部共享存储。
     * 共享存储需要「所有文件访问」授权（MANAGE_EXTERNAL_STORAGE），授权后直接开根浏览；
     * 各根独立索引库（index.sqlite / index-shared.sqlite / index-system.sqlite）。
     */
    fun switchRoot(target: BrowserRoot) {
        if (target == _state.value.rootKind) return
        if (target == BrowserRoot.SharedStorage) {
            core = openShared() ?: return
        } else {
            core = appCore
        }
        history.clear()
        _state.update {
            it.copy(
                rootKind = target,
                searchQuery = "",
                filterLabel = null,
                filterExts = emptySet(),
                actionsTarget = null,
            )
        }
        load(core.rootId())
        loadRecent()
        // 新根的内核可能是刚刚才打开的（共享/全盘），其索引里的收藏现在才可解析
        loadFavorites()
        // 进入新根的目录即触发后台扫描（异步 + 饼图进度，不阻塞前台）
    }

    /** 返回上一级"根"（共享/全盘根 → 逐级退回）。 */
    fun backToParentRoot() {
        when (_state.value.rootKind) {
            BrowserRoot.SharedStorage, BrowserRoot.Network -> switchRoot(BrowserRoot.AppStorage)
            BrowserRoot.System ->
                switchRoot(
                    if (android.os.Environment.isExternalStorageManager()) {
                        BrowserRoot.SharedStorage
                    } else {
                        BrowserRoot.AppStorage
                    },
                )
            BrowserRoot.AppStorage -> Unit
        }
    }

    /**
     * 路径栏直达：输入绝对路径回车跳转（如 /data/data、/storage/emulated/0/DCIM）。
     * 目标核按路径归属自动选择（沙盒 / 共享 / 全盘）；先探测「目录且可列出」，
     * 失败时给出「无法访问」提示且不改变当前浏览状态。
     */
    fun navigateToPath(raw: String) {
        val sandboxRoot = File(getApplication<Application>().filesDir, "storage").absolutePath
        val sharedRoot = android.os.Environment.getExternalStorageDirectory().absolutePath
        var path = raw.trim().trimEnd('/').ifEmpty { "/" }
        if (!path.startsWith("/")) {
            notice(L10n.t(R.string.s_ab7f7fb7eb))
            return
        }
        // /sdcard 与 /storage/self/primary 都是共享存储的软链别名
        path = when {
            path == "/sdcard" -> sharedRoot
            path.startsWith("/sdcard/") -> sharedRoot + path.removePrefix("/sdcard")
            path == "/storage/self/primary" -> sharedRoot
            path.startsWith("/storage/self/primary/") ->
                sharedRoot + path.removePrefix("/storage/self/primary")
            else -> path
        }
        val resolved = coreForPath(path) ?: return
        val target = resolved.first
        val kind = resolved.second
        viewModelScope.launch {
            val probe = withContext(Dispatchers.IO) {
                runCatching {
                    val entry = target.stat(path)
                    if (entry.kind != EntryKind.DIRECTORY) null else target.list(path)
                }
            }
            probe.onFailure {
                notice(L10n.t(R.string.s_4b430a794e, (path), (friendlyError(it))))
                return@launch
            }
            if (probe.getOrNull() == null) {
                notice(L10n.t(R.string.s_3de6cb79b3, (path)))
                return@launch
            }
            core = target
            history.clear()
            _state.update {
                it.copy(
                    rootKind = kind,
                    filterLabel = null,
                    filterExts = emptySet(),
                    searchQuery = "",
                    actionsTarget = null,
                )
            }
            load(path)
        }
    }

    /** 记录一次「打开」并刷新首页最近列表（索引表 recent_opens）。 */
    fun recordOpen(entry: Entry) {
        viewModelScope.launch {
            withContext(Dispatchers.IO) { runCatching { core.recordOpen(entry.id) } }
            loadRecent()
        }
    }

    /** 最近打开：跨「应用存储 + 共享存储」两个根合并，按打开时间倒序。 */
    private fun loadRecent() {
        viewModelScope.launch {
            val recent = withContext(Dispatchers.IO) {
                runCatching {
                    val all = ArrayList<RecentOpen>()
                    runCatching { appCore.recentFiles(8u) }.getOrNull()?.let { all += it }
                    sharedCore?.let { shared ->
                        runCatching { shared.recentFiles(8u) }.getOrNull()?.let { all += it }
                    }
                    all.sortedByDescending { it.openedMs }.take(6)
                }.getOrDefault(emptyList())
            }
            _state.update { it.copy(recent = recent) }
        }
    }



    fun openEntry(entry: Entry) {
        if (entry.kind != EntryKind.DIRECTORY) return
        // 搜索结果可能来自其它根（跨根合并搜索）→ 按路径路由到所属内核
        val path = core.displayPath(entry.id)
        val resolved = coreForPath(path)
        val switched = resolved != null && (resolved.first !== core || resolved.second != _state.value.rootKind)
        if (switched) {
            core = resolved!!.first
            history.clear()
            _state.update {
                it.copy(
                    rootKind = resolved.second,
                    filterLabel = null,
                    filterExts = emptySet(),
                    searchQuery = "",
                    actionsTarget = null,
                )
            }
        } else {
            history.addLast(_state.value.currentId)
        }
        load(entry.id)
    }

    /**
     * 条目的「所在位置」（搜索结果展示用，解决不同目录同名文件无法区分的问题）：
     * 返回相对所属存储根的路径（如 `工作资料/山屿品牌`），根下直放返回 `/`。
     * display_path 是纯字符串运算（无 IO），可在组合期安全调用。
     */
    /**
     * 结果行「所在位置」：数据源 · 相对目录。用户据此判断文件归属来决定操作——
     * 例如 SMB/WebDAV 上的大视频「先拷到本地再播」比流播流畅。
     * - 网络/云盘 id：`SCHEME · 挂载名 · 相对路径`（host/首级 share 折叠进挂载名）
     * - 本地路径：按沙盒 / 共享 / 全盘给出存储名，相对路径沿用中间省略压缩
     * - parent 为空（根）回退 "/"
     */
    fun locationOf(entry: Entry): String {
        val full = entry.parent?.takeIf { it.isNotEmpty() } ?: return "/"
        if (!full.startsWith("/")) {
            val source = sourceLabelOf(full)
            val rel = relativePathUnderRoot(full)
            return if (rel.isEmpty()) source else "$source · ${compressPath(rel)}"
        }
        val sandboxRoot = File(getApplication<Application>().filesDir, "storage").absolutePath
        val sharedRoot = android.os.Environment.getExternalStorageDirectory().absolutePath
        return when {
            full == sandboxRoot || full.startsWith("$sandboxRoot/") ->
                L10n.t(R.string.s_99f7a465ec) + suffixAfter(sandboxRoot, full)
            full == sharedRoot || full.startsWith("$sharedRoot/") ->
                L10n.t(R.string.s_0d81676d53) + suffixAfter(sharedRoot, full)
            else ->
                L10n.t(R.string.s_5e2bb608f9) + " · ${compressPath(full)}"
        }
    }

    /** 本地根下裁掉前缀的部分，格式化为「 · 相对路径」（根本身则只留存储名）。 */
    private fun suffixAfter(root: String, full: String): String {
        if (full == root) return ""
        val rel = full.removePrefix("$root/")
        return " · ${compressPath(rel)}"
    }

    /**
     * 数据源名：网络 id → 「协议大写 · 挂载名」（挂载缺名回退 host）；本地路径
     * → 沙盒「应用存储」/ 共享「内部共享存储」/ 其余「本地存储」。
     */
    fun sourceLabelOf(path: String): String {
        if (path.startsWith("/")) {
            val sandboxRoot = File(getApplication<Application>().filesDir, "storage").absolutePath
            val sharedRoot = android.os.Environment.getExternalStorageDirectory().absolutePath
            return when {
                path == sandboxRoot || path.startsWith("$sandboxRoot/") ->
                    L10n.t(R.string.s_99f7a465ec)
                path == sharedRoot || path.startsWith("$sharedRoot/") ->
                    L10n.t(R.string.s_0d81676d53)
                else -> L10n.t(R.string.s_5e2bb608f9)
            }
        }
        val scheme = path.substringBefore("://", "").uppercase()
        val rest = path.substringAfter("://", "")
        val host = rest.substringBefore('/')
        val share = rest.substringAfter('/', "")
            .substringBefore('/')
            .takeIf { it.isNotEmpty() } ?: ""
        val mounts = _state.value.networkMounts
        val mountName = mounts.firstOrNull { m ->
            m.rootId?.startsWith("$scheme://", ignoreCase = true) == true &&
                m.config.host == host &&
                (share.isEmpty() || m.config.share.isBlank() || m.config.share == share)
        }?.config?.name ?: host.ifEmpty { scheme }
        return "$scheme · $mountName"
    }

    /** 网络路径折掉主机后的目录段（每级 share 保留——挂载名与 share 常重名，宁可稍重复）。 */
    private fun relativePathUnderRoot(path: String): String {
        val rest = path.substringAfter("://", path)
        return rest.substringAfter('/', "")
    }

    /** 太长时中间用 … 省略，保留开头与最后一级目录（同名文件靠最后一级区分）。 */
    private fun compressPath(full: String): String {
        val max = 56
        if (full.length <= max) return full
        val headCut = full.take(18)
        val head = headCut.substringBeforeLast('/', "")
        val tailCut = full.takeLast(34)
        val tail = tailCut.substringAfter('/', tailCut)
        return if (head.isEmpty()) "…/$tail" else "$head…/$tail"
    }

    /** 路径 → 所属内核与根类型（沙盒 / 共享 / 全盘 / 网络）。 */
    private fun coreForPath(path: String): Pair<SuperFiles, BrowserRoot>? {
        // 网络挂载 id 是 `webdav://…`/`smb://…` 形式（非绝对路径），挂在 appCore 上
        if (!path.startsWith("/")) return (openSystem() ?: appCore) to BrowserRoot.Network
        val sandboxRoot = File(getApplication<Application>().filesDir, "storage").absolutePath
        val sharedRoot = android.os.Environment.getExternalStorageDirectory().absolutePath
        return when {
            path == sandboxRoot || path.startsWith("$sandboxRoot/") ->
                appCore to BrowserRoot.AppStorage
            path == sharedRoot || path.startsWith("$sharedRoot/") ->
                openShared()?.let { it to BrowserRoot.SharedStorage }
            else -> openSystem()?.let { it to BrowserRoot.System }
        }
    }

    fun goUp() {
        val previous = history.removeLastOrNull() ?: return
        load(previous)
    }

    fun refresh() = load(_state.value.currentId.ifEmpty { core.rootId() })

    /**
     * 模糊搜索：走 SQLite FTS5（trigram 子串 + 拼音全拼/首字母 sidecar），
     * 本地索引毫秒级返回，随输随搜。
     *
     * 作用域语义（与产品对齐）：
     *  - 普通浏览 / 首页入口：全盘搜索；
     *  - 类型筛选页（如「个人文档」）：仅在该类型集合内命中（扩展名交集过滤）。
     */
    private var searchJob: kotlinx.coroutines.Job? = null

    /** 查询解析器：默认字面解析；接入自然语言模型时用 [setQueryParser] 注入。 */
    private var queryParser: QueryParser = NaturalLanguageQueryParser

    fun setQueryParser(parser: QueryParser) {
        queryParser = parser
    }

    fun search(rawQuery: String) {
        _state.update { it.copy(searchQuery = rawQuery) }
        val scope = _state.value.filterExts
        searchJob?.cancel() // 防抖：连击只保留最后一次
        if (rawQuery.isBlank()) {
            if (scope.isNotEmpty()) {
                applyTypeFilter(_state.value.filterLabel ?: return, scope) // 清空 → 回到类型列表
            } else {
                refresh()
            }
            return
        }
        searchJob = viewModelScope.launch {
            kotlinx.coroutines.delay(160)
            _state.update { it.copy(loading = true, error = null) }
            val startedAt = android.os.SystemClock.elapsedRealtime()

            // 1) 解析（字面 or 自然语言/模型）
            val context = SearchContext(
                currentRootId = core.rootId(),
                filterLabel = _state.value.filterLabel,
                filterExts = scope,
                mountedRootIds = _state.value.networkMounts.mapNotNull { it.rootId },
                appRootPath = appRootPath(),
                sharedRootPath = sharedRootPath(),
            )
            val query = runCatching { queryParser.parse(rawQuery, context) }
                .getOrElse { LiteralQueryParser.parse(rawQuery, context) }

            // 2) 执行（候选 + 结构化过滤 + 位置预计算，全部在 IO 线程）
            val result = withContext(Dispatchers.IO) {
                runCatching { executeQuery(query) }
            }
            android.util.Log.d(
                "SuperFiles",
                "search '$rawQuery' -> ${result.getOrNull()?.size ?: -1} hits in " +
                    "${android.os.SystemClock.elapsedRealtime() - startedAt}ms " +
                    "(ext=${query.extensions} kinds=${query.kinds} roots=${query.roots.size})",
            )
            result
                .onSuccess { hits ->
                    val label = _state.value.filterLabel
                    _state.update {
                        it.copy(
                            loading = false,
                            entries = visible(hits),
                            locationProvider = { entry -> locationOf(entry) },
                            title = if (label != null) L10n.t(R.string.s_de40885484, (label), (rawQuery)) else L10n.t(R.string.s_0992ea7ba2, (rawQuery)),
                            error = null,
                            offlineCacheMs = null,
                            selectionMode = false,
                            selectedIds = emptySet(),
                        )
                    }
                }
                .onFailure(::report)
        }
    }

    /** 执行结构化查询：索引候选（跨根合并）→ 结构化过滤 → 排序 → 截断。 */
    private fun executeQuery(query: SearchQuery): List<Entry> {
        val cores = listOfNotNull(appCore, sharedCore, systemCore)
        // 纯结构化查询（如「上个月的照片」）没有关键词，FTS 只能先给一批最近
        // 候选再过滤；扩大候选池，避免近期非图片文件把老照片挤出前 200。
        val structured = query.text.isBlank() && (
            query.extensions.isNotEmpty() || query.kinds.isNotEmpty() ||
                query.modifiedAfterMs != null || query.modifiedBeforeMs != null ||
                query.minSizeBytes != null || query.maxSizeBytes != null
            )
        val poolSize = if (structured) 5000u else (query.limit.coerceAtLeast(200)).toUInt()
        return cores
            .flatMap { coreItem ->
                runCatching { coreItem.search(query.text, poolSize) }.getOrDefault(emptyList())
            }
            .distinctBy { it.id }
            .filter { entry ->
                (query.extensions.isEmpty() || extOf(entry.name) in query.extensions) &&
                    (query.kinds.isEmpty() || entry.kind in query.kinds) &&
                    (query.modifiedAfterMs == null || (entry.modifiedMs ?: 0L) >= query.modifiedAfterMs) &&
                    (query.modifiedBeforeMs == null || (entry.modifiedMs ?: Long.MAX_VALUE) <= query.modifiedBeforeMs) &&
                    (query.minSizeBytes == null || entry.size.toLong() >= query.minSizeBytes) &&
                    (query.maxSizeBytes == null || entry.size.toLong() <= query.maxSizeBytes) &&
                    (query.roots.isEmpty() || query.roots.any { root -> entry.id.startsWith(root) })
            }
            .let { list ->
                when (query.sort) {
                    SortMode.MODIFIED_DESC -> list.sortedByDescending { it.modifiedMs ?: 0L }
                    SortMode.NAME_ASC -> list.sortedBy { it.name }
                }
            }
            .take(query.limit)
    }

    fun createFolder(name: String) {
        val parent = _state.value.currentId
        if (name.isBlank()) return
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { runCatching { core.createDir(parent, name) } }
            result
                .onSuccess {
                    load(parent)
                    refreshCategoryStats()
                }
                .onFailure(::report)
        }
    }

    fun delete(entry: Entry) {
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching { core.remove(entry.id, entry.kind == EntryKind.DIRECTORY) }
            }
            result
                .onSuccess {
                    refreshCurrent()
                    refreshCategoryStats()
                    notice(L10n.t(R.string.s_40cfaa37c2, (entry.name)))
                }
                .onFailure(::report)
        }
    }

    // ---- 多选模式（长按进入；M1 批量操作：复制/移动/删除/压缩） ----

    fun enterSelection(entry: Entry) {
        _state.update { it.copy(selectionMode = true, selectedIds = setOf(entry.id)) }
    }

    /** 滑动多选：只增选（拖过同一行时不反复反选）。 */
    fun addSelection(entry: Entry) {
        _state.update { s ->
            if (entry.id in s.selectedIds) s
            else s.copy(selectionMode = true, selectedIds = s.selectedIds + entry.id)
        }
    }

    fun toggleSelection(entry: Entry) {
        _state.update { s ->
            val next =
                if (entry.id in s.selectedIds) s.selectedIds - entry.id else s.selectedIds + entry.id
            // 最后一项被取消 = 自动退出多选
            s.copy(selectedIds = next, selectionMode = next.isNotEmpty())
        }
    }

    fun selectAllVisible() {
        _state.update { it.copy(selectedIds = it.entries.map { e -> e.id }.toSet()) }
    }

    fun clearSelection() {
        _state.update { it.copy(selectionMode = false, selectedIds = emptySet()) }
    }

    /** 当前选中的条目（按列表顺序）。 */
    fun selectedEntries(): List<Entry> {
        val ids = _state.value.selectedIds
        return _state.value.entries.filter { it.id in ids }
    }

    /** 批量删除：逐条独立失败不影响其余；条目按路径自动路由所属内核。 */
    fun deleteEntries(entries: List<Entry>) {
        if (entries.isEmpty()) return
        viewModelScope.launch {
            val removed = withContext(Dispatchers.IO) {
                var count = 0
                entries.forEach { e ->
                    val target = coreForPath(core.displayPath(e.id))?.first ?: core
                    runCatching { target.remove(e.id, e.kind == EntryKind.DIRECTORY) }
                        .onSuccess { count++ }
                        .onFailure { SfLog.e("batch delete failed: ${e.name}", it) }
                }
                count
            }
            clearSelection()
            refreshCurrent()
            refreshCategoryStats()
            // 删除后同步收藏/最近列表，避免已不存在的条目继续显示（滑删时尤其明显）
            loadFavorites()
            loadRecent()
            notice(
                if (removed == entries.size) L10n.t(R.string.s_482fb3b1e2, (removed))
                else L10n.t(R.string.s_7c1c929315, (removed), (entries.size - removed)),
            )
        }
    }

    /** FAB 手动刷新索引（全量重扫，带进度；与后台自动扫描共用同一条串行通道）。 */
    fun indexEverything() = indexAccessibleRoots(force = true)

    fun dismissError() {
        _state.update { it.copy(error = null) }
    }

    // ---- 传输中心：多条并发（引擎侧异步执行，与 UI 生命周期解耦） ----

    private var transferPolling = false

    /** 已创建过的内核集合（传输可能落在任意一个上：浏览核复制 vs systemCore 移动）。 */
    private fun allCores(): List<SuperFiles> =
        listOfNotNull(systemCore, core, appCore, sharedCore).distinct()

    /** 轮询传输状态（仅展示用）。传输本体在 Rust runtime 中执行：
     * 退出界面/退到后台只要进程活着就继续，进程被杀即停止（符合产品约定）。
     */
    /** 速度采样：(上次字节数, 上次采样时刻 ms, 平滑后速度)。 */
    private class RateSample(var bytes: Long, var at: Long, var rate: Long = 0)

    private val rateSamples = HashMap<String, RateSample>()

    /** 目录选择器的后台刷新节流（dirId → 上次刷新时刻）：防止「缓存→刷新→重绘→再刷新」自旋。 */
    private val destRefreshAt = java.util.concurrent.ConcurrentHashMap<String, Long>()

    private fun sampleRates(list: List<TransferSnapshot>): Map<String, Long> {
        val now = android.os.SystemClock.elapsedRealtime()
        val rates = HashMap<String, Long>()
        for (t in list) {
            if (t.state != TransferState.RUNNING) {
                rateSamples.remove(t.id)
                continue
            }
            val bytes = t.bytesDone.toLong()
            val prev = rateSamples[t.id]
            if (prev == null) {
                rateSamples[t.id] = RateSample(bytes, now)
                continue
            }
            val dt = now - prev.at
            if (dt < 400) { // 采样窗口太短，沿用上次速度
                if (prev.rate > 0) rates[t.id] = prev.rate
                continue
            }
            val instant = ((bytes - prev.bytes).coerceAtLeast(0) * 1000) / dt
            // EMA：新值占 1/3，避免数字跳动（2s 收敛到真实值附近）
            val smoothed = if (prev.rate == 0L) instant else (prev.rate * 2 + instant) / 3
            prev.bytes = bytes
            prev.at = now
            prev.rate = smoothed
            rates[t.id] = smoothed
        }
        return rates
    }

    /** 已提示过完成的任务 id（复制/移动），用于只刷新一次分类计数。 */
    private val completedTransferIds = mutableSetOf<String>()

    private fun startTransferPolling() {
        if (transferPolling) return
        transferPolling = true
        viewModelScope.launch {
            while (true) {
                pollTransfersOnce()
                // 空闲时 2.5s 一拍；有任务时 700ms 一拍。启动/恢复会主动插一拍，
                // 所以不用为了「立刻出现进度」把空闲节拍调快。
                val active = _state.value.transfers.any {
                    it.state == TransferState.QUEUED ||
                        it.state == TransferState.RUNNING ||
                        // PAUSED 仍是「正在网络上」的任务：恢复跟手/FGS 保活都不能停
                        it.state == TransferState.PAUSED
                }
                kotlinx.coroutines.delay(if (active) 700 else 2500)
            }
        }
    }

    /**
     * 立即拉一次任务快照并同步前台服务。启动/恢复传输后直接调用它，
     * 进度浮层/传输中心无需等下一个轮询节拍（空闲时是 2.5s）。
     */
    private suspend fun pollTransfersOnce() {
        // 合并所有内核的任务（移动总在 systemCore 上，「⋯」复制在浏览核上）
        val list = withContext(Dispatchers.IO) {
            allCores()
                .flatMap { c -> runCatching { c.transfers() }.getOrDefault(emptyList()) }
                .distinctBy { it.id }
        }
        val rates = sampleRates(list)
        _state.update { it.copy(transfers = list, transferRates = rates) }
        // 前台浮层里的任务结束（完成/失败/取消）→ 自动收起浮层
        val fgBefore = _state.value.foregroundTransfers
        if (fgBefore.isNotEmpty()) {
            val ended = list
                .filter {
                    it.id in fgBefore && it.state != TransferState.QUEUED &&
                        it.state != TransferState.RUNNING &&
                        // PAUSED 不是结束态：前台任务不会被打成 PAUSED（浮层无暂停入口），
                        // 防御性保留，防止未来加入口后浮层被提前收掉
                        it.state != TransferState.PAUSED
                }
                .map { it.id }
                .toSet()
            if (ended.isNotEmpty()) {
                _state.update {
                    it.copy(
                        foregroundTransfers = it.foregroundTransfers - ended,
                        foregroundMoves = it.foregroundMoves - ended,
                    )
                }
            }
        }
        // M1 前台服务：只保活「已转后台」的任务；前台浮层由 App 自己展示进度
        val background = list.filter { it.id !in _state.value.foregroundTransfers }
        val backgroundIds = background.map { it.id }.toSet()
        TransferService.sync(getApplication(), background, rates.filterKeys { it in backgroundIds })
        // 有任务完成（复制/移动）→ 索引已由内核同步，这里只需刷新界面计数。
        val newlyDone = list.filter {
            it.state == TransferState.COMPLETED && completedTransferIds.add(it.id)
        }
        if (newlyDone.isNotEmpty()) {
            refreshCategoryStats()
        }
        // 移动完成：引擎已删源，这里只负责刷新当前目录 + 提示
        val movedDone = list.any {
            it.state == TransferState.COMPLETED && moveTaskIds.remove(it.id)
        }
        if (movedDone) {
            refreshCurrent()
            notice(L10n.t(R.string.s_983dbb845a))
        }
    }

    /** 找到活着管理该传输的内核（找不到 = 已属其它进程历史）。 */
    private suspend fun coreOwningTransfer(id: String): SuperFiles? = withContext(Dispatchers.IO) {
        allCores().firstOrNull { c ->
            runCatching { c.transferSnapshot(id) != null }.getOrDefault(false)
        }
    }

    fun cancelTransfer(id: String) {
        viewModelScope.launch {
            coreOwningTransfer(id)?.let { runCatching { it.cancelTransfer(id) } }
            notice(L10n.t(R.string.s_610c06de88))
        }
    }

    /**
     * 左滑「暂停」：PAUSED（非终态）保留进度，可 unpause 继续或 cancel 终止。
     * 引擎在块边界停摆，与取消同优先级——暂停中点取消立即生效。
     */
    fun pauseTransfer(id: String) {
        viewModelScope.launch {
            coreOwningTransfer(id)?.let { runCatching { it.pauseTransfer(id) } }
        }
    }

    /** 左滑「继续」：解除 PAUSED 拨回 RUNNING。与 resumeTransfer（崩溃恢复）是两条独立路径。 */
    fun unpauseTransfer(id: String) {
        viewModelScope.launch {
            coreOwningTransfer(id)?.let { runCatching { it.unpauseTransfer(id) } }
        }
    }

    /**
     * 前台进度浮层 →「后台传输」：交给传输中心列表 + 前台服务（通知栏）继续跑。
     * 只是一个 UI 归属切换，引擎任务本身从不中断。
     */
    fun sendForegroundTransfersToBackground() {
        if (_state.value.foregroundTransfers.isEmpty()) return
        _state.update { it.copy(foregroundTransfers = emptySet(), foregroundMoves = emptySet()) }
    }

    /** 前台进度浮层 →「终止」：取消这批任务并收起浮层。 */
    fun cancelForegroundTransfers() {
        val ids = _state.value.foregroundTransfers
        if (ids.isEmpty()) return
        _state.update { it.copy(foregroundTransfers = emptySet(), foregroundMoves = emptySet()) }
        viewModelScope.launch {
            ids.forEach { id ->
                coreOwningTransfer(id)?.let { runCatching { it.cancelTransfer(id) } }
            }
            notice(L10n.t(R.string.s_4b773fca16))
        }
    }

    /**
     * App 退到后台时调用：前台浮层已不可见，自动把这批任务转为后台传输，
     * 由前台服务接管（否则界面消失了却也没有 FGS 保活，进程可能被杀）。
     */
    fun promoteForegroundTransfers() {
        if (_state.value.foregroundTransfers.isEmpty()) return
        _state.update { it.copy(foregroundTransfers = emptySet(), foregroundMoves = emptySet()) }
    }

    fun forgetTransfer(id: String) {
        viewModelScope.launch {
            coreOwningTransfer(id)?.let { runCatching { it.forgetTransfer(id) } }
            withContext(Dispatchers.IO) {
                allCores().forEach { c -> runCatching { c.forgetTransfer(id) } }
            }
        }
    }

    fun refreshResumable() {
        viewModelScope.launch {
            val list = withContext(Dispatchers.IO) {
                allCores()
                    .flatMap { c -> runCatching { c.pendingTransfers() }.getOrDefault(emptyList()) }
                    .distinctBy { it.id }
            }
            _state.update { it.copy(resumable = list) }
        }
    }

    fun resumeTransfer(id: String) {
        viewModelScope.launch {
            // 续传必须回到记录所属的内核（其索引库才有该任务档案，且挂载在它上面）
            val owner = withContext(Dispatchers.IO) {
                allCores().firstOrNull { c ->
                    runCatching { c.pendingTransfers().any { it.id == id } }.getOrDefault(false)
                }
            }
            if (owner == null) {
                notice(L10n.t(R.string.s_c669dbfe3b))
                return@launch
            }
            val result = withContext(Dispatchers.IO) { runCatching { owner.resumeTransfer(id) } }
            result
                .onSuccess {
                    // 恢复是从「传输中心」发起的，就直接在传输中心跑：
                    // 不进前台浮层（那是给浏览页新建复制/移动用的），
                    // 主动插一拍让该行立刻变成「传输中」并拉起前台服务通知。
                    notice(L10n.t(R.string.s_9ae2a3725b))
                    refreshResumable()
                    pollTransfersOnce()
                }
                .onFailure(::report)
        }
    }

    fun forgetResumable(id: String) {
        viewModelScope.launch {
            // 持久化档案分布各内核 sqlite（传输在哪个核启动就在哪个库），全部尝试删除
            withContext(Dispatchers.IO) {
                allCores().forEach { c -> runCatching { c.forgetTransfer(id) } }
            }
            refreshResumable()
        }
    }

    // ---- 跨根复制/移动（任意源 ↔ 任意目标，均在 systemCore 上执行） ----

    /** 仅用于 UI 反馈（完成后刷新源目录）：删除源已由引擎负责并持久化。 */
    private val moveTaskIds = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()

    private fun sharedRootPath(): String =
        android.os.Environment.getExternalStorageDirectory().absolutePath

    private fun appRootPath(): String =
        File(getApplication<Application>().filesDir, "storage").absolutePath

    /** 递归计算本地文件/目录大小（字节）；目录逐层求和。 */
    private fun dirSize(f: File): Long =
        if (f.isFile) f.length() else f.listFiles()?.sumOf { dirSize(it) } ?: 0L

    /** 首页分类数量：走索引 count，不遍历目录树；跨 app/共享/系统三个内核。 */
    fun refreshCategoryStats() {
        viewModelScope.launch {
            val t0 = android.os.SystemClock.elapsedRealtime()
            val stats = withContext(Dispatchers.IO) {
                // 只统计用户数据：系统根 `/` 是 Android rootfs（/system、/data…），
                // 不属于用户文件，也不该出现在相册/文档分类里。
                val cores = listOfNotNull(appCore, sharedCore)
                CATEGORY_DEFS.map { (key, labelRes, exts) ->
                    val includeHidden = _state.value.showHidden
                    val total = cores.sumOf { c ->
                        runCatching {
                            c.countByExts(exts.toList(), includeHidden).toLong()
                        }.getOrDefault(0L)
                    }
                    CategoryStat(key, L10n.t(labelRes), exts, total)
                }
            }
            android.util.Log.d(
                "SuperFiles",
                "category counts ${android.os.SystemClock.elapsedRealtime() - t0}ms " +
                    stats.joinToString { "${it.key}=${it.count}" },
            )
            _state.update { it.copy(categoryStats = stats) }
        }
    }

    /** 某个存储当前是否正在建立索引（用于把进度标到索引管理页对应行）。 */
    fun isIndexTargetRunning(target: IndexTarget): Boolean {
        val running = _state.value.scanTargetId ?: return false
        return if (target.isLocal) {
            running == appCore.rootId() || running == sharedCore?.rootId()
        } else {
            running == target.id
        }
    }

    private fun protocolKindLabel(protocol: String): String = when (protocol.lowercase()) {
        "smb" -> "SMB"
        "webdav" -> "WebDAV"
        "sftp" -> "SFTP"
        "s3" -> "S3"
        else -> L10n.t(R.string.s_index_kind_cloud)
    }

    /**
     * 索引管理页数据：本地存储（沙盒 + 共享存储）+ 每个已挂载的网络存储，
     * 各自已索引的条目数。网络存储只有用户点「建立索引」后才会入库。
     */
    fun refreshIndexTargets() {
        viewModelScope.launch {
            val mounts = _state.value.networkMounts.filter { it.rootId != null }
            val targets = withContext(Dispatchers.IO) {
                val localCount =
                    runCatching { appCore.indexPrefixCount(appCore.rootId()) }.getOrDefault(0uL) +
                        (sharedCore?.let { c ->
                            runCatching { c.indexPrefixCount(c.rootId()) }.getOrDefault(0uL)
                        } ?: 0uL)
                val local = IndexTarget(
                    id = "local",
                    name = L10n.t(R.string.s_index_target_local),
                    kind = L10n.t(R.string.s_index_kind_local),
                    entries = localCount.toLong(),
                    isLocal = true,
                )
                val network = mounts.mapNotNull { mount ->
                    val rootId = mount.rootId ?: return@mapNotNull null
                    val core = runCatching { coreForPath(rootId)?.first }.getOrNull() ?: appCore
                    val count = runCatching { core.indexPrefixCount(rootId) }.getOrDefault(0uL)
                    IndexTarget(
                        id = rootId,
                        name = mount.config.name,
                        kind = protocolKindLabel(mount.config.protocol),
                        entries = count.toLong(),
                        isLocal = false,
                        mount = mount,
                    )
                }
                listOf(local) + network
            }
            _state.update { it.copy(indexTargets = targets) }
        }
    }

    /**
     * 索引管理：建立/重建某个存储的索引（本地 = 沙盒 + 共享存储）。
     * 统一走串行扫描队列：前台显示进度，离开页面/切到首页任务继续在后台跑。
     */
    fun rebuildIndexTarget(target: IndexTarget) {
        if (target.isLocal) {
            indexAccessibleRoots(force = true, label = target.name)
            notice(L10n.t(R.string.s_index_rebuild_started, target.name))
            return
        }
        val root = target.mount?.rootId ?: target.id
        indexMountInBackground(root, target.name)
        notice(L10n.t(R.string.s_index_rebuild_started, target.name))
    }

    /**
     * 索引管理：清空某个存储的索引。本地索引是搜索/分类/最近打开/离线浏览的
     * 数据来源，UI 会先给出警告和原因；网络存储索引直接删除即可。
     */
    fun clearIndexTarget(target: IndexTarget) {
        viewModelScope.launch {
            withContext(Dispatchers.IO) {
                if (target.isLocal) {
                    runCatching { appCore.clearIndex() }
                    sharedCore?.let { runCatching { it.clearIndex() } }
                } else {
                    val root = target.mount?.rootId ?: target.id
                    val core = runCatching { coreForPath(root)?.first }.getOrNull() ?: appCore
                    runCatching { core.clearIndexPrefix(root) }
                }
            }
            // 清空后取消扫描冷却：下次「重建」必须真的重扫，而不是被 10 分钟冷却跳过。
            prefs.edit().apply {
                remove(scanCooldownKey(appCore.rootId()))
                sharedCore?.let { remove(scanCooldownKey(it.rootId())) }
                apply()
            }
            notice(
                if (target.isLocal) {
                    L10n.t(R.string.s_index_local_deleted)
                } else {
                    L10n.t(R.string.s_index_deleted, target.name)
                },
            )
            refreshIndexTargets()
            refreshCategoryStats()
            loadFavorites()
            loadRecent()
            if (target.isLocal) {
                prefs.edit().putBoolean(KEY_SCAN_DONE, false).apply()
                _state.update { it.copy(indexedCount = 0) }
            }
        }
    }

    /** 清理范围：共享存储的用户数据目录（不含 Android/ 等系统/第三方根）+ 应用沙盒。 */
    private fun cleanupRoots(): List<File> {
        val roots = mutableListOf<File>()
        File(appRootPath()).takeIf { it.isDirectory }?.let { roots += it }
        val shared = File(sharedRootPath())
        listOf("Download", "DCIM", "Pictures", "Movies", "Music", "Documents").forEach { name ->
            shared.resolve(name).takeIf { it.isDirectory }?.let { roots += it }
        }
        return roots
    }

    /** 重新扫描：null = 用户数据根列表，否则扫描该目录一级条目。 */
    fun scanStorageForCleanup() = scanCleanupAt(null)

    fun enterCleanupDir(path: String) = scanCleanupAt(path)

    /** 返回上一级；已经在根列表时返回 false（交给页面退出）。 */
    fun cleanupGoUp(): Boolean {
        val cur = _cleanupPath.value ?: return false
        if (cur in cleanupRoots().map { it.absolutePath }) {
            scanCleanupAt(null)
            return true
        }
        val parent = File(cur).parentFile ?: return false
        scanCleanupAt(parent.absolutePath)
        return true
    }

    private fun scanCleanupAt(path: String?) {
        if (_cleanupScanning.value) return
        viewModelScope.launch {
            _cleanupScanning.value = true
            val items = withContext(Dispatchers.IO) {
                runCatching {
                    val dirs = if (path == null) cleanupRoots() else listOf(File(path))
                    dirs.flatMap { dir ->
                        dir.listFiles().orEmpty()
                            .filter { !it.name.startsWith(".") }
                            .map { f -> CleanupItem(f.absolutePath, f.name, dirSize(f), f.isDirectory) }
                    }.distinctBy { it.path }.sortedByDescending { it.size }
                }.getOrDefault(emptyList())
            }
            _cleanupItems.value = items
            _cleanupPath.value = path
            _cleanupScanning.value = false
        }
    }

    /** 批量删除清理项：逐个递归删除，汇总成功/失败后刷新当前目录。 */
    fun deleteCleanupItems(items: List<CleanupItem>) {
        if (items.isEmpty()) return
        viewModelScope.launch {
            val (ok, failed) = withContext(Dispatchers.IO) {
                var o = 0
                var f = 0
                items.forEach { item ->
                    if (runCatching { File(item.path).deleteRecursively() }.getOrDefault(false)) {
                        o++
                    } else {
                        f++
                    }
                }
                o to f
            }
            scanCleanupAt(_cleanupPath.value)
            refreshCurrent()
            notice(
                if (failed == 0) {
                    L10n.t(R.string.s_cleanup_deleted_n, ok.toString())
                } else {
                    L10n.t(R.string.s_cleanup_deleted_partial, ok.toString(), failed.toString())
                },
            )
        }
    }

    /** 点击清理项：目录进入下一级，文件走内置预览/外部打开。 */
    fun openCleanupItem(context: android.content.Context, item: CleanupItem) {
        viewModelScope.launch {
            if (item.isDir) {
                scanCleanupAt(item.path)
                return@launch
            }
            val entry = withContext(Dispatchers.IO) {
                runCatching { (coreForPath(item.path)?.first ?: core).stat(item.path) }.getOrNull()
            }
            if (entry == null) {
                notice(L10n.t(R.string.s_df86c859dc))
                return@launch
            }
            if (isPreviewable(entry)) {
                openDocPreview(entry)
            } else if (!openFileDefault(context, File(item.path), entry.name)) {
                notice(L10n.t(R.string.s_d0b586db3b, (entry.name)))
            }
        }
    }

    /** 删除一个清理项（本地文件/目录，递归删除）；失败给提示，成功后刷新浏览页。 */
    fun deleteCleanupItem(item: CleanupItem) {
        viewModelScope.launch {
            val ok = withContext(Dispatchers.IO) {
                runCatching { File(item.path).deleteRecursively() }.getOrDefault(false)
            }
            if (ok) {
                _cleanupItems.update { it.filterNot { c -> c.path == item.path } }
                notice(L10n.t(R.string.s_40cfaa37c2, (item.name)))
                scanCleanupAt(_cleanupPath.value)
                refreshCurrent()
            } else {
                notice(L10n.t(R.string.s_cleanup_failed, (item.name)))
            }
        }
    }

    /** 目标选择器：根列表 = 应用存储 / 本地存储 / 各网络挂载。 */
    /** 同一后端（尤其 WebDAV 的 host）可能被不同名字挂载两次，rootId 相同会撞 LazyColumn key。 */
    private fun dedupeMounts(list: List<NetworkMountStatus>): List<NetworkMountStatus> {
        val seen = HashSet<String>()
        return list.filter { st ->
            val key = st.rootId ?: ("name:" + st.config.name)
            seen.add(key)
        }
    }

    suspend fun destRoots(): List<DestNode> = withContext(Dispatchers.IO) {
        val sys = openSystem() ?: return@withContext emptyList()
        val nodes = mutableListOf<DestNode>()
        // Network mounts first: when importing from another app, the file is
        // already local, so NAS/WebDAV is usually the desired destination.
        _state.value.networkMounts.filter { it.rootId != null }.forEach { mount ->
            mount.rootId?.let { rid ->
                nodes += DestNode(rid, mount.config.name, L10n.t(R.string.s_9e038b1b38, (mount.config.protocol.uppercase())))
            }
        }
        runCatching { sys.stat(appRootPath()) }.getOrNull()?.let {
            nodes += DestNode(it.id, L10n.t(R.string.s_99f7a465ec), L10n.t(R.string.s_79abfee53f))
        }
        runCatching { sys.stat(sharedRootPath()) }.getOrNull()?.let {
            nodes += DestNode(it.id, L10n.t(R.string.s_5e2bb608f9), L10n.t(R.string.s_c2b9f4b9fc))
        }
        nodes.distinctBy { it.id }
    }

    /** 目标选择器打开时重试断开的网络挂载，避免只看到本地目录。 */
    fun retryDisconnectedMounts() {
        val pending = _state.value.networkMounts.filter { it.rootId == null }
        if (pending.isEmpty()) return
        viewModelScope.launch {
            val mountCore = openSystem() ?: appCore
            val updated = withContext(Dispatchers.IO) {
                pending.map { status ->
                    runCatching { mountOn(mountCore, status.config) }.fold(
                        onSuccess = { rootId -> status.copy(rootId = rootId, error = null) },
                        onFailure = { status.copy(error = friendlyError(it)) },
                    )
                }
            }
            _state.update { s ->
                val byName = updated.associateBy { it.config.name }
                s.copy(networkMounts = s.networkMounts.map { byName[it.config.name] ?: it })
            }
        }
    }

    /**
     * 目标选择器：某个目录下的子目录（自动路由到所属内核）。
     *
     * 慢的根因：每次下钻都实时列举，网络存储一级 = 一次 SMB/WebDAV 往返。
     * 优化：index 缓存（`list()` 平时已把浏览过的目录写索引）优先秒开；
     * 同时后台发起真实列举刷新缓存，完成后 bump `dirTick` 让对话框用新数据
     * 重绘（首次未缓存的目录仍走一次真实列举，但会被写进缓存，下次即快）。
     *
     * 隐藏过滤：复用全局 `visible()`（. 开头/隐藏属性），与文件列表同一规则。
     */
    suspend fun destChildren(parentId: String): List<DestNode> = withContext(Dispatchers.IO) {
        val path = runCatching { core.displayPath(parentId) }.getOrDefault(parentId)
        val target = coreForPath(path)?.first ?: return@withContext emptyList()

        fun toNodes(entries: List<Entry>): List<DestNode> = visible(entries)
            .filter { it.kind == EntryKind.DIRECTORY }
            .sortedBy { it.name }
            .map { DestNode(it.id, it.name, L10n.t(R.string.s_1f4c1042ed)) }

        val cached = runCatching { target.listCached(parentId) }.getOrNull()
        val cachedNodes = cached?.let { toNodes(it.entries) }.orEmpty()
        if (cachedNodes.isNotEmpty()) {
            // 缓存先给结果，实时刷新在后台进行（完成后 dirTick 驱动重绘；10s 节流防自旋）
            val now = android.os.SystemClock.elapsedRealtime()
            val last = destRefreshAt[parentId] ?: 0L
            if (now - last > 10_000) {
                destRefreshAt[parentId] = now
                viewModelScope.launch {
                    // 关键：核心调用是阻塞 FFI（网络列举可达秒级），必须在 IO 线程，
                    // 否则主线程被冻住，用户连点会积压成「目录/目录/目录」面包屑
                    val ok = withContext(Dispatchers.IO) {
                        runCatching { target.list(parentId) }.isSuccess
                    }
                    if (ok) _state.update { s -> s.copy(dirTick = s.dirTick + 1) }
                }
            }
            return@withContext cachedNodes
        }
        // 无缓存：同步真实列举（本地毫秒级；网络首次访问是唯一慢路径）
        val live = runCatching { target.list(parentId) }.getOrDefault(emptyList())
        toNodes(live)
    }

    /**
     * 启动复制或移动（可跨根/跨网络）。引擎在 Rust runtime 异步并发执行；
     * 移动对用户而言就是移动（实现上先复制再清理源；进程被杀时源保持不动，安全）。
     *
     * M1 冲突对话框：先探测目标目录同名项——无冲突直接以「重命名(自动加后缀)」
     * 启动（历史默认）；有冲突逐项弹窗（覆盖/跳过/重命名 + 全部应用），决策完
     * 按策略分组交给引擎（跳过组不下发）。
     */
    fun startTransfer(sources: List<String>, destDir: String, move: Boolean) {
        if (sources.isEmpty()) return
        viewModelScope.launch {
            val sys = openSystem()
            if (sys == null) {
                notice(L10n.t(R.string.s_0678bae007))
                return@launch
            }
            val destNames = withContext(Dispatchers.IO) {
                runCatching { sys.list(destDir).map { it.name }.toSet() }.getOrDefault(emptySet())
            }
            val conflicts = sources
                .map { it.trimEnd('/').substringAfterLast('/') }
                .filter { it in destNames }
                .distinct()
            if (conflicts.isEmpty()) {
                launchTransfers(sys, sources, destDir, move, ConflictPolicy.RENAME)
            } else {
                pendingBatch = PendingBatch(sources, destDir, move, conflicts)
                promptNextConflict()
            }
        }
    }

    /** 待决的一批复制/移动：逐个询问冲突策略后按策略分组启动引擎。 */
    private class PendingBatch(
        val sources: List<String>,
        val destDir: String,
        val move: Boolean,
        val conflictNames: List<String>,
    ) {
        /** 已决策的冲突（name → 策略），size 即「下一个待问序号」。 */
        val decisions = LinkedHashMap<String, ConflictPolicy>()
    }

    private var pendingBatch: PendingBatch? = null

    private fun promptNextConflict() {
        val batch = pendingBatch ?: return
        val index = batch.decisions.size
        check(index < batch.conflictNames.size)
        _state.update {
            it.copy(
                conflictPrompt = ConflictPrompt(
                    name = batch.conflictNames[index],
                    index = index + 1,
                    total = batch.conflictNames.size,
                ),
            )
        }
    }

    /** 冲突对话框决策：记录当前项（applyToAll 时其余冲突同策略），推进或启动传输。 */
    fun resolveConflict(policy: ConflictPolicy, applyToAll: Boolean) {
        val batch = pendingBatch ?: return
        val index = batch.decisions.size
        if (index >= batch.conflictNames.size) return
        batch.decisions[batch.conflictNames[index]] = policy
        if (applyToAll) {
            batch.conflictNames.drop(index + 1).forEach { batch.decisions[it] = policy }
        }
        if (batch.decisions.size >= batch.conflictNames.size) {
            finishConflictBatch()
        } else {
            promptNextConflict()
        }
    }

    /** 整批放弃（对话框取消）：一个文件也不动。 */
    fun cancelConflictResolution() {
        pendingBatch = null
        _state.update { it.copy(conflictPrompt = null) }
    }

    private fun finishConflictBatch() {
        val batch = pendingBatch ?: return
        pendingBatch = null
        _state.update { it.copy(conflictPrompt = null) }
        // 按策略分组（跳过的不下发；无冲突项默认进 RENAME 组保持原行为）
        val groups = LinkedHashMap<ConflictPolicy, MutableList<String>>()
        var skipped = 0
        for (source in batch.sources) {
            val name = source.trimEnd('/').substringAfterLast('/')
            val policy = batch.decisions[name] ?: ConflictPolicy.RENAME
            if (policy == ConflictPolicy.SKIP && name in batch.conflictNames) {
                skipped++
                continue
            }
            groups.getOrPut(policy) { mutableListOf() }.add(source)
        }
        viewModelScope.launch {
            val sys = openSystem()
            if (sys == null) {
                notice(L10n.t(R.string.s_0678bae007))
                return@launch
            }
            var started = 0
            for ((policy, srcs) in groups) {
                started += launchTransfers(sys, srcs, batch.destDir, batch.move, policy, quiet = true)
            }
            notice(
                buildString {
                    append(if (batch.move) L10n.t(R.string.s_4cc30bf4c4, (started)) else L10n.t(R.string.s_6a67c171fb, (started)))
                    if (skipped > 0) append(L10n.t(R.string.s_71c5801e44, (skipped)))
                },
            )
        }
    }

    /** 向引擎下发一组传输；返回成功启动的源数量（0/1 个引擎调用）。 */
    private suspend fun launchTransfers(
        sys: SuperFiles,
        sources: List<String>,
        destDir: String,
        move: Boolean,
        policy: ConflictPolicy,
        quiet: Boolean = false,
    ): Int {
        if (sources.isEmpty()) return 0
        val result = withContext(Dispatchers.IO) {
            runCatching {
                if (move) sys.startMove(sources, destDir, policy)
                else sys.startCopy(sources, destDir, policy)
            }
        }
        return result
            .fold(
                onSuccess = { id ->
                    if (move) moveTaskIds.add(id)
                    // 前台进度浮层：先不让它进传输中心/通知，等用户选「后台传输」
                    _state.update {
                        it.copy(
                            foregroundTransfers = it.foregroundTransfers + id,
                            foregroundMoves = if (move) it.foregroundMoves + id else it.foregroundMoves,
                        )
                    }
                    // 引擎已在 Rust 侧登记句柄，立刻拉一拍把浮层顶出来
                    pollTransfersOnce()
                    sources.size
                },
                onFailure = {
                    report(it)
                    0
                },
            )
    }

    // ---- 设置页数据 ----

    /** 更新本地昵称（头像字取昵称末字，如「林悦」→「悦」）。 */
    fun updateNickname(raw: String) {
        val name = raw.trim().ifEmpty { L10n.t(R.string.s_0ed27cbb38) }
        prefs.edit().putString(KEY_USER_NICKNAME, name).apply()
        _state.update { it.copy(userNickname = name, userAvatarChar = avatarCharOf(name)) }
    }

    /** 头像字：拉丁名取首字母大写（Tony→T），其余取最后一个字符（刘帅→帅）；空回退默认。 */
    private fun avatarCharOf(name: String): String {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) return L10n.t(R.string.s_1681525453)
        val first = trimmed.first()
        return if (first in 'a'..'z' || first in 'A'..'Z') {
            first.uppercaseChar().toString()
        } else {
            trimmed.last().toString()
        }
    }

    fun coreVersion(): String = runCatching { core.version() }.getOrDefault("-")

    fun indexEntryCount(): Long = runCatching { core.indexCount().toLong() }.getOrDefault(0L)

    fun indexFileBytes(): Long = runCatching {
        val dir = getApplication<Application>().filesDir
        dir.listFiles { f -> f.name.startsWith("index") }?.sumOf { it.length() } ?: 0L
    }.getOrDefault(0L)

    /** 当前根最近一次扫描时间（无记录返回 null）。 */
    fun lastScanAt(): Long? = prefs.getLong(scanCooldownKey(core.rootId()), 0L).takeIf { it > 0 }

    fun clearIndex() {
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { runCatching { core.clearIndex() } }
            result
                .onSuccess {
                    _state.update { it.copy(indexedCount = 0) }
                    notice(L10n.t(R.string.s_b3d221eddb))
                }
                .onFailure(::report)
        }
    }

    /** 生成诊断包（版本/设备/索引/挂载/传输 + 本应用日志），返回分享用的文件。 */
    fun exportDiagnostics(context: android.content.Context): File? = runCatching {
        val sb = StringBuilder()
        sb.appendLine(L10n.t(R.string.s_2de1be5cfb))
        sb.appendLine(L10n.t(R.string.s_fa3aaeb003, (java.text.DateFormat.getDateTimeInstance().format(java.util.Date()))))
        sb.appendLine("App: ${coreVersion()} (${context.packageName})")
        sb.appendLine(L10n.t(R.string.s_fad0b49555, (android.os.Build.MANUFACTURER), (android.os.Build.MODEL), (android.os.Build.VERSION.RELEASE), (android.os.Build.VERSION.SDK_INT), (android.os.Build.SUPPORTED_ABIS.joinToString())))
        sb.appendLine(L10n.t(R.string.s_c1bc1fb2da, (android.os.Environment.isExternalStorageManager())))
        sb.appendLine(L10n.t(R.string.s_f2ec063492, (_state.value.rootKind), (indexEntryCount()), (indexFileBytes())))
        sb.appendLine(L10n.t(R.string.s_a276398784) + _state.value.networkMounts.joinToString { L10n.t(R.string.s_23afcde132, (it.config.name), (it.config.protocol), (if (it.rootId != null) L10n.t(R.string.s_68905cf391) else L10n.t(R.string.s_f050778f9f, (it.error)))) })
        sb.appendLine(L10n.t(R.string.s_f4b947bc1d) + _state.value.transfers.joinToString { "${it.id}=${it.state} ${it.bytesDone}/${it.bytesTotal}" })
        sb.appendLine(L10n.t(R.string.s_2bb58bf71b) + _state.value.resumable.joinToString { it.id })
        sb.appendLine(L10n.t(R.string.s_f12ee6c266))
        sb.appendLine(SfLog.tail())
        sb.appendLine("---- logcat ----")
        // 拿到 READ_LOGS（adb 授予，见 AndroidManifest 注释）时导完整主日志；
        // 否则退回本应用 tag 过滤——普通应用读 logcat 本就只见自己 UID 的输出。
        val readLogsGranted = androidx.core.content.ContextCompat.checkSelfPermission(
            context, android.Manifest.permission.READ_LOGS,
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        if (readLogsGranted) {
            sb.appendLine(L10n.t(R.string.s_6c529e878e))
            sb.appendLine(
                runCatching {
                    val p = ProcessBuilder("logcat", "-d", "-t", "1000", "-b", "main")
                        .redirectErrorStream(true).start()
                    p.inputStream.bufferedReader().readText().also { p.waitFor() }
                }.getOrElse { L10n.t(R.string.s_dabbe9372c, (it.message)) },
            )
        } else {
            sb.appendLine(L10n.t(R.string.s_2963f3c15e, (context.packageName)))
            sb.appendLine(
                runCatching {
                    val p = ProcessBuilder("logcat", "-d", "-t", "300", "-s", "SuperFiles:V", "SuperFiles:E", "AndroidRuntime:E")
                        .redirectErrorStream(true).start()
                    p.inputStream.bufferedReader().readText().also { p.waitFor() }
                }.getOrElse { L10n.t(R.string.s_dabbe9372c, (it.message)) },
            )
        }
        val dir = File(context.cacheDir, "diagnostics").apply { mkdirs() }
        val name = "diagnostics-${System.currentTimeMillis()}.txt"
        File(dir, name).apply { writeText(sb.toString()) }
    }.getOrNull()

    // ---- 文件操作（「⋯」操作菜单：复制/上传/详情/压缩/重命名/打开方式） ----

    fun renameEntry(entry: Entry, newName: String) {
        val name = newName.trim()
        if (name.isEmpty() || name == entry.name) return
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { runCatching { core.rename(entry.id, name) } }
            result
                .onSuccess {
                    refreshCurrent()
                    refreshCategoryStats()
                    notice(L10n.t(R.string.s_f4f64b6654, (name)))
                }
                .onFailure(::report)
        }
    }

    /** 复制到目标目录；同名冲突自动加后缀（Renamed），后台任务由 Rust 引擎驱动。 */
    fun copyEntryTo(entry: Entry, dest: Entry) {
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching { core.startCopy(listOf(entry.id), dest.id, ConflictPolicy.RENAME) }
            }
            result
                .onSuccess { id ->
                    // 与批量复制同一条前台浮层通道
                    _state.update { it.copy(foregroundTransfers = it.foregroundTransfers + id) }
                    notice(L10n.t(R.string.s_26fd85dbbf, (dest.name)))
                }
                .onFailure(::report)
        }
    }

    /** 压缩单个条目（「⋯」菜单入口）。 */
    fun compressEntry(entry: Entry, dest: Entry, zipName: String, deflate: Boolean) =
        compressEntries(listOf(entry.id), dest, zipName, deflate)

    /** 压缩到目标目录（可批量多源）；进度通过 ZipProgressListener 回流到 state.compress。 */
    fun compressEntries(sources: List<String>, dest: Entry, zipName: String, deflate: Boolean) {
        if (sources.isEmpty()) return
        if (_state.value.compress != null) return // 同一时刻只允许一个压缩任务（v1）
        _state.update { it.copy(compress = CompressState(done = 0, total = 0)) }
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    core.compressZip(
                        sources,
                        dest.id,
                        zipName,
                        if (deflate) ZipMethod.DEFLATE else ZipMethod.STORE,
                        object : ZipProgressListener {
                            override fun onProgress(done: ULong, total: ULong) {
                                _state.update {
                                    it.copy(compress = CompressState(done.toLong(), total.toLong()))
                                }
                            }
                        },
                    )
                }
            }
            _state.update { it.copy(compress = null) }
            result
                .onSuccess { out ->
                    refreshCurrent()
                    refreshCategoryStats()
                    notice(L10n.t(R.string.s_c8c6277159, (out.name)))
                }
                .onFailure(::report)
        }
    }

    // ---- 就近分享（ADR 0005）：内网链接 + 二维码；浏览器免安装可收 ----

    /** 实际承载分享会话的内核（用于关闭时精确回收，避免服务残留）。 */
    private var shareHost: SuperFiles? = null

    /**
     * 分享选中文件：仅文件可分享（目录请先用「压缩」打包）。
     *
     * 统一在 systemCore（根 = `/`，所有网络挂载也在这里）上起服务：搜索结果 /
     * 收藏 / 最近打开里的条目可能来自任意根，用当前浏览核会导致本地后端
     * 报 `path escapes local root`。
     */
    fun startShare(entries: List<Entry>) {
        if (entries.isEmpty()) return
        if (entries.any { it.kind == EntryKind.DIRECTORY }) {
            notice(L10n.t(R.string.s_a385d3efa6))
            return
        }
        viewModelScope.launch {
            // 先试 systemCore（根 `/` + 全部网络挂载，覆盖面最大）；极端情况下它
            // 打不开时退回当前浏览核再试一次。
            val candidates = listOfNotNull(openSystem(), core).distinct()
            val previousHost = shareHost
            var lastError: Throwable? = null
            for (host in candidates) {
                val result = withContext(Dispatchers.IO) {
                    runCatching { host.startShare(entries.map { it.id }) }
                }
                result
                    .onSuccess { info ->
                        // 换内核时显式关掉旧会话，避免旧服务继续在局域网可见
                        if (previousHost != null && previousHost !== host) {
                            withContext(Dispatchers.IO) {
                                runCatching { previousHost.stopShare() }
                            }
                        }
                        shareHost = host
                        _state.update { it.copy(shareInfo = info) }
                        return@launch
                    }
                lastError = result.exceptionOrNull()
            }
            lastError?.let(::report)
        }
    }

    /** 关闭分享（分享页 dismiss 时也调用：即焚语义）。 */
    fun stopShare() {
        val host = shareHost
        shareHost = null
        viewModelScope.launch {
            withContext(Dispatchers.IO) {
                runCatching { (host ?: core).stopShare() }
            }
            _state.update { it.copy(shareInfo = null) }
        }
    }

    // ---- LocalSend 近邻传输：HTTPS 接收 + 组播发现 + 发送 ----

    fun startLocalSend() {
        if (_state.value.localSendRunning || _state.value.localSendBusy) return
        viewModelScope.launch {
            _state.update { it.copy(localSendBusy = true) }
            // 组播锁必须在 join multicast 之前拿到，否则 Android 上收不到包。
            acquireMulticastLock()
            val destId = localSendDestDir()
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    val core = openSystem() ?: appCore
                    val store = File(getApplication<Application>().filesDir, "localsend").apply { mkdirs() }
                    // 网络挂载是 VFS id（smb://…），不能用 File 创建目录。
                    if (destId.startsWith("/")) {
                        val dest = File(destId).apply { mkdirs() }
                        migrateOldLocalSendFiles(dest)
                    }
                    val opts = com.superfiles.core.LocalSendOptions(
                        alias = _state.value.userNickname.ifBlank { android.os.Build.MODEL },
                        deviceModel = android.os.Build.MODEL,
                        port = 53317u,
                        storeDir = store.absolutePath,
                        destDir = destId,
                        pin = null,
                        enableDiscovery = true,
                        // 安全：无传输活动自动关闭监听（用户可配，0=永不）。
                        idleTimeoutSecs = _state.value.localSendIdleSecs.toULong(),
                    )
                    val handle = core.startLocalSend(opts)
                    localSendHandle = handle
                    handle.info()
                }
            }
            result
                .onSuccess { info ->
                    _state.update {
                        it.copy(
                            localSendRunning = true,
                            localSendBusy = false,
                            localSendInfo = info,
                            localSendDest = destId,
                            localSendDestName = localSendDestLabel(),
                            localSendStartError = null,
                        )
                    }
                    localSendLastFileCount =
                        if (destId.startsWith("/")) countFiles(File(destId)) else -1
                    seedLocalSendRecvBaseline(destId)
                    notice(L10n.t(R.string.s_6627878273, (info.alias)))
                    startLocalSendPolling()
                    refreshLocalSendPeers()
                }
                .onFailure {
                    releaseMulticastLock()
                    val msg = friendlyError(it)
                    _state.update { it.copy(localSendBusy = false, localSendStartError = msg) }
                    report(it)
                }
        }
    }

    /** 接收目录：有「所有文件访问」时放系统 Download/superfiles，否则应用沙盒。 */
    /** 旧版本收在应用沙盒；升级后首次开启时搬到可见目录，避免用户找不到。 */
    private fun migrateOldLocalSendFiles(newDir: File) {
        val old = File(getApplication<Application>().filesDir, "storage/LocalSend")
        if (!old.isDirectory || old.absolutePath == newDir.absolutePath) return
        old.listFiles()?.forEach { src ->
            if (!src.isFile) return@forEach
            val base = src.nameWithoutExtension
            val ext = src.extension.takeIf { it.isNotEmpty() }?.let { ".$it" } ?: ""
            var dst = File(newDir, src.name)
            var index = 1
            while (dst.exists()) {
                dst = File(newDir, "$base ($index)$ext")
                index++
            }
            runCatching {
                src.copyTo(dst, overwrite = false)
                src.delete()
            }
        }
    }

    fun localSendDestDir(): String {
        prefs.getString(KEY_LOCAL_SEND_DEST_ID, null)?.takeIf { it.isNotBlank() }?.let {
            return it
        }
        // 默认落在「应用存储」根目录
        return appRootPath()
    }

    fun localSendDestLabel(): String {
        prefs.getString(KEY_LOCAL_SEND_DEST_NAME, null)?.takeIf { it.isNotBlank() }?.let {
            return it
        }
        return L10n.t(R.string.s_99f7a465ec)
    }

    /** 用户选择接收位置（支持本地/共享/NAS）。运行中会自动重启监听以生效。 */
    fun setLocalSendDestination(id: String, name: String) {
        if (id.isBlank()) return
        prefs.edit()
            .putString(KEY_LOCAL_SEND_DEST_ID, id)
            .putString(KEY_LOCAL_SEND_DEST_NAME, name)
            .apply()
        _state.update { it.copy(localSendDest = id, localSendDestName = name) }
        if (_state.value.localSendRunning) {
            restartLocalSend()
        } else {
            notice(L10n.t(R.string.s_7b5809b1d7, (name)))
        }
    }

    private fun restartLocalSend() {
        val handle = localSendHandle
        localSendHandle = null
        localSendPollJob?.cancel()
        localSendPollJob = null
        releaseMulticastLock()
        _state.update {
            it.copy(
                localSendRunning = false,
                localSendInfo = null,
                localSendPeers = emptyList(),
                localSendBusy = false,
            )
        }
        viewModelScope.launch {
            if (handle != null) {
                withContext(Dispatchers.IO) { runCatching { handle.stop() } }
            }
            startLocalSend()
        }
    }

    /** 从近邻传输页跳到接收目录。 */
    fun openLocalSendFolder() {
        val dir = localSendDestDir()
        val target = openSystem() ?: appCore
        core = target
        history.clear()
        _state.update {
            it.copy(
                rootKind = BrowserRoot.System,
                filterLabel = null,
                filterExts = emptySet(),
                searchQuery = "",
                actionsTarget = null,
                selectionMode = false,
                selectedIds = emptySet(),
            )
        }
        load(dir)
    }

    private fun countFiles(dir: File): Int =
        runCatching { dir.listFiles()?.count { it.isFile } ?: 0 }.getOrDefault(0)

    fun stopLocalSend() {
        localSendPollJob?.cancel()
        localSendPollJob = null
        val handle = localSendHandle
        localSendHandle = null
        releaseMulticastLock()
        _state.update {
            it.copy(
                localSendRunning = false,
                localSendInfo = null,
                localSendPeers = emptyList(),
                localSendErrors = emptyList(),
                localSendSendError = null,
                localSendStartError = null,
            )
        }
        if (handle != null) {
            viewModelScope.launch(Dispatchers.IO) { runCatching { handle.stop() } }
        }
        notice(L10n.t(R.string.s_803c17b87c))
    }

    /** 发送面板打开/点刷新时调用：没有服务就先自动开启，再广播一次并拉取设备。 */
    fun refreshLocalSendPeers() {
        val handle = localSendHandle
        if (handle == null) {
            if (!_state.value.localSendBusy) startLocalSend()
            return
        }
        viewModelScope.launch {
            withContext(Dispatchers.IO) { runCatching { handle.announce() } }
            kotlinx.coroutines.delay(500)
            val peers = withContext(Dispatchers.IO) {
                runCatching { handle.peers() }.getOrDefault(emptyList())
            }
            val errors = withContext(Dispatchers.IO) {
                runCatching { handle.errors() }.getOrDefault(emptyList())
            }
            _state.update { it.copy(localSendPeers = peers, localSendErrors = errors) }
        }
    }

    fun ensureLocalSendStarted() {
        if (!_state.value.localSendRunning && !_state.value.localSendBusy) {
            startLocalSend()
        }
    }

    /** 组网深链（两端同契约）：superfiles://localsend?ip=..（扫码/系统深链共用）。 */
    fun registerFromLocalSendLink(link: String) {
        val uri = runCatching { android.net.Uri.parse(link) }.getOrNull() ?: return
        if (uri.scheme != "superfiles" || uri.host != "localsend") return
        val ip = uri.getQueryParameter("ip")?.trim().orEmpty()
        if (ip.isEmpty()) return
        val port = uri.getQueryParameter("port")?.toIntOrNull() ?: 53317
        val fp = uri.getQueryParameter("fp")?.trim()?.takeIf { it.isNotBlank() }
        ensureLocalSendStarted()
        viewModelScope.launch {
            // 深链可能在服务冷启动前到达：等接收服务起来（最多 ~6s）
            var tries = 0
            while (localSendHandle == null && tries < 12) {
                kotlinx.coroutines.delay(500)
                tries++
            }
            registerLocalSendPeer(ip, port, fp) { ok, err ->
                notice(
                    if (ok) L10n.t(R.string.s_lswiz_peer_added, ip)
                    else err ?: L10n.t(R.string.s_lswiz_bad),
                )
            }
        }
    }

    /** 本机私网 IPv4（Wi-Fi / 热点候选），组网码展示用。 */
    fun localSendIps(): List<String> = runCatching {
        val out = LinkedHashSet<String>()
        java.util.Collections.list(java.net.NetworkInterface.getNetworkInterfaces()).forEach { nif ->
            nif.interfaceAddresses.forEach { ia ->
                val addr = ia.address
                if (addr is java.net.Inet4Address && !addr.isLoopbackAddress && addr.isSiteLocalAddress) {
                    addr.hostAddress?.let { out.add(it) }
                }
            }
        }
        out.toList()
    }.getOrDefault(emptyList())

    /** 「无传输活动自动关闭」时长（秒，0=永不）：持久化；运行中重启服务即时生效。 */
    fun setLocalSendIdleSecs(secs: Long) {
        if (secs < 0) return
        prefs.edit().putLong(KEY_LS_IDLE_SECS, secs).apply()
        _state.update { it.copy(localSendIdleSecs = secs) }
        if (_state.value.localSendRunning) {
            restartLocalSend()
        }
    }

    /** 手动 IP 兜底：组播被 AP 隔离时直接连对方。 */
    fun registerLocalSendPeer(
        ip: String,
        port: Int,
        fingerprint: String?,
        onResult: (Boolean, String?) -> Unit,
    ) {
        val handle = localSendHandle
        if (handle == null) {
            onResult(false, L10n.t(R.string.s_3dda6522db))
            return
        }
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    handle.registerAt(
                        ip.trim(),
                        (port.takeIf { it > 0 } ?: 53317).toUShort(),
                        fingerprint?.trim()?.takeIf { it.isNotBlank() },
                    )
                }
            }
            result
                .onSuccess { peer ->
                    _state.update { s ->
                        s.copy(
                            localSendPeers = s.localSendPeers
                                .filterNot { it.ip == peer.ip && it.port == peer.port } + peer,
                        )
                    }
                    onResult(true, null)
                }
                .onFailure { onResult(false, friendlyError(it)) }
        }
    }

    fun sendViaLocalSend(
        peer: com.superfiles.core.LocalSendPeer,
        entries: List<Entry>,
        onResult: (Boolean, String?) -> Unit = { _, _ -> },
    ) {
        if (entries.isEmpty()) {
            onResult(false, L10n.t(R.string.s_ebef679e28))
            return
        }
        // LocalSend 只传文件；文件夹需要先压缩成 zip。
        val files = entries.filter { it.kind != EntryKind.DIRECTORY }
        if (files.isEmpty()) {
            onResult(false, L10n.t(R.string.s_6450df37e9))
            return
        }
        if (files.size != entries.size) {
            notice(L10n.t(R.string.s_72cc0122aa, (entries.size - files.size)))
        }
        val handle = localSendHandle
        if (handle == null) {
            onResult(false, L10n.t(R.string.s_3dda6522db))
            return
        }
        viewModelScope.launch {
            _state.update { it.copy(localSendBusy = true) }
            // 组播锁必须在 join multicast 之前拿到，否则 Android 上收不到包。
            acquireMulticastLock()
            val result = withContext(Dispatchers.IO) {
                runCatching { handle.send(peer, files.map { it.id }) }
            }
            _state.update { it.copy(localSendBusy = false) }
            result
                .onSuccess {
                    notice(L10n.t(R.string.s_52eecbbc3c, (peer.alias)))
                    recordLocalSendSends(files, peer.alias)
                    onResult(true, null)
                }
                .onFailure {
                    val msg = friendlyError(it)
                    notice(L10n.t(R.string.s_71e1eaada9, (msg)))
                    onResult(false, msg)
                }
        }
    }

    /** 发出侧也记近邻流水（传输中心「近邻传输」分组）。 */
    private fun recordLocalSendSends(files: List<Entry>, peerAlias: String) {
        val now = System.currentTimeMillis()
        val items = files.map {
            LocalSendReceived(it.name, it.size.toLong(), now, incoming = false, peer = peerAlias)
        }
        _state.update { s ->
            s.copy(localSendRecords = (items + s.localSendRecords).take(50))
        }
    }

    /**
     * 传输中心近邻流水：左滑移除单条。流水只是内存态展示（take(50) 滚动窗口），
     * 近邻传输页的「已接收」清单独立维护，这里删它不影响那份清单。
     */
    fun removeLocalSendRecord(record: LocalSendReceived) {
        _state.update { s ->
            s.copy(localSendRecords = s.localSendRecords.filterNot { it.seq == record.seq })
        }
    }

    private fun acquireMulticastLock() {
        runCatching {
            val wifi = getApplication<Application>()
                .getSystemService(android.content.Context.WIFI_SERVICE) as android.net.wifi.WifiManager
            localSendMulticastLock = wifi.createMulticastLock("superfiles-localsend").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
    }

    private fun releaseMulticastLock() {
        runCatching { localSendMulticastLock?.release() }
        localSendMulticastLock = null
    }

    private fun startLocalSendPolling() {
        localSendPollJob?.cancel()
        localSendPollJob = viewModelScope.launch {
            while (true) {
                val handle = localSendHandle ?: break
                val stillRunning = withContext(Dispatchers.IO) {
                    runCatching { handle.isRunning() }.getOrDefault(true)
                }
                if (!stillRunning) {
                    localSendHandle = null
                    releaseMulticastLock()
                    _state.update {
                        it.copy(
                            localSendRunning = false,
                            localSendInfo = null,
                            localSendPeers = emptyList(),
                            localSendBusy = false,
                        )
                    }
                    notice(L10n.t(R.string.s_fb54ebc2d5))
                    break
                }
                val peers = withContext(Dispatchers.IO) {
                    runCatching { handle.peers() }.getOrDefault(emptyList())
                }
                val errors = withContext(Dispatchers.IO) {
                    runCatching { handle.errors() }.getOrDefault(emptyList())
                }
                val dest = _state.value.localSendDest
                if (dest.isNotBlank() && dest.startsWith("/")) {
                    val count = withContext(Dispatchers.IO) { countFiles(File(dest)) }
                    if (localSendLastFileCount >= 0 && count > localSendLastFileCount) {
                        val added = count - localSendLastFileCount
                        notice(L10n.t(R.string.s_1b382382fe, (added), (localSendDestLabel())))
                    }
                    localSendLastFileCount = count
                }
                pollLocalSendRecv(dest)
                _state.update { it.copy(localSendPeers = peers, localSendErrors = errors) }
                kotlinx.coroutines.delay(3000)
            }
        }
    }

    /** (文件名, 字节数) 快照；.tmp 过程文件跳过（内核接收完成才落定命名）。 */
    private fun currentRecvEntries(destId: String): List<Pair<String, Long>> {
        if (destId.isBlank()) return emptyList()
        return runCatching {
            if (destId.startsWith("/")) {
                File(destId).listFiles()?.filter { it.isFile && !it.name.endsWith(".tmp") }
                    ?.map { it.name to it.length() } ?: emptyList()
            } else {
                core.list(destId).filter { it.kind == EntryKind.FILE && !it.name.endsWith(".tmp") }
                    .map { it.name to it.size.toLong() }
            }
        }.getOrDefault(emptyList())
    }

    /** 建立接收目录基线（开启接收时已存在的文件不算「新到」）。 */
    private fun seedLocalSendRecvBaseline(destId: String) {
        viewModelScope.launch(Dispatchers.IO) {
            localSendSeenNames.clear()
            localSendSeenNames.addAll(currentRecvEntries(destId).map { it.first })
            localSendBaselineReady = true
        }
    }

    /** 接收到账对账：差集 → 常驻「已接收」清单 + 瞬时提示（清单解决“弹完就找不到”）。 */
    private fun pollLocalSendRecv(destId: String) {
        if (destId.isBlank() || !localSendBaselineReady) return
        viewModelScope.launch {
            val entries = withContext(Dispatchers.IO) { currentRecvEntries(destId) }
            val fresh = entries.filter { it.first !in localSendSeenNames }
            if (fresh.isEmpty()) return@launch
            localSendSeenNames.addAll(fresh.map { it.first })
            val now = System.currentTimeMillis()
            val items = fresh.map { LocalSendReceived(it.first, it.second, now) }
            _state.update { s ->
                s.copy(
                    localSendReceived = (items.asReversed() + s.localSendReceived).take(20),
                    localSendRecords = (items + s.localSendRecords).take(50),
                )
            }
            notice(L10n.t(R.string.s_1b382382fe, (fresh.size), (localSendDestLabel())))
        }
    }

    /** 系统分享面板 → 用户选目录 → 流式写入目标 VFS（支持本地/共享/网络）。 */
    fun importSharedUris(uris: List<android.net.Uri>, destId: String, destName: String) {
        if (uris.isEmpty()) return
        viewModelScope.launch {
            _state.update { it.copy(shareImport = ShareImportState(0, uris.size, destName)) }
            val core = openSystem() ?: appCore
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    ShareIntake.importToVfs(
                        context = getApplication(),
                        core = core,
                        uris = uris,
                        destId = destId,
                    ) { done, total ->
                        _state.update { it.copy(shareImport = ShareImportState(done, total, destName)) }
                    }
                }
            }
            _state.update { it.copy(shareImport = null) }
            result
                .onSuccess { count ->
                    if (count > 0) {
                        notice(L10n.t(R.string.s_ba247f8ade, (count), (destName)))
                        refreshCurrent()
                    } else {
                        notice(L10n.t(R.string.s_7b4fcc53c3))
                    }
                }
                .onFailure { report(it) }
        }
    }

    fun dismissIncomingShare() = _state.update { it.copy(incomingShare = null) }

    /** 「接收文件」第一步：粘贴链接 → 拉 manifest.json 清单。 */
    fun fetchShareManifest(rawUrl: String) {
        var base = rawUrl.trim()
        if (!base.startsWith("http://") && !base.startsWith("https://")) {
            notice(L10n.t(R.string.s_c3de0f6d46))
            return
        }
        if (!base.endsWith("/")) base += "/"
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    val body = httpGet(base + "manifest.json", connectMs = 6000, readMs = 10000)
                    val json = org.json.JSONObject(body)
                    val arr = json.getJSONArray("files")
                    val files = (0 until arr.length()).map { i ->
                        val o = arr.getJSONObject(i)
                        ShareFileMeta(o.getString("name"), o.getLong("size"), o.getString("url"))
                    }
                    if (files.isEmpty()) error(L10n.t(R.string.s_d6076b1023))
                    ShareManifest(base, files)
                }
            }
            result
                .onSuccess { _state.update { s -> s.copy(incomingShare = it) } }
                .onFailure {
                    SfLog.e("fetch share manifest failed", it)
                    notice(L10n.t(R.string.s_e4d316931c))
                }
        }
    }

    /** 「接收文件」第二步：逐个 HTTP 分块拉取并写入当前目录（经 VFS，目标可以是 NAS）。 */
    fun receiveFiles() {
        val manifest = _state.value.incomingShare ?: return
        val destDir = _state.value.currentId.ifEmpty { core.rootId() }
        _state.update {
            it.copy(
                incomingShare = null,
                receive = ReceiveState(
                    filesTotal = manifest.files.size,
                    bytesTotal = manifest.files.sumOf { f -> f.size },
                ),
            )
        }
        viewModelScope.launch {
            val failures = withContext(Dispatchers.IO) {
                var failCount = 0
                var bytesDone = 0L
                val takenNames = _state.value.entries.map { it.name }.toMutableSet()
                manifest.files.forEachIndexed { index, meta ->
                    _state.update { s ->
                        s.copy(receive = s.receive?.copy(filesDone = index, currentName = meta.name))
                    }
                    runCatching {
                        val name = uniqueName(meta.name, takenNames)
                        takenNames += name
                        val entry = core.createFile(destDir, name)
                        try {
                            var offset = 0L
                            httpStreamEach(meta, manifest.baseUrl) { chunk ->
                                core.writeBytes(entry.id, offset.toULong(), chunk)
                                offset += chunk.size
                                bytesDone += chunk.size
                                val snapshot = bytesDone
                                _state.update { s ->
                                    s.copy(receive = s.receive?.copy(bytesDone = snapshot))
                                }
                            }
                        } catch (e: Exception) {
                            runCatching { core.remove(entry.id, false) } // 半成品即删，不留垃圾
                            throw e
                        }
                    }.onFailure {
                        failCount++
                        SfLog.e("receive file failed: ${meta.name}", it)
                    }
                }
                failCount
            }
            _state.update { it.copy(receive = null) }
            refreshCurrent()
            notice(
                if (failures == 0) {
                    L10n.t(R.string.s_b8da4a4781, (manifest.files.size))
                } else {
                    L10n.t(R.string.s_35042928d4, (manifest.files.size - failures), (failures))
                },
            )
        }
    }

    /** 出网卡断网/代理环境的兜底错误已转成中文提示；这里只做传输。 */
    private fun httpGet(url: String, connectMs: Int, readMs: Int): String {
        val conn = (java.net.URL(url).openConnection() as java.net.HttpURLConnection).apply {
            connectTimeout = connectMs
            readTimeout = readMs
        }
        try {
            if (conn.responseCode !in 200..299) error("HTTP ${conn.responseCode}")
            return conn.inputStream.bufferedReader().use { it.readText() }
        } finally {
            conn.disconnect()
        }
    }

    /** 分块回调；chunk 是精确长度的字节数组。 */
    private inline fun httpStreamEach(
        meta: ShareFileMeta,
        baseUrl: String,
        onChunk: (ByteArray) -> Unit,
    ) {
        val conn = (java.net.URL(baseUrl + meta.relUrl).openConnection() as java.net.HttpURLConnection).apply {
            connectTimeout = 6000
            readTimeout = 30_000
        }
        try {
            if (conn.responseCode !in 200..299) error("HTTP ${conn.responseCode}")
            conn.inputStream.use { input ->
                val buf = ByteArray(256 * 1024)
                var total = 0L
                while (true) {
                    val n = input.read(buf)
                    if (n <= 0) break
                    onChunk(buf.copyOf(n))
                    total += n
                }
                if (total != meta.size) error(L10n.t(R.string.s_d3a32fc024, (total), (meta.size)))
            }
        } finally {
            conn.disconnect()
        }
    }

    /** 重名避让：report.pdf → report-2.pdf、report-3.pdf…（不存在重名时原样返回）。 */
    private fun uniqueName(name: String, taken: Set<String>): String {
        if (name !in taken) return name
        val stem = name.substringBeforeLast('.', name)
        val ext = name.substringAfterLast('.', "")
        var n = 2
        while (true) {
            val candidate = if (ext.isEmpty()) "$stem-$n" else "$stem-$n.$ext"
            if (candidate !in taken) return candidate
            n++
        }
    }

    /** 详情页数据源（Entry + displayPath）。 */
    fun openDetails(entry: Entry) {
        viewModelScope.launch {
            val path = withContext(Dispatchers.IO) {
                runCatching { core.displayPath(entry.id) }.getOrDefault("")
            }
            _state.update { it.copy(details = EntryDetails(entry, path)) }
        }
    }

    /** 详情页「所在位置 ›」：跳进父目录（跨根自动路由；页面由 UI 关闭）。 */
    fun openParentOf(entry: Entry) {
        val parent = entry.parent ?: return
        viewModelScope.launch {
            val resolved = withContext(Dispatchers.IO) {
                val path = runCatching { core.displayPath(parent) }.getOrDefault(parent)
                val target = coreForPath(path)?.first ?: core
                runCatching { target.stat(parent) }.getOrNull()
            } ?: return@launch
            openEntry(resolved)
        }
    }

    /** 详情页「下载」：远端文件复制进应用存储（本地文件本就是本地，无操作）。 */
    fun downloadToAppStorage(entry: Entry) {
        if (isLocalEntry(entry) || entry.kind != EntryKind.FILE) return
        startTransfer(listOf(entry.id), appRootPath(), move = false)
    }

    fun dismissDetails() = _state.update { it.copy(details = null) }

    /** 打开文档预览页（只收文件；计入「最近打开」，与外部打开同一口径）。 */
    fun openDocPreview(entry: Entry) {
        if (entry.kind != EntryKind.FILE) return
        recordOpen(entry)
        _state.update { it.copy(docPreview = entry) }
    }

    fun dismissDocPreview() = _state.update { it.copy(docPreview = null) }

    /** 仅 DEBUG：adb 触发某个网络存储的索引重建（验证后台扫描/进度）。 */
    fun debugRebuildMount(rootId: String) {
        indexMountInBackground(rootId, "debug")
    }

    /** 仅 DEBUG：adb 触发一次分类筛选，用于测量耗时。 */
    fun debugApplyFilter(key: String) {
        val def = CATEGORY_DEFS.firstOrNull { it.first == key } ?: return
        applyTypeFilter(L10n.t(def.second), def.third)
    }

    /** 仅 DEBUG：从 intent 直接打开预览，供 adb 自动化验证（不影响正式包）。 */
    fun debugOpenPreview(id: String) {
        viewModelScope.launch(Dispatchers.IO) {
            runCatching { core.stat(id) }.onSuccess { entry ->
                if (entry.kind == EntryKind.FILE) openDocPreview(entry)
            }
        }
    }

    /** PDF 预览落地缓存用：按偏移读条目字节（阻塞 FFI → IO 线程）。 */
    suspend fun readEntryBytes(id: String, offset: Long, want: Int): ByteArray =
        withContext(Dispatchers.IO) { core.readBytes(id, offset.toULong(), want.toUInt()) }

    /** 打开「⋯」操作面板（首页最近列表与文件页共用）。 */
    fun showActions(entry: Entry) = _state.update { it.copy(actionsTarget = entry) }

    fun dismissActions() = _state.update { it.copy(actionsTarget = null) }

    fun dismissNotice() = _state.update { it.copy(notice = null) }

    fun notice(message: String) = _state.update { it.copy(notice = message) }

    /** 全树目录收集（压缩目标选择器；上限 200 个防失控；隐藏过滤与全局一致）。 */
    suspend fun collectDirs(): List<Entry> = withContext(Dispatchers.IO) {
        runCatching {
            val out = ArrayList<Entry>()
            val queue = ArrayDeque(listOf(core.rootId()))
            var guard = 0
            while (queue.isNotEmpty() && out.size < 200) {
                guard++
                val dir = queue.removeFirst()
                val entry = core.stat(dir)
                if (entry.kind == EntryKind.DIRECTORY) out.add(entry)
                // 不可读目录跳过；隐藏目录不下钻也不展示（与文件列表同规则）
                for (child in visible(runCatching { core.list(dir) }.getOrDefault(emptyList()))) {
                    if (child.kind == EntryKind.DIRECTORY) queue.addLast(child.id)
                    if (guard++ > 2000) break
                }
            }
            out.sortedBy { it.name }
        }.getOrDefault(emptyList())
    }

    /** 是否本地路径条目（网络挂载 id 形如 webdav://…，非本地）。 */
    fun isLocalEntry(entry: Entry): Boolean = entry.id.startsWith("/")

    /** 本地真实文件（供「打开方式」走 FileProvider 外发；远端走流式 Provider）。 */
    fun localFileOf(entry: Entry): File? {
        val path = runCatching { core.displayPath(entry.id) }.getOrNull() ?: return null
        val direct = File(path)
        if (direct.isAbsolute && direct.exists()) return direct
        // 兜底：拼到存储根下（displayPath 理论上已是绝对路径）
        val root = File(getApplication<Application>().filesDir, "storage")
        val nested = File(root, path.removePrefix("/"))
        return nested.takeIf { it.exists() }
    }

    /** 刷新当前视图（普通浏览 → 重载目录；类型筛选 → 重新过滤）。 */
    private fun refreshCurrent() {
        val s = _state.value
        if (s.filterExts.isNotEmpty()) {
            applyTypeFilter(s.filterLabel ?: return, s.filterExts)
        } else {
            load(s.currentId.ifEmpty { core.rootId() })
        }
    }

    // ---- 类型筛选（首页「我的文件夹」快捷入口） ----

    /** 全树遍历并按扩展名过滤（如 个人文档={csv,txt} / 工作资料={pdf,doc,docx,ppt,pptx}）。 */
    /** 首页发起进入文件页：下一次 load 成功后把当前目录记为 homeEntryRoot。 */
    private var armHomeEntry = false

    fun markHomeEntry() {
        armHomeEntry = true
    }

    fun clearHomeEntry() {
        armHomeEntry = false
        _state.update { it.copy(homeEntryRoot = null) }
    }

    /** 进入分类筛选前的目录，返回时恢复到这里（而不是内核根）。 */
    private var filterOriginId: String? = null

    /** 分类首屏每内核取这么多条：点开即出，剩下的一律后台续载。 */
    private val filterFirstPage = 240u
    /** 递增令牌：用户切走/换分类后，旧的后台加载结果直接丢弃。 */
    private var filterToken = 0

    /** 每内核按扩展名分页取一段，合并后返回（不做排序，调用方统一排）。 */
    private fun loadFilterSlice(offset: UInt, limit: UInt): List<Entry> {
        val cores = listOfNotNull(appCore, sharedCore)
        val out = ArrayList<Entry>()
        for (c in cores) {
            val bytes = runCatching {
                c.listByExtsPacked(extsForFilter, offset, limit, _state.value.showHidden)
            }.getOrDefault(ByteArray(0))
            out += com.superfiles.app.core.PackedEntries.decode(bytes)
        }
        return out
    }

    /** 当前分类筛选的扩展名（后台分页读取用；随 applyTypeFilter 更新）。 */
    private var extsForFilter: List<String> = emptyList()

    fun applyTypeFilter(label: String, exts: Set<String>) {
        if (exts.isEmpty()) return
        if (_state.value.filterExts.isEmpty()) {
            filterOriginId = _state.value.currentId.takeIf { it.isNotEmpty() }
        }
        extsForFilter = exts.toList()
        val token = ++filterToken
        viewModelScope.launch {
            val t0 = android.os.SystemClock.elapsedRealtime()
            // 立即清空旧列表：避免先显示上一个目录的内容再被图片替换
            _state.update {
                it.copy(
                    loading = true,
                    error = null,
                    searchQuery = "",
                    entries = emptyList(),
                    locationProvider = null,
                )
            }
            // 首屏：只取最新的几百条，解码成本可以忽略（点开即出）。
            val first = withContext(Dispatchers.IO) {
                loadFilterSlice(0u, filterFirstPage).distinctBy { it.id }
                    .sortedByDescending { it.modifiedMs ?: 0L }
            }
            if (token != filterToken) return@launch
            android.util.Log.d(
                "SuperFiles",
                "filter[$label] first page ${first.size} in ${android.os.SystemClock.elapsedRealtime() - t0}ms",
            )
            _state.update {
                it.copy(
                    loading = false,
                    filterLabel = label,
                    filterExts = exts,
                    entries = visible(first),
                    locationProvider = { entry -> locationOf(entry) },
                    title = L10n.t(R.string.s_045738c243, (label), (it.entries.size)),
                    canGoUp = false,
                    error = null,
                    offlineCacheMs = null,
                    selectionMode = false,
                    selectedIds = emptySet(),
                )
            }
            // 后台续载：一次性取完剩下的，合并排序后替换（用户此时已在看图）。
            val all = withContext(Dispatchers.IO) {
                val slice = runCatching { loadFilterSlice(filterFirstPage, UInt.MAX_VALUE) }
                    .getOrDefault(emptyList())
                (first + slice).distinctBy { it.id }.sortedByDescending { it.modifiedMs ?: 0L }
            }
            if (token != filterToken) return@launch
            android.util.Log.d(
                "SuperFiles",
                "filter[$label] full ${all.size} in ${android.os.SystemClock.elapsedRealtime() - t0}ms",
            )
            _state.update {
                if (it.filterExts != exts) {
                    it
                } else {
                    it.copy(
                        entries = visible(all),
                        title = L10n.t(R.string.s_045738c243, (label), (visible(all).size)),
                    )
                }
            }
        }
    }

    fun clearFilter() {
        if (_state.value.filterExts.isEmpty()) return
        filterToken++
        history.clear()
        _state.update {
            it.copy(filterLabel = null, filterExts = emptySet(), searchQuery = "")
        }
        val origin = filterOriginId
        filterOriginId = null
        load(origin ?: core.rootId())
    }

    // ---- 搜索焦点一次 signal（首页搜索框 → 文件 Tab 自动聚焦） ----

    fun requestSearchFocus() = _state.update { it.copy(searchFocusRequest = true) }

    fun consumeSearchFocus() = _state.update { it.copy(searchFocusRequest = false) }

    private fun extOf(name: String): String = name.substringAfterLast('.', "").lowercase()

    private companion object {
        const val KEY_SHOW_HIDDEN = "show_hidden"
        const val KEY_LS_IDLE_SECS = "ls_idle_secs"
        const val KEY_SCAN_DONE = "scan_done"
        const val KEY_NETWORK_MOUNTS = "network_mounts"
        const val KEY_NETWORK_MOUNTS_ENC = "network_mounts_enc"
        const val KEY_INDEX_PINS = "index_pins"
        const val KEY_SMB_SHARE_HISTORY = "smb_share_history"
        const val KEY_USER_NICKNAME = "user_nickname"
        const val KEY_LOCAL_SEND_DEST_ID = "local_send_dest_id"
        const val KEY_LOCAL_SEND_DEST_NAME = "local_send_dest_name"
    }

    private fun load(id: String) {
        viewModelScope.launch {
            _state.update { it.copy(loading = true, error = null) }
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    val entries = core.list(id)
                    val caps = core.capabilities(id)
                    val path = core.displayPath(id)
                    Triple(entries, caps, path)
                }
            }
            result
                .onSuccess { (entries, caps, path) ->
                    val fromHome = armHomeEntry
                    armHomeEntry = false
                    _state.update {
                        it.copy(
                            loading = false,
                            currentId = id,
                            homeEntryRoot = if (fromHome) id else it.homeEntryRoot,
                            entries = visible(entries),
                            locationProvider = null,
                            capabilities = caps,
                            canGoUp = history.isNotEmpty(),
                            title = path,
                            isCurrentFavorite = it.favoriteIds.contains(id),
                            error = null,
                            offlineCacheMs = null,
                            // 换目录即退出多选（旧选择对新列表无意义）
                            selectionMode = false,
                            selectedIds = emptySet(),
                        )
                    }
                    // 每次进入目录：后台异步刷新该子树的索引（不阻塞前台）；
                    // 全盘根（/）与网络存储不自动扫（前者无意义，后者走网络代价高）
                    if (_state.value.rootKind != BrowserRoot.System &&
                        _state.value.rootKind != BrowserRoot.Network
                    ) {
                        scanInBackground(id)
                    }
                }
                .onFailure { error ->
                    // M1 离线浏览：实时列举失败（断网/服务不可达/权限）回退索引缓存，
                    // 并以「上次更新时间」作过期标记；无缓存才报错。
                    val cached = withContext(Dispatchers.IO) {
                        runCatching { core.listCached(id) }.getOrNull()
                    }
                    if (cached != null && cached.entries.isNotEmpty()) {
                        SfLog.e("list failed; serving offline cache", error)
                        _state.update {
                            it.copy(
                                loading = false,
                                currentId = id,
                                entries = visible(cached.entries),
                                locationProvider = null,
                                capabilities = null,
                                canGoUp = history.isNotEmpty(),
                                title = runCatching { core.displayPath(id) }.getOrDefault(id),
                                isCurrentFavorite = it.favoriteIds.contains(id),
                                error = null,
                                offlineCacheMs = cached.listedAtMs,
                                selectionMode = false,
                                selectedIds = emptySet(),
                            )
                        }
                    } else {
                        report(error)
                    }
                }
        }
    }

    private fun report(error: Throwable) {
        SfLog.e("core call failed", error)
        _state.update { it.copy(loading = false, error = friendlyError(error)) }
    }

    override fun onCleared() {
        localSendPollJob?.cancel()
        releaseMulticastLock()
        val handle = localSendHandle
        localSendHandle = null
        if (handle != null) {
            Thread { runCatching { handle.stop() } }.start()
        }
        super.onCleared()
    }

    /**
     * UniFFI 生成的异常 message 模板是 `"detail=<原始信息>"`（见 superfiles.kt
     * SfException），直接上屏会露出 `detail=` 前缀；这里按异常类型转成人话。
     */
    private fun friendlyError(error: Throwable): String = when (error) {
        is SfException.NotFound -> L10n.t(R.string.s_40fa1e18f8, (error.detail))
        is SfException.PermissionDenied ->
            if (error.detail.contains("Android/data") || error.detail.contains("Android/obb")) {
                L10n.t(R.string.s_734b9bcdf7)
            } else {
                L10n.t(R.string.s_27d0b0f629, (error.detail))
            }
        is SfException.AlreadyExists -> L10n.t(R.string.s_4a3be11abb, (error.detail))
        is SfException.Unsupported -> L10n.t(R.string.s_8d09f0c9d9, (error.detail))
        is SfException.Network -> L10n.t(R.string.s_c533b51e70, (error.detail))
        is SfException.InvalidName -> L10n.t(R.string.s_99d80b493a, (error.detail))
        is SfException.Cancelled -> L10n.t(R.string.s_a45bac47f5)
        is SfException.Io ->
            when {
                error.detail.contains("Not connected", ignoreCase = true) ||
                    error.detail.contains("Transport", ignoreCase = true) ->
                    L10n.t(R.string.s_46be1661f2)
                error.detail.contains("Bad network name", ignoreCase = true) ||
                    error.detail.contains("0x00000cc", ignoreCase = true) ||
                    error.detail.contains("BAD_NETWORK_NAME", ignoreCase = true) ->
                    L10n.t(R.string.s_2c872b1ad4) +
                        L10n.t(R.string.s_32cb938fc6) +
                        L10n.t(R.string.s_031a6d4ef4)
                error.detail.contains("TransferSyntaxesNotSupported", ignoreCase = true) ||
                    error.detail.contains("BindAck", ignoreCase = true) ->
                    L10n.t(R.string.s_6340d9f50c)
                error.detail.contains("InvalidParameter", ignoreCase = true) ||
                    error.detail.contains("Logon failure", ignoreCase = true) ||
                    error.detail.contains("STATUS_LOGON_FAILURE", ignoreCase = true) ->
                    L10n.t(R.string.s_3953f6cae8)
                else -> L10n.t(R.string.s_f5b3638327, (error.detail))
            }
        else -> error.message ?: error::class.simpleName ?: L10n.t(R.string.s_974e748456)
    }
}
