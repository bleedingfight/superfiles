package com.superfiles.app.ui

import com.superfiles.app.L10n
import com.superfiles.app.R

import android.content.Intent

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.Image
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.FilterChip
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.Devices
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material.icons.outlined.Send
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Divider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.superfiles.app.VfsViewModel
import com.superfiles.core.Entry
import com.superfiles.core.LocalSendPeer

/**
 * 近邻传输（LocalSend 兼容）：HTTPS 接收 + 组播发现 + 手动 IP 兜底。
 * 首次连接以证书指纹做 TOFU；接收文件默认落到「应用存储/superfiles」。
 */
@Composable
fun LocalSendScreen(
    viewModel: VfsViewModel,
    onBack: () -> Unit,
    onOpenDest: () -> Unit = {},
    onOpenFiles: () -> Unit = {},
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    var ip by remember { mutableStateOf("") }
    var port by remember { mutableStateOf("53317") }
    var manualError by remember { mutableStateOf<String?>(null) }
    var showDestPicker by remember { mutableStateOf(false) }
    val fallbackDestPath = remember { viewModel.localSendDestDir() }
    val fallbackDestLabel = remember { viewModel.localSendDestLabel() }
    val context = LocalContext.current
    var ips by remember { mutableStateOf(listOf<String>()) }
    var scanOpen by remember { mutableStateOf(false) }
    var idlePicker by remember { mutableStateOf(false) }

    // 服务器启停时刷新本机私网 IP（组网码展示用）
    LaunchedEffect(state.localSendRunning, state.localSendInfo?.port) {
        ips = viewModel.localSendIps()
    }

    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
        Column(modifier = Modifier.widthIn(max = Adaptive.ListMaxWidth).fillMaxSize()) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = Dimens.Space2, vertical = Dimens.Space1),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(onClick = onBack) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = L10n.t(R.string.s_5f411223ca))
                }
                Text(L10n.t(R.string.s_4494d7e5cb), fontSize = 17.sp, fontWeight = FontWeight.Bold, color = SfColors.OnSurface)
            }

            LazyColumn(
                modifier = Modifier.fillMaxSize().padding(horizontal = Dimens.Space6),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = Dimens.Space8),
            ) {
                item { Spacer(Modifier.height(Dimens.Space2)) }
                item {
                    StatusCard(
                        running = state.localSendRunning,
                        busy = state.localSendBusy,
                        alias = state.localSendInfo?.alias ?: state.userNickname,
                        port = state.localSendInfo?.port?.toInt(),
                        fingerprint = state.localSendInfo?.fingerprint,
                        onStart = viewModel::startLocalSend,
                        onStop = viewModel::stopLocalSend,
                        onOpenFiles = onOpenFiles,
                    )
                }

                item {
                    ReceiveLocationCard(
                        path = state.localSendDest.ifBlank { fallbackDestPath },
                        label = state.localSendDestName.ifBlank { fallbackDestLabel },
                        onOpen = onOpenDest,
                        onChange = { showDestPicker = true },
                    )
                }

                // 对端能被雷达/注册发现 = 已在同一局域网，组网向导按需让位
                if (state.localSendPeers.isEmpty()) {
                    item {
                        PairingCard(
                            running = state.localSendRunning,
                            ips = ips,
                            port = state.localSendInfo?.port?.toInt(),
                            fingerprint = state.localSendInfo?.fingerprint,
                            onOpenSettings = {
                                runCatching { context.startActivity(Intent("android.settings.TETHER_SETTINGS")) }
                            },
                            onStart = viewModel::startLocalSend,
                            onScan = { scanOpen = true },
                        )
                    }
                }

                item {
                    ListSectionCard {
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(Dimens.Space4),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(Modifier.weight(1f)) {
                                Text(L10n.t(R.string.s_lswiz_idle_title), fontSize = 13.sp, color = SfColors.OnSurface)
                                Text(idleLabelOf(state.localSendIdleSecs), fontSize = 11.sp, color = SfColors.OnSurfaceVariant)
                            }
                            Text(
                                L10n.t(R.string.s_lswiz_idle_change),
                                fontSize = 12.sp,
                                color = SfColors.Primary,
                                modifier = Modifier.clickable { idlePicker = true },
                            )
                        }
                    }
                }

                item { SectionLabel(L10n.t(R.string.s_9662acf715), action = L10n.t(R.string.s_694fc5efa9), onAction = viewModel::refreshLocalSendPeers) }
                if (state.localSendPeers.isEmpty()) {
                    item {
                        if (state.localSendRunning) {
                            Surface(
                                shape = RoundedCornerShape(Dimens.RadiusM),
                                color = SfColors.SurfaceCard,
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                Column(
                                    modifier = Modifier.fillMaxWidth().padding(Dimens.Space4),
                                    horizontalAlignment = Alignment.CenterHorizontally,
                                    verticalArrangement = Arrangement.spacedBy(Dimens.Space2),
                                ) {
                                    NearbySearchAnimation()
                                    Text(
                                        L10n.t(R.string.s_9b3920387b),
                                        fontSize = 12.sp,
                                        color = SfColors.OnSurfaceVariant,
                                    )
                                    Text(
                                        L10n.t(R.string.s_3539468571),
                                        fontSize = 11.sp,
                                        color = SfColors.OnSurfaceVariant,
                                    )
                                }
                            }
                        } else {
                            HintCard(L10n.t(R.string.s_7293a455a1))
                        }
                    }
                } else {
                    item {
                        ListSectionCard {
                            state.localSendPeers.forEachIndexed { index, peer ->
                                PeerRow(peer = peer)
                                if (index < state.localSendPeers.lastIndex) RowDivider(start = Dimens.Space4)
                            }
                        }
                    }
                }

                // 已接收清单：常驻展示“收到了什么、什么时候、多大”，点行直达所在目录
                if (state.localSendReceived.isNotEmpty()) {
                    item {
                        SectionLabel(L10n.t(R.string.s_ls_recv_title, (state.localSendDestName.ifBlank { fallbackDestLabel })))
                    }
                    item {
                        ListSectionCard {
                            val fmt = remember { java.text.SimpleDateFormat("HH:mm", java.util.Locale.getDefault()) }
                            state.localSendReceived.forEachIndexed { index, r ->
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .clickable { onOpenDest() }
                                        .padding(horizontal = Dimens.Space4, vertical = Dimens.Space3),
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    Text("📄", fontSize = 18.sp)
                                    Column(
                                        modifier = Modifier.weight(1f).padding(start = Dimens.Space3),
                                    ) {
                                        Text(r.name, fontSize = 14.sp, color = SfColors.OnSurface, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                        Text(
                                            "${fmt.format(java.util.Date(r.atMs))} · ${android.text.format.Formatter.formatShortFileSize(context, r.sizeBytes)}",
                                            fontSize = 11.sp,
                                            color = SfColors.OnSurfaceVariant,
                                        )
                                    }
                                }
                                if (index < state.localSendReceived.lastIndex) RowDivider(start = Dimens.Space4)
                            }
                        }
                    }
                }

                if (state.localSendErrors.isNotEmpty()) {
                    item { SectionLabel(L10n.t(R.string.s_a2b83df06d)) }
                    item {
                        ListSectionCard {
                            Column(
                                modifier = Modifier.fillMaxWidth().padding(Dimens.Space4),
                                verticalArrangement = Arrangement.spacedBy(Dimens.Space1),
                            ) {
                                state.localSendErrors.takeLast(3).forEach { err ->
                                    Text(
                                        err,
                                        fontSize = 11.sp,
                                        color = SfColors.Error,
                                        maxLines = 3,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                }
                            }
                        }
                    }
                }

                state.localSendSendError?.let { err ->
                    item { SectionLabel(L10n.t(R.string.s_05505ce686)) }
                    item {
                        ListSectionCard {
                            Text(
                                err,
                                fontSize = 11.sp,
                                color = SfColors.Error,
                                modifier = Modifier.padding(Dimens.Space4),
                            )
                        }
                    }
                }

                item { SectionLabel(L10n.t(R.string.s_8f50953135)) }
                item {
                    ListSectionCard {
                        Column(
                            modifier = Modifier.fillMaxWidth().padding(Dimens.Space4),
                            verticalArrangement = Arrangement.spacedBy(Dimens.Space2),
                        ) {
                            Text(
                                L10n.t(R.string.s_d8d1594c8f),
                                fontSize = 11.sp,
                                color = SfColors.OnSurfaceVariant,
                            )
                            Row(horizontalArrangement = Arrangement.spacedBy(Dimens.Space2)) {
                                Box(Modifier.weight(1f)) {
                                    SfInputField(
                                        value = ip,
                                        onValueChange = { ip = it },
                                        placeholder = "192.168.1.10",
                                    )
                                }
                                Box(Modifier.size(width = 96.dp, height = 48.dp)) {
                                    SfInputField(
                                        value = port,
                                        onValueChange = { port = it.filter(Char::isDigit) },
                                        placeholder = L10n.t(R.string.s_c76cfefe72),
                                    )
                                }
                            }
                            manualError?.let {
                                Text(it, fontSize = 11.sp, color = SfColors.Error)
                            }
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.End,
                            ) {
                                PrimaryConfirmButton(
                                    L10n.t(R.string.s_30f7dd4ecd),
                                    enabled = ip.isNotBlank() && !state.localSendBusy,
                                ) {
                                    manualError = null
                                    viewModel.registerLocalSendPeer(
                                        ip = ip,
                                        port = port.toIntOrNull() ?: 53317,
                                        fingerprint = null,
                                    ) { ok, err ->
                                        if (!ok) manualError = err ?: L10n.t(R.string.s_0745fc09bb)
                                    }
                                }
                            }
                        }
                    }
                }

                item {
                    Text(
                        L10n.t(R.string.s_cf5a7158ef) +
                            L10n.t(R.string.s_d8b0aa726a),
                        fontSize = 11.sp,
                        color = SfColors.OnSurfaceVariant,
                        modifier = Modifier.padding(vertical = Dimens.Space3),
                    )
                }
            }
        }
    }

    if (showDestPicker) {
        DestPickerDialog(
            viewModel = viewModel,
            title = L10n.t(R.string.s_dae3656db4),
            confirmLabel = L10n.t(R.string.s_93ba4eb11b),
            onDismiss = { showDestPicker = false },
            onPick = { node ->
                showDestPicker = false
                viewModel.setLocalSendDestination(node.id, node.name)
            },
        )
    }

    if (scanOpen) {
        QrScanSheet(
            onClose = { scanOpen = false },
            onResult = { link ->
                scanOpen = false
                viewModel.registerFromLocalSendLink(link)
            },
        )
    }

    if (idlePicker) {
        SfDialog(
            onDismissRequest = { idlePicker = false },
            title = L10n.t(R.string.s_lswiz_idle_title),
            actions = {
                SafeCancelButton(onClick = { idlePicker = false })
            },
        ) {
            IDLE_OPTIONS.forEach { secs ->
                Text(
                    idleLabelOf(secs),
                    fontSize = 14.sp,
                    color = if (secs == state.localSendIdleSecs) SfColors.Primary else SfColors.OnSurface,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable {
                            viewModel.setLocalSendIdleSecs(secs)
                            idlePicker = false
                        }
                        .padding(vertical = Dimens.Space3),
                )
            }
        }
    }
}

/** 分段文字钮（组网卡二选一)：选中 primary + Medium，未选 onSurfaceVariant。 */
@Composable
private fun RowScope.PairSegment(
    label: String,
    active: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    Box(
        modifier = modifier
            .clip(RoundedCornerShape(Dimens.RadiusS))
            .clickable(onClick = onClick)
            .padding(vertical = Dimens.Space2),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            fontSize = 13.sp,
            fontWeight = if (active) FontWeight.SemiBold else FontWeight.Normal,
            color = if (active) SfColors.Primary else SfColors.OnSurfaceVariant,
        )
    }
}

/** 无传输活动自动关闭的可选时长（秒）。 */
private val IDLE_OPTIONS = listOf(300L, 600L, 1800L, 3600L, 0L)

private fun idleLabelOf(secs: Long): String =
    if (secs <= 0) L10n.t(R.string.s_lswiz_idle_never)
    else "${secs / 60} ${L10n.t(com.superfiles.app.R.string.s_lswiz_idle_min)}"

@Composable
private fun ReceiveLocationCard(
    path: String,
    label: String,
    onOpen: () -> Unit,
    onChange: () -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(Dimens.RadiusM),
        color = SfColors.SurfaceCard,
        modifier = Modifier.fillMaxWidth().padding(top = Dimens.Space2),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = Dimens.Space4, vertical = Dimens.Space2),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Dimens.Space3),
        ) {
            Icon(Icons.Outlined.FolderOpen, contentDescription = null, tint = SfColors.PrimaryWarm)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(L10n.t(R.string.s_dae3656db4), fontSize = 11.sp, color = SfColors.OnSurfaceVariant)
                Text(label, fontSize = 13.sp, fontWeight = FontWeight.Medium, color = SfColors.OnSurface)
                Text(
                    path,
                    fontSize = 10.sp,
                    color = SfColors.OnSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            TextButton(onClick = onChange) { Text(L10n.t(R.string.s_fe3cd2776c), fontSize = 13.sp) }
            TextButton(onClick = onOpen) { Text(L10n.t(R.string.s_d7098f5050), fontSize = 13.sp) }
        }
    }
}

@Composable
private fun StatusCard(
    running: Boolean,
    busy: Boolean,
    alias: String,
    port: Int?,
    fingerprint: String?,
    onStart: () -> Unit,
    onStop: () -> Unit,
    onOpenFiles: () -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(Dimens.RadiusL),
        color = SfColors.SurfaceTint,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier.padding(Dimens.Space4),
            verticalArrangement = Arrangement.spacedBy(Dimens.Space2),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier = Modifier
                        .size(10.dp)
                        .clip(CircleShape)
                        .background(if (running) SfColors.Success else SfColors.Outline),
                )
                Spacer(Modifier.size(Dimens.Space2))
                Text(
                    if (running) L10n.t(R.string.s_1be4d8bd9a) else L10n.t(R.string.s_ea4a363d8f),
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium,
                    color = SfColors.OnSurface,
                )
                Spacer(Modifier.weight(1f))
                if (busy) {
                    CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                }
            }
            Text(L10n.t(R.string.s_567121a16d, (alias)), fontSize = 12.sp, color = SfColors.OnSurfaceVariant)
            if (running && port != null) {
                Text(L10n.t(R.string.s_dc36e7919d, (port)), fontSize = 11.sp, color = SfColors.OnSurfaceVariant)
                fingerprint?.let {
                    Text(
                        L10n.t(R.string.s_63a481e022, (shortFingerprint(it))),
                        fontSize = 11.sp,
                        color = SfColors.OnSurfaceVariant,
                    )
                }
            }
            Spacer(Modifier.height(Dimens.Space1))
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(Dimens.Space2),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (running) {
                    PrimaryConfirmButton(L10n.t(R.string.s_5bbc48d94f), enabled = !busy, onClick = onOpenFiles)
                    Spacer(Modifier.weight(1f))
                    TextButton(onClick = onStop) {
                        Text(L10n.t(R.string.s_b15d91274e), fontSize = 13.sp, color = SfColors.Error)
                    }
                } else {
                    PrimaryConfirmButton(L10n.t(R.string.s_90151548cc), enabled = !busy, onClick = onStart)
                }
            }
            if (running) {
                Text(
                    L10n.t(R.string.s_79e96e6d9d),
                    fontSize = 11.sp,
                    color = SfColors.OnSurfaceVariant,
                )
                Text(
                    L10n.t(R.string.s_da82b55021),
                    fontSize = 11.sp,
                    color = SfColors.Success,
                )
            }
        }
    }
}

/** 雷达式搜索动画：中心设备 + 向外扩散的三圈涟漪。 */
@Composable
private fun NearbySearchAnimation(modifier: Modifier = Modifier) {
    val transition = rememberInfiniteTransition(label = "nearby-search")
    val phase by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 1600, easing = LinearEasing),
            repeatMode = RepeatMode.Restart,
        ),
        label = "phase",
    )
    Box(modifier = modifier.size(132.dp), contentAlignment = Alignment.Center) {
        repeat(3) { index ->
            val p = (phase + index / 3f) % 1f
            Box(
                modifier = Modifier
                    .size((132f * (0.42f + 0.58f * p)).dp)
                    .alpha(1f - p)
                    .border(1.dp, SfColors.Primary.copy(alpha = 0.55f), CircleShape),
            )
        }
        Box(
            modifier = Modifier
                .size(46.dp)
                .clip(CircleShape)
                .background(SfColors.SurfaceTint),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                Icons.Outlined.Devices,
                contentDescription = null,
                tint = SfColors.Primary,
                modifier = Modifier.size(22.dp),
            )
        }
    }
}

@Composable
private fun PeerRow(peer: LocalSendPeer) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = Dimens.Space4, vertical = Dimens.Space2),
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
            Icon(Icons.Outlined.Devices, contentDescription = null, tint = SfColors.PrimaryWarm, modifier = Modifier.size(20.dp))
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                peer.alias,
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
                color = SfColors.OnSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                "${peer.ip}:${peer.port} · ${peer.deviceType}",
                fontSize = 11.sp,
                color = SfColors.OnSurfaceVariant,
            )
        }
    }
}

@Composable
private fun SectionLabel(text: String, action: String? = null, onAction: (() -> Unit)? = null) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(top = Dimens.Space4, bottom = Dimens.Space2),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(text, fontSize = 12.sp, fontWeight = FontWeight.Medium, color = SfColors.OnSurfaceVariant)
        Spacer(Modifier.weight(1f))
        if (action != null && onAction != null) {
            TextButton(onClick = onAction) { Text(action, fontSize = 12.sp) }
        }
    }
}

@Composable
private fun HintCard(text: String) {
    Surface(
        shape = RoundedCornerShape(Dimens.RadiusM),
        color = SfColors.SurfaceCard,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Text(
            text,
            fontSize = 12.sp,
            color = SfColors.OnSurfaceVariant,
            modifier = Modifier.padding(Dimens.Space4),
        )
    }
}

private fun shortFingerprint(value: String): String =
    if (value.length <= 16) value else "${value.take(8)}…${value.takeLast(8)}"

/**
 * 发送文件时的附近设备选择器。只列出已发现/手动连接的 peer。
 */
@Composable
fun LocalSendPeerPicker(
    viewModel: VfsViewModel,
    entries: List<Entry>,
    onDismiss: () -> Unit,
) {
    val state by viewModel.state.collectAsStateWithLifecycle()

    // 打开即自动开启发现；不需要用户先手动点「开启近邻传输」。
    LaunchedEffect(Unit) { viewModel.ensureLocalSendStarted() }

    SfDialog(
        onDismissRequest = onDismiss,
        title = L10n.t(R.string.s_04f2479ab3),
        showCloseButton = true,
        actions = { SafeCancelButton(onClick = onDismiss) },
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(Dimens.Space2)) {
            Text(
                L10n.t(R.string.s_a0e8059216, (entries.size)),
                fontSize = 11.sp,
                color = SfColors.OnSurfaceVariant,
            )
            state.localSendSendError?.let { err ->
                Text(
                    L10n.t(R.string.s_71e1eaada9, (err)),
                    fontSize = 11.sp,
                    color = SfColors.Error,
                    maxLines = 6,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (state.localSendBusy && state.localSendRunning) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(Dimens.Space2),
                ) {
                    CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                    Text(L10n.t(R.string.s_72d6759906), fontSize = 12.sp, color = SfColors.OnSurfaceVariant)
                }
            }
            when {
                state.localSendStartError != null -> {
                    SfDialogMessage(L10n.t(R.string.s_a780af0418, (state.localSendStartError)))
                    PrimaryConfirmButton(
                        L10n.t(R.string.s_132c5cdcce),
                        enabled = !state.localSendBusy,
                        modifier = Modifier.fillMaxWidth(),
                        onClick = viewModel::startLocalSend,
                    )
                }
                !state.localSendRunning -> {
                    NearbySearchAnimation(Modifier.align(Alignment.CenterHorizontally))
                    Text(
                        L10n.t(R.string.s_3dc881dc28),
                        fontSize = 12.sp,
                        color = SfColors.OnSurfaceVariant,
                        modifier = Modifier.align(Alignment.CenterHorizontally),
                    )
                }
                state.localSendPeers.isEmpty() -> {
                    NearbySearchAnimation(Modifier.align(Alignment.CenterHorizontally))
                    Text(
                        L10n.t(R.string.s_9b3920387b),
                        fontSize = 12.sp,
                        color = SfColors.OnSurfaceVariant,
                        modifier = Modifier.align(Alignment.CenterHorizontally),
                    )
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(Dimens.Space2, Alignment.CenterHorizontally),
                    ) {
                        TextButton(onClick = viewModel::refreshLocalSendPeers) {
                            Text(L10n.t(R.string.s_408e998993), fontSize = 13.sp)
                        }
                    }
                    Text(
                        L10n.t(R.string.s_0dc909441e),
                        fontSize = 11.sp,
                        color = SfColors.OnSurfaceVariant,
                    )
                }
                else -> {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            L10n.t(R.string.s_bebe1995f0, (state.localSendPeers.size)),
                            fontSize = 11.sp,
                            color = SfColors.OnSurfaceVariant,
                            modifier = Modifier.weight(1f),
                        )
                        TextButton(onClick = viewModel::refreshLocalSendPeers) {
                            Text(L10n.t(R.string.s_408e998993), fontSize = 12.sp)
                        }
                    }
                    ListSectionCard {
                        state.localSendPeers.forEachIndexed { index, peer ->
                            val enabled = !state.localSendBusy
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable(enabled = enabled) {
                                        viewModel.sendViaLocalSend(peer, entries) { ok, _ ->
                                            if (ok) onDismiss()
                                        }
                                    }
                                    .padding(horizontal = Dimens.Space4, vertical = Dimens.Space3),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(Dimens.Space3),
                            ) {
                                Icon(Icons.Outlined.Devices, contentDescription = null, tint = SfColors.Primary)
                                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                    Text(peer.alias, fontSize = 14.sp, fontWeight = FontWeight.Medium, color = SfColors.OnSurface)
                                    Text("${peer.ip}:${peer.port}", fontSize = 11.sp, color = SfColors.OnSurfaceVariant)
                                }
                                if (state.localSendBusy) {
                                    CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                                } else {
                                    Icon(Icons.Outlined.Send, contentDescription = null, tint = SfColors.Primary)
                                }
                            }
                            if (index < state.localSendPeers.lastIndex) RowDivider(start = Dimens.Space4)
                        }
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------------- 一键组网（v1 热点向导 + v2 组网码）

/** 组网深链（两端同契约）：superfiles://localsend?ip=..&port=..&fp=.. */
internal fun buildLocalSendLink(ip: String, port: Int?, fingerprint: String?): String =
    "superfiles://localsend?ip=$ip&port=${port ?: 53317}" +
        (if (!fingerprint.isNullOrBlank()) "&fp=$fingerprint" else "")

/**
 * 一键组网卡：
 * - 发起端：跳系统热点设置；接收模式运行中时展示组网码（QR + 链接文本），
 *   对方扫码即等于手动 IP 注册（AP 隔离也能直连）。
 * - 加入端：App 内扫码（QrScanSheet）或先连对方热点等雷达自动发现。
 */
@Composable
private fun PairingCard(
    running: Boolean,
    ips: List<String>,
    port: Int?,
    fingerprint: String?,
    onOpenSettings: () -> Unit,
    onStart: () -> Unit,
    onScan: () -> Unit,
) {
    var panel by remember { mutableStateOf<String?>(null) }
    var selIp by remember(ips) { mutableStateOf(ips.firstOrNull()) }

    ListSectionCard {
        Column(
            modifier = Modifier.fillMaxWidth().padding(Dimens.Space4),
            verticalArrangement = Arrangement.spacedBy(Dimens.Space2),
        ) {
            Text(
                L10n.t(R.string.s_lswiz_title),
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
                color = SfColors.OnSurface,
            )
            Text(L10n.t(R.string.s_lswiz_hint), fontSize = 11.sp, color = SfColors.OnSurfaceVariant)

            // 分段入口走「文字按钮」规范：选中 primary 强调、未选 onSurfaceVariant，不自造底色
            Row(modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(Dimens.RadiusS))) {
                PairSegment(
                    label = L10n.t(R.string.s_lswiz_host),
                    active = panel == "host",
                    modifier = Modifier.weight(1f),
                ) { panel = if (panel == "host") null else "host" }
                PairSegment(
                    label = L10n.t(R.string.s_lswiz_client),
                    active = panel == "client",
                    modifier = Modifier.weight(1f),
                ) { panel = if (panel == "client") null else "client" }
            }

            when (panel) {
                "host" -> {
                    if (!running) {
                        Text(L10n.t(R.string.s_lswiz_need_start), fontSize = 11.sp, color = SfColors.OnSurfaceVariant)
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) {
                            PrimaryConfirmButton(L10n.t(R.string.s_lswiz_start_now), onClick = onStart)
                        }
                    } else if (ips.isEmpty()) {
                        Text(L10n.t(R.string.s_lswiz_no_ip), fontSize = 11.sp, color = SfColors.OnSurfaceVariant)
                    } else {
                        if (selIp == null) selIp = ips.first()
                        Row(modifier = Modifier.horizontalScroll(rememberScrollState())) {
                            ips.forEach { ip ->
                                FilterChip(
                                    selected = ip == selIp,
                                    onClick = { selIp = ip },
                                    label = { Text(ip, fontSize = 11.sp) },
                                    modifier = Modifier.padding(end = Dimens.Space1),
                                )
                            }
                        }
                        selIp?.let { ip ->
                            val qr = remember(ip, port, fingerprint) {
                                qrBitmapOf(buildLocalSendLink(ip, port, fingerprint), 640)
                            }
                            qr?.let { bmp ->
                                Image(
                                    bitmap = bmp.asImageBitmap(),
                                    contentDescription = null,
                                    modifier = Modifier
                                        .size(220.dp)
                                        .align(Alignment.CenterHorizontally),
                                )
                            }
                            Text(
                                buildLocalSendLink(ip, port, fingerprint),
                                fontSize = 10.sp,
                                color = SfColors.OnSurfaceVariant,
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }
                    }
                    Text(L10n.t(R.string.s_lswiz_host_hint), fontSize = 11.sp, color = SfColors.OnSurfaceVariant)
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) {
                        TextButton(onClick = onOpenSettings) {
                            Text(L10n.t(R.string.s_lswiz_open_settings), fontSize = 12.sp, color = SfColors.Primary)
                        }
                    }
                }
                "client" -> {
                    PrimaryConfirmButton(
                        L10n.t(R.string.s_lswiz_scan),
                        modifier = Modifier.fillMaxWidth(),
                        onClick = onScan,
                    )
                    Text(L10n.t(R.string.s_lswiz_scan_hint), fontSize = 11.sp, color = SfColors.OnSurfaceVariant)
                }
            }
        }
    }
}
