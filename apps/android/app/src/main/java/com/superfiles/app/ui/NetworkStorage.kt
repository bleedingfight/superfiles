package com.superfiles.app.ui

import com.superfiles.app.L10n
import com.superfiles.app.R

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.Cloud
import androidx.compose.material.icons.outlined.CloudQueue
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material.icons.outlined.Lan
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.zIndex
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.foundation.layout.widthIn
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.roundToInt
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.superfiles.app.NetworkMountConfig
import com.superfiles.app.NetworkMountStatus
import com.superfiles.app.SmbHostInfo
import com.superfiles.app.VfsViewModel

/**
 * 网络存储面板：协议选择（WebDAV / SFTP / Samba）+ 连接表单 + 已保存连接列表。
 * 连接成功后点击条目直接进入浏览（挂载在 appCore，重启自动重连）。
 */
/** 各协议对应的描边图标（WebDAV=云、SMB=局域网、SFTP=终端）。 */
private enum class NetProtocol(
    val key: String,
    val label: String,
    val icon: ImageVector,
    @androidx.annotation.StringRes val hintRes: Int?,
    val fallbackHint: String = "",
) {
    Webdav("webdav", "WebDAV", Icons.Outlined.Cloud, null, "https://host/dav"),
    Sftp("sftp", "SFTP", Icons.Outlined.Terminal, R.string.s_9d2cff41c3),
    Smb("smb", "Samba (SMB)", Icons.Outlined.Lan, R.string.s_910ece51a1),
    S3("s3", "S3", Icons.Outlined.CloudQueue, null, "https://s3.amazonaws.com"),
}

private fun NetProtocol.hintText(): String =
    hintRes?.let { L10n.t(it) } ?: fallbackHint

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NetworkSheet(
    viewModel: VfsViewModel,
    onDismiss: () -> Unit,
    onBrowse: (NetworkMountStatus) -> Unit,
    /** 非空时直接进入编辑表单（首页长按「编辑连接」）。 */
    initialEdit: NetworkMountStatus? = null,
    /** 调试用：直接打开云盘列表。 */
    startInCloud: Boolean = false,
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    var mode by remember {
        mutableStateOf<NetMode>(
            initialEdit?.let { NetMode.Form(protoOf(it.config.protocol), editing = it) }
                ?: if (startInCloud) NetMode.CloudProviders else NetMode.List,
        )
    }
    var deleteTarget by remember { mutableStateOf<NetworkMountStatus?>(null) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = SfColors.Surface,
        // 由内容自己处理 IME/导航栏 insets，避免键盘弹出时输入框被遮挡
        contentWindowInsets = { WindowInsets(0, 0, 0, 0) },
    ) {
        // 内容可能超出弹层高度（自动扫描结果/共享列表/键盘）——整体可滚动，避免按钮被推出屏幕
        Column(
            modifier = Modifier
                // 平板/横屏：表单与列表限宽居中（docs/06 §7）
                .widthIn(max = Adaptive.ListMaxWidth)
                .align(Alignment.CenterHorizontally)
                .imePadding()
                .navigationBarsPadding()
                .verticalScroll(rememberScrollState())
                .padding(bottom = Dimens.Space6),
        ) {
            when (val m = mode) {
                NetMode.List -> {
                    // 标题 + 添加入口同样包进圆角卡片，与下方连接卡一致
                    Surface(
                        shape = androidx.compose.foundation.shape.RoundedCornerShape(Dimens.RadiusM),
                        color = SfColors.SurfaceCard,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = Dimens.Space4, vertical = Dimens.Space1),
                    ) {
                        SheetHeader(
                            title = L10n.t(R.string.s_5d4c75d1bb),
                            onBack = null,
                        ) {
                            TextButton(onClick = { mode = NetMode.ChooseProtocol }) { Text(L10n.t(R.string.s_b58c7549c0)) }
                        }
                    }
                    if (state.networkMounts.isEmpty()) {
                        Text(
                            L10n.t(R.string.s_cc00c3a5f5),
                            fontSize = 12.sp,
                            color = SfColors.OnSurfaceVariant,
                            modifier = Modifier.padding(horizontal = Dimens.Space6, vertical = Dimens.Space3),
                        )
                    } else {
                        LazyColumn(modifier = Modifier.heightIn(max = 360.dp)) {
                            items(state.networkMounts, key = { it.config.name }) { mount ->
                                Surface(
                                    shape = androidx.compose.foundation.shape.RoundedCornerShape(Dimens.RadiusM),
                                    color = SfColors.SurfaceCard,
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .padding(horizontal = Dimens.Space4, vertical = Dimens.Space1),
                                ) {
                                    MountRow(
                                        mount = mount,
                                        onOpen = { onBrowse(mount) },
                                        onEdit = {
                                            mode = NetMode.Form(protoOf(mount.config.protocol), editing = mount)
                                        },
                                        onDelete = { deleteTarget = mount },
                                    )
                                }
                            }
                        }
                    }
                    HorizontalDivider(modifier = Modifier.padding(vertical = Dimens.Space2))
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = 52.dp)
                            .clickable { mode = NetMode.CloudProviders }
                            .padding(horizontal = Dimens.Space6),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(Dimens.Space4),
                    ) {
                        Icon(Icons.Outlined.Cloud, contentDescription = null, tint = SfColors.Primary)
                        Column(Modifier.weight(1f)) {
                            Text(L10n.t(R.string.s_681f0e8555), fontSize = 14.sp, color = SfColors.OnSurface)
                            Text(L10n.t(R.string.s_f8b47dab5d), fontSize = 11.sp, color = SfColors.OnSurfaceVariant)
                        }
                    }
                }

                NetMode.ChooseProtocol -> {
                    SheetHeader(title = L10n.t(R.string.s_1956580477), onBack = { mode = NetMode.List })
                    NetProtocol.entries.forEach { proto ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .heightIn(min = 56.dp)
                                .clickable { mode = NetMode.Form(proto) }
                                .padding(horizontal = Dimens.Space6),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(Dimens.Space4),
                        ) {
                            Icon(proto.icon, contentDescription = null, tint = SfColors.Primary)
                            Column(Modifier.weight(1f)) {
                                Text(proto.label, fontSize = 14.sp, fontWeight = FontWeight.Medium, color = SfColors.OnSurface)
                                Text(proto.hintText(), fontSize = 11.sp, color = SfColors.OnSurfaceVariant)
                            }
                        }
                    }
                }

                NetMode.CloudProviders -> {
                    val context = LocalContext.current
                    val haptics = LocalHapticFeedback.current
                    val density = LocalDensity.current
                    var providers by remember {
                        mutableStateOf(
                            com.superfiles.app.cloud.CloudOrder.ordered(
                                context,
                                com.superfiles.app.cloud.CloudProviders.all,
                            ),
                        )
                    }
                    var hintFor by remember { mutableStateOf<String?>(null) }
                    val heights = remember { mutableStateMapOf<Int, Float>() }
                    var dragging by remember { mutableStateOf(-1) }
                    var dragOffset by remember { mutableStateOf(0f) }

                    SheetHeader(title = L10n.t(R.string.s_6c0912e5bb), onBack = { mode = NetMode.List })
                    providers.forEachIndexed { index, provider ->
                        val configured = provider.configured
                        val authed = com.superfiles.app.cloud.CloudAuthManager.hasToken(context, provider.id)
                        val isDragging = index == dragging
                        val currentIndex by rememberUpdatedState(index)
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .zIndex(if (isDragging) 1f else 0f)
                                .graphicsLayer {
                                    translationY = if (isDragging) dragOffset else 0f
                                    shadowElevation = if (isDragging) 6f else 0f
                                }
                                .onGloballyPositioned { coords ->
                                    heights[index] = coords.size.height.toFloat()
                                }
                                .pointerInput(provider.id) {
                                    detectDragGesturesAfterLongPress(
                                        onDragStart = {
                                            haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                                            dragging = currentIndex
                                            dragOffset = 0f
                                        },
                                        onDrag = { change, amount ->
                                            change.consume()
                                            dragOffset += amount.y
                                        },
                                        onDragEnd = {
                                            val from = currentIndex
                                            val h = heights[from]?.takeIf { it > 0f }
                                                ?: with(density) { 56.dp.toPx() }
                                            val shift = (dragOffset / h).roundToInt()
                                            val target = (from + shift)
                                                .coerceIn(0, providers.lastIndex)
                                            if (target != from) {
                                                val list = providers.toMutableList()
                                                val item = list.removeAt(from)
                                                list.add(target, item)
                                                providers = list
                                                com.superfiles.app.cloud.CloudOrder.save(context, list)
                                                heights.clear()
                                            }
                                            dragging = -1
                                            dragOffset = 0f
                                        },
                                        onDragCancel = {
                                            dragging = -1
                                            dragOffset = 0f
                                        },
                                    )
                                },
                        ) {
                            Column {
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .heightIn(min = 56.dp)
                                        .clickable {
                                            if (configured) {
                                                com.superfiles.app.cloud.CloudAuthManager
                                                    .startAuth(context, provider)
                                            } else {
                                                hintFor = if (hintFor == provider.id) null else provider.id
                                            }
                                        }
                                        .padding(horizontal = Dimens.Space6),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(Dimens.Space4),
                                ) {
                                    CloudProviderLogo(provider.id)
                                    Column(Modifier.weight(1f)) {
                                        Text(
                                            L10n.t(provider.displayNameRes),
                                            fontSize = 14.sp,
                                            color = SfColors.OnSurface,
                                        )
                                        Text(
                                            when {
                                                !configured -> L10n.t(R.string.s_8613606e5d)
                                                authed -> L10n.t(R.string.s_812545f64c)
                                                else -> L10n.t(R.string.s_13df49d82b)
                                            },
                                            fontSize = 11.sp,
                                            color = if (authed) SfColors.Success else SfColors.OnSurfaceVariant,
                                        )
                                    }
                                }
                                if (hintFor == provider.id) {
                                    Text(
                                        L10n.t(R.string.s_92e56dfe6a) +
                                            L10n.t(R.string.s_3a5af9d0d8),
                                        fontSize = 11.sp,
                                        color = SfColors.OnSurfaceVariant,
                                        modifier = Modifier.padding(
                                            horizontal = Dimens.Space6,
                                            vertical = Dimens.Space1,
                                        ),
                                    )
                                }
                            }
                        }
                    }
                    Text(
                        L10n.t(R.string.s_3e8d6cc31f),
                        fontSize = 11.sp,
                        color = SfColors.OnSurfaceVariant,
                        modifier = Modifier.padding(horizontal = Dimens.Space6, vertical = Dimens.Space2),
                    )
                }

                is NetMode.Form -> {
                    val proto = m.protocol
                    SheetHeader(
                        title = if (m.editing == null) {
                            L10n.t(R.string.s_373869b558, (proto.label))
                        } else {
                            L10n.t(R.string.s_6175e09bb1)
                        },
                        onBack = { mode = NetMode.List },
                    )
                    ConnectForm(
                        proto = proto,
                        editing = m.editing,
                        prefillHost = m.host,
                        prefillShare = m.share,
                        onScanLanSmb = viewModel::scanLanSmb,
                        rememberedShare = viewModel::lastShareFor,
                        onListShares = viewModel::listSmbShares,
                        onSubmit = { cfg, done ->
                            val editing = m.editing
                            val handler: (Boolean, String?) -> Unit = { ok, err ->
                                done(ok, err)
                                if (ok) mode = NetMode.List
                            }
                            if (editing == null) {
                                viewModel.addNetworkMount(cfg, onResult = handler)
                            } else {
                                viewModel.updateNetworkMount(editing, cfg, onResult = handler)
                            }
                        },
                    )
                }
            }
        }
    }

    // 移除确认（与首页长按/左滑删除同一套确认框）
    deleteTarget?.let { mount ->
        DangerConfirmDialog(
            title = L10n.t(R.string.s_ed4613d9b9),
            message = L10n.t(R.string.s_d10ef8e3eb, (mount.config.name)),
            confirmLabel = L10n.t(R.string.s_86048b4fea),
            onConfirm = {
                deleteTarget = null
                viewModel.removeNetworkMount(mount)
            },
            onCancel = { deleteTarget = null },
        )
    }
}

private fun protoOf(key: String): NetProtocol =
    NetProtocol.entries.firstOrNull { it.key == key } ?: NetProtocol.Webdav

private sealed interface NetMode {
    data object List : NetMode
    data object ChooseProtocol : NetMode
    data object CloudProviders : NetMode
    data class Form(
        val protocol: NetProtocol,
        val host: String = "",
        val share: String = "",
        /** 非空 = 编辑已保存连接（字段全部预填）。 */
        val editing: NetworkMountStatus? = null,
    ) : NetMode
}

@Composable
private fun SheetHeader(title: String, onBack: (() -> Unit)?, actions: @Composable () -> Unit = {}) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = Dimens.Space2, vertical = Dimens.Space1),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (onBack != null) {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = L10n.t(R.string.s_5f411223ca))
            }
        } else {
            Spacer(Modifier.width(Dimens.Space4))
        }
        Text(
            title,
            fontSize = 17.sp,
            fontWeight = FontWeight.Bold,
            color = SfColors.OnSurface,
            modifier = Modifier.weight(1f),
        )
        actions()
    }
}

@Composable
private fun MountRow(
    mount: NetworkMountStatus,
    onOpen: () -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
) {
    val online = mount.rootId != null
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 60.dp)
            .clickable(enabled = online) { onOpen() }
            .padding(horizontal = Dimens.Space4),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Dimens.Space3),
    ) {
        StorageProtoLogo(mount.config.protocol)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
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
                    L10n.t(R.string.s_43a97a3646, (mount.config.protocol.uppercase()), (mount.error ?: L10n.t(R.string.s_f91d273b96)))
                },
                fontSize = 11.sp,
                color = if (online) SfColors.Success else SfColors.Error,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        // 行尾操作组：统一 0 间距紧凑排布（与其它行尾操作保持同一间距规则）
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(0.dp),
        ) {
            CompactIconButton(Icons.Outlined.Edit, L10n.t(R.string.s_74f03bafc8), onClick = onEdit)
            CompactIconButton(Icons.Outlined.Delete, L10n.t(R.string.s_86048b4fea), tint = SfColors.Error, onClick = onDelete)
        }
    }
}


@Composable
private fun ConnectForm(
    proto: NetProtocol,
    editing: NetworkMountStatus? = null,
    prefillHost: String = "",
    prefillShare: String = "",
    onScanLanSmb: ((onDone: (List<SmbHostInfo>?, String?) -> Unit) -> Unit) = {},
    rememberedShare: (String) -> String? = { null },
    onListShares: (
        host: String,
        port: Int,
        username: String,
        password: String,
        onResult: (List<String>?, String?) -> Unit,
    ) -> Unit,
    onSubmit: (NetworkMountConfig, (Boolean, String?) -> Unit) -> Unit,
) {
    var name by remember(proto, editing) {
        mutableStateOf(editing?.config?.name ?: defaultName(proto))
    }
    var host by remember(proto, editing) {
        mutableStateOf(editing?.config?.host ?: prefillHost)
    }
    var port by remember(proto, editing) {
        mutableStateOf(
            editing?.config?.port?.takeIf { it > 0 }?.toString() ?: when (proto) {
                NetProtocol.Sftp -> "22"
                NetProtocol.Smb -> "445" // 支持自定义端口（如 1445）
                else -> ""
            },
        )
    }
    var share by remember(proto, editing) {
        mutableStateOf(editing?.config?.share ?: prefillShare)
    }
    var username by remember(proto, editing) {
        mutableStateOf(editing?.config?.username ?: "")
    }
    var password by remember(proto, editing) {
        mutableStateOf(editing?.config?.password ?: "")
    }
    var region by remember(proto, editing) {
        mutableStateOf(editing?.config?.region ?: "us-east-1")
    }
    var pathStyle by remember(proto, editing) {
        mutableStateOf(editing?.config?.pathStyle ?: false)
    }
    var submitting by remember { mutableStateOf(false) }
    var errorText by remember { mutableStateOf<String?>(null) }
    var listingShares by remember { mutableStateOf(false) }
    var shareOptions by remember { mutableStateOf<List<String>>(emptyList()) }
    // 选中 Samba 后自动扫描局域网（无需再点按钮）
    var scanningLan by remember { mutableStateOf(false) }
    var lanHosts by remember { mutableStateOf<List<SmbHostInfo>>(emptyList()) }
    var lanError by remember { mutableStateOf<String?>(null) }
    var showShareHelp by remember { mutableStateOf(false) }

    androidx.compose.runtime.LaunchedEffect(proto) {
        if (proto == NetProtocol.Smb) {
            scanningLan = true
            onScanLanSmb { found, err ->
                scanningLan = false
                lanHosts = found ?: emptyList()
                lanError = err
            }
        }
    }

    val valid = host.isNotBlank() && name.isNotBlank() &&
        (proto != NetProtocol.Smb || share.isNotBlank()) &&
        (proto != NetProtocol.S3 || (share.isNotBlank() && username.isNotBlank() && password.isNotBlank()))

    Column(
        modifier = Modifier.padding(horizontal = Dimens.Space6),
        verticalArrangement = Arrangement.spacedBy(Dimens.Space2),
    ) {
        if (proto == NetProtocol.Smb) {
            when {
                scanningLan -> Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(Dimens.Space2),
                ) {
                    androidx.compose.material3.CircularProgressIndicator(
                        modifier = Modifier.size(14.dp),
                        strokeWidth = 1.5.dp,
                    )
                    Text(L10n.t(R.string.s_c9dbf70ed7), fontSize = 11.sp, color = SfColors.OnSurfaceVariant)
                }
                lanHosts.isNotEmpty() -> Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(L10n.t(R.string.s_859d19ee97, (lanHosts.size)), fontSize = 11.sp, color = SfColors.OnSurfaceVariant)
                    lanHosts.forEach { info ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .heightIn(min = 34.dp)
                                .clickable {
                                    host = info.host
                                    share = info.shares.firstOrNull()
                                        ?: rememberedShare(info.host)
                                        ?: ""
                                },
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(
                                Icons.Outlined.FolderOpen,
                                contentDescription = null,
                                modifier = Modifier.size(Dimens.Space4),
                                tint = SfColors.Primary,
                            )
                            Spacer(Modifier.width(Dimens.Space2))
                            Column(Modifier.weight(1f)) {
                                Text(
                                    info.name,
                                    fontSize = 12.sp,
                                    color = SfColors.OnSurface,
                                    maxLines = 1,
                                )
                                Text(
                                    if (info.shares.isEmpty()) {
                                        L10n.t(R.string.s_d6fa94966b, (info.host))
                                    } else {
                                        "${info.host} · ${info.shares.joinToString("、")}"
                                    },
                                    fontSize = 10.sp,
                                    color = SfColors.OnSurfaceVariant,
                                    maxLines = 1,
                                )
                            }
                        }
                    }
                }
                lanError != null -> Text(lanError!!, fontSize = 11.sp, color = SfColors.OnSurfaceVariant)
            }
        }
        FormField(L10n.t(R.string.s_d7ec2d3fea), name) { name = it }
        when (proto) {
            NetProtocol.Webdav -> FormField(L10n.t(R.string.s_5d57821d7e), host, "https://host/dav") { host = it }
            NetProtocol.Sftp -> {
                FormField(L10n.t(R.string.s_652273694e), host, "192.168.1.10") { host = it }
                FormField(L10n.t(R.string.s_c76cfefe72), port, "22", KeyboardType.Number) { port = it }
            }
            NetProtocol.S3 -> {
                FormField(L10n.t(R.string.s_s3_endpoint), host, "https://s3.amazonaws.com") { host = it }
                FormField(L10n.t(R.string.s_s3_bucket), share, "my-bucket") { share = it }
                FormField(L10n.t(R.string.s_s3_region), region, "us-east-1") { region = it }
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        L10n.t(R.string.s_s3_pathstyle),
                        fontSize = 12.sp,
                        color = SfColors.OnSurface,
                        modifier = Modifier.weight(1f),
                    )
                    SfSwitch(checked = pathStyle, onCheckedChange = { pathStyle = it })
                }
            }
            NetProtocol.Smb -> {
                FormField(L10n.t(R.string.s_652273694e), host, "192.168.1.10") { host = it }
                FormField(L10n.t(R.string.s_c76cfefe72), port, L10n.t(R.string.s_ac9b7d210f), KeyboardType.Number) { port = it }
                FormField(L10n.t(R.string.s_03b81b2f40), share, "movies") { share = it }
                // 共享名容易填错（STATUS_BAD_NETWORK_NAME）→ 直接从服务器枚举选择
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.End,
                ) {
                    TextButton(
                        onClick = {
                            if (host.isBlank()) {
                                errorText = L10n.t(R.string.s_c87c8c1882)
                                return@TextButton
                            }
                            listingShares = true
                            errorText = null
                            onListShares(
                                host.trim(),
                                port.toIntOrNull() ?: 0,
                                username,
                                password,
                            ) { shares, err ->
                                listingShares = false
                                shareOptions = shares ?: emptyList()
                                errorText = err
                            }
                        },
                        enabled = !listingShares,
                    ) {
                        Text(if (listingShares) L10n.t(R.string.s_e5d295adcc) else L10n.t(R.string.s_3a0ccea638))
                    }
                }
                TextButton(onClick = { showShareHelp = !showShareHelp }) {
                    Text(if (showShareHelp) L10n.t(R.string.s_76cf118510) else L10n.t(R.string.s_ad4bf71598), fontSize = 12.sp)
                }
                if (showShareHelp) {
                    Text(
                        L10n.t(R.string.s_cfbbefbdb3) +
                            L10n.t(R.string.s_13a4019138) +
                            L10n.t(R.string.s_df424b7878) +
                            L10n.t(R.string.s_5446da9178) +
                            L10n.t(R.string.s_b8e23a34c6),
                        fontSize = 11.sp,
                        color = SfColors.OnSurfaceVariant,
                    )
                }
                if (shareOptions.isNotEmpty()) {
                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(L10n.t(R.string.s_438b30a400), fontSize = 11.sp, color = SfColors.OnSurfaceVariant)
                        shareOptions.forEach { name ->
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .heightIn(min = 36.dp)
                                    .clickable {
                                        share = name
                                        shareOptions = emptyList()
                                    },
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Icon(
                                    Icons.Outlined.FolderOpen,
                                    contentDescription = null,
                                    modifier = Modifier.size(Dimens.Space4),
                                    tint = SfColors.Primary,
                                )
                                Spacer(Modifier.width(Dimens.Space2))
                                Text(name, fontSize = 13.sp, color = SfColors.OnSurface)
                            }
                        }
                    }
                }
            }
        }
        FormField(
            if (proto == NetProtocol.S3) L10n.t(R.string.s_s3_access) else L10n.t(R.string.s_819767ada1),
            username,
            L10n.t(R.string.s_4192bed6b0),
        ) { username = it }
        FormField(
            if (proto == NetProtocol.S3) L10n.t(R.string.s_s3_secret) else L10n.t(R.string.s_a810520460),
            password,
            L10n.t(R.string.s_4192bed6b0),
            isPassword = true,
        ) { password = it }
        errorText?.let {
            Text(
                it,
                fontSize = 12.sp,
                color = SfColors.Error,
                modifier = Modifier.padding(top = Dimens.Space1),
            )
        }
        Row(
            modifier = Modifier.fillMaxWidth().padding(top = Dimens.Space2),
            horizontalArrangement = Arrangement.End,
        ) {
            TextButton(
                onClick = {
                    if (!valid || submitting) return@TextButton
                    submitting = true
                    errorText = null
                    onSubmit(
                        NetworkMountConfig(
                            name = name.trim(),
                            protocol = proto.key,
                            host = host.trim(),
                            port = port.toIntOrNull() ?: 0,
                            share = share.trim(),
                            username = username,
                            password = password,
                            region = region.trim(),
                            pathStyle = pathStyle,
                        ),
                    ) { _, err ->
                        submitting = false
                        errorText = err
                    }
                },
                enabled = valid && !submitting,
            ) {
                Text(
                    if (submitting) {
                        L10n.t(if (editing == null) R.string.s_5e8eb21201 else R.string.s_9b5d32d18c)
                    } else {
                        L10n.t(if (editing == null) R.string.s_976d321fe5 else R.string.s_be5fbbe34c)
                    },
                )
            }
        }
    }
}

@Composable
private fun FormField(
    label: String,
    value: String,
    placeholder: String = "",
    keyboardType: KeyboardType = KeyboardType.Text,
    isPassword: Boolean = false,
    onChange: (String) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(Dimens.Space1)) {
        Text(label, fontSize = 11.sp, color = SfColors.OnSurfaceVariant)
        SfInputField(
            value = value,
            onValueChange = onChange,
            placeholder = placeholder,
            keyboardType = keyboardType,
            isPassword = isPassword,
        )
    }
}

private fun defaultName(proto: NetProtocol): String = when (proto) {
    NetProtocol.Webdav -> L10n.t(R.string.s_8f1b7aa16e)
    NetProtocol.Sftp -> L10n.t(R.string.s_cfa0d35954)
    NetProtocol.Smb -> L10n.t(R.string.s_79aa812258)
    NetProtocol.S3 -> "S3"
}
