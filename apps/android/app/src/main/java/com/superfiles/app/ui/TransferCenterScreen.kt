package com.superfiles.app.ui

import com.superfiles.app.L10n
import com.superfiles.app.R

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.CloudUpload
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.superfiles.app.VfsViewModel
import com.superfiles.app.LocalSendReceived
import com.superfiles.core.PendingTransfer
import com.superfiles.core.TransferSnapshot
import com.superfiles.core.TransferState

/**
 * 传输中心：进行中 / 已完成 / 可恢复。
 *
 * 版式对齐首页：17 w700 分组标题 + 白色圆角卡 + 11 号次信息；空分区直接不渲染，
 * 整页为空时给一条完整空态说明（而不是堆三段灰字）。前台浮层里的任务还没
 * 「转后台」，不属于这里。
 */
@Composable
fun TransferCenterScreen(viewModel: VfsViewModel, onBack: () -> Unit) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val tasks = state.transfers.filter { it.id !in state.foregroundTransfers }
    // PAUSED 不是终态：一律算进行中（含 FGS 保活与传输中心展示）
    val active = tasks.filter {
        it.state == TransferState.QUEUED ||
            it.state == TransferState.RUNNING ||
            it.state == TransferState.PAUSED
    }
    val finished = tasks.filter {
        it.state != TransferState.QUEUED &&
            it.state != TransferState.RUNNING &&
            it.state != TransferState.PAUSED
    }
    LaunchedEffect(Unit) { viewModel.refreshResumable() }

    // 标题缓存（对齐鸿蒙 nameCache）：完成后引擎会把 current 清空，没有缓存
    // 标题就会退化成任务 id。普通 HashMap 即可——轮询每拍都触发重组，不需要观察它。
    val nameCache = remember { HashMap<String, String>() }
    fun rowTitle(s: TransferSnapshot): String {
        val cur = s.current.orEmpty()
        if (cur.isNotEmpty()) nameCache[s.id] = cur
        return cur.ifEmpty { nameCache[s.id] ?: L10n.t(R.string.s_tr_items, s.filesTotal.toString()) }
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
                Text(L10n.t(R.string.s_feed0b2e46), fontSize = 17.sp, fontWeight = FontWeight.Bold, color = SfColors.OnSurface)
                Spacer(Modifier.weight(1f))
                Text(
                    L10n.t(R.string.s_613cd7dda1, (active.size)),
                    fontSize = 12.sp,
                    color = SfColors.OnSurfaceVariant,
                )
                Spacer(Modifier.width(Dimens.Space4))
            }

            if (active.isEmpty() && finished.isEmpty() && state.resumable.isEmpty() && state.localSendRecords.isEmpty()) {
                EmptyTransfers()
                return@Column
            }

            LazyColumn(
                modifier = Modifier.fillMaxSize().padding(horizontal = Dimens.Space6),
            ) {
                if (active.isNotEmpty()) {
                    item { SectionTitle(L10n.t(R.string.s_25f9246234), active.size) }
                    // key 用 id：任务从「进行中」落到「已结束」时行不会错位（半开的滑动态也跟着行走）
                    items(active, key = { "a-${it.id}" }) { snapshot ->
                        val paused = snapshot.state == TransferState.PAUSED
                        TransferRow(
                            snapshot = snapshot,
                            title = rowTitle(snapshot),
                            rate = state.transferRates[snapshot.id] ?: 0L,
                            onCancel = { viewModel.cancelTransfer(snapshot.id) },
                            onForget = { viewModel.forgetTransfer(snapshot.id) },
                            onPauseToggle = {
                                if (paused) viewModel.unpauseTransfer(snapshot.id)
                                else viewModel.pauseTransfer(snapshot.id)
                            },
                        )
                    }
                }

                if (finished.isNotEmpty()) {
                    item { SectionTitle(L10n.t(R.string.s_fad5222ca0), finished.size) }
                    items(finished, key = { "f-${it.id}" }) { snapshot ->
                        TransferRow(
                            snapshot = snapshot,
                            title = rowTitle(snapshot),
                            rate = 0,
                            onCancel = {},
                            onForget = { viewModel.forgetTransfer(snapshot.id) },
                            onPauseToggle = {},
                        )
                    }
                }

                if (state.resumable.isNotEmpty()) {
                    item { SectionTitle(L10n.t(R.string.s_2e61683ad2)) }
                    item {
                        Text(
                            L10n.t(R.string.s_969a4ed5ce),
                            fontSize = 12.sp,
                            color = SfColors.OnSurfaceVariant,
                            modifier = Modifier.padding(bottom = Dimens.Space2),
                        )
                    }
                    items(state.resumable, key = { "r-${it.id}" }) { pending ->
                        ResumableRow(
                            pending = pending,
                            onResume = { viewModel.resumeTransfer(pending.id) },
                            onForget = { viewModel.forgetResumable(pending.id) },
                        )
                    }
                }

                // 近邻收发流水：LocalSend 不走引擎 transfers()，独立分组展示，
                // 解决"发了/收到了但传输中心空白"的断链。版式与其他分组的卡片行
                // 对齐（此前是从近邻传输页搬来的裸行，两头不挨）；左滑移除单条流水，
                // 近邻传输页的「已接收」清单不受影响。
                if (state.localSendRecords.isNotEmpty()) {
                    item { SectionTitle(L10n.t(R.string.s_ls_records_title), state.localSendRecords.size) }
                    items(state.localSendRecords, key = { "ls-${it.seq}" }) { r ->
                        var menu by remember { mutableStateOf(false) }
                        Box {
                            SwipeRevealRow(
                                onDelete = { viewModel.removeLocalSendRecord(r) },
                                deleteLabel = L10n.t(R.string.s_86048b4fea),
                                backgroundColor = Color.Transparent,
                                modifier = Modifier.padding(vertical = Dimens.Space1),
                                onLongClick = { menu = true },
                            ) {
                                LocalSendRecordRow(r)
                            }
                            DeleteRecordMenu(
                                expanded = menu,
                                onDismiss = { menu = false },
                                onDelete = { viewModel.removeLocalSendRecord(r) },
                            )
                        }
                    }
                }

                item { Spacer(Modifier.height(Dimens.Space8)) }
            }
        }
    }
}

@Composable
private fun SectionTitle(title: String, count: Int? = null) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(top = Dimens.Space6, bottom = Dimens.Space2),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Dimens.Space2),
    ) {
        Text(title, fontSize = 17.sp, fontWeight = FontWeight.Bold, color = SfColors.OnSurface)
        if (count != null) {
            Text("$count", fontSize = 12.sp, color = SfColors.OnSurfaceVariant)
        }
    }
}

@Composable
private fun EmptyTransfers() {
    Column(
        modifier = Modifier.fillMaxSize().padding(horizontal = 40.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(
            Icons.Outlined.CloudUpload,
            contentDescription = null,
            modifier = Modifier.size(40.dp),
            tint = SfColors.Outline,
        )
        Spacer(Modifier.height(Dimens.Space2))
        Text(L10n.t(R.string.s_b9dee527e4), fontSize = 15.sp, fontWeight = FontWeight.Medium, color = SfColors.OnSurface)
        Spacer(Modifier.height(Dimens.Space2))
        Text(
            L10n.t(R.string.s_1f00ee60ae) +
                L10n.t(R.string.s_3968f1053a),
            fontSize = 13.sp,
            color = SfColors.OnSurfaceVariant,
            textAlign = TextAlign.Center,
            lineHeight = 19.sp,
        )
    }
}

private fun stateLabel(state: TransferState): String = when (state) {
    TransferState.QUEUED -> L10n.t(R.string.s_e5ac1d2029)
    TransferState.RUNNING -> L10n.t(R.string.s_25f9246234)
    TransferState.PAUSED -> L10n.t(R.string.s_tr_paused)
    TransferState.COMPLETED -> L10n.t(R.string.s_fad5222ca0)
    TransferState.FAILED -> L10n.t(R.string.s_acd5cb847a)
    TransferState.CANCELLED -> L10n.t(R.string.s_2111ccbb19)
}

/**
 * 速度格式（与 formatSize 同口径：KB/MB/GB 一位小数 + /s）。
 */
private fun formatSpeed(bytesPerSec: Long): String {
    if (bytesPerSec < 1024) return "$bytesPerSec B/s"
    val units = listOf("KB", "MB", "GB", "TB")
    var value = bytesPerSec.toDouble()
    var index = -1
    while (value >= 1024 && index < units.lastIndex) {
        value /= 1024
        index++
    }
    return String.format(java.util.Locale.US, "%.1f %s/s", value, units[index])
}

/** HH:mm:ss（传输记录的开始/结束时刻，与鸿蒙 Format.ets formatClock 同口径）。 */
private fun formatClock(ms: Long): String {
    if (ms <= 0) return ""
    return java.text.SimpleDateFormat("HH:mm:ss", java.util.Locale.getDefault()).format(java.util.Date(ms))
}

/** 耗时：45 秒 / 3 分 32 秒 / 1 小时 2 分。单位走资源（鸿蒙版在此硬编码中文，这里修正）。 */
private fun formatDuration(ms: Long): String {
    var s = Math.round(ms / 1000.0).toInt()
    if (s < 0) s = 0
    if (s < 60) {
        return L10n.t(R.string.s_tr_dur_sec, s.toString())
    }
    val m = s / 60
    val sec = s % 60
    if (m < 60) {
        return if (sec > 0) {
            L10n.t(R.string.s_tr_dur_min_sec, m.toString(), sec.toString())
        } else {
            L10n.t(R.string.s_tr_dur_min, m.toString())
        }
    }
    val h = m / 60
    val min = m % 60
    return if (min > 0) {
        L10n.t(R.string.s_tr_dur_hr_min, h.toString(), min.toString())
    } else {
        L10n.t(R.string.s_tr_dur_hr, h.toString())
    }
}

/**
 * 长按条目弹出的删除菜单（设计合同：记录清理走长按菜单）。
 * 单一项「删除」，红字；后续有更多操作（重试/查看详情）再扩展。
 */
@Composable
private fun DeleteRecordMenu(expanded: Boolean, onDismiss: () -> Unit, onDelete: () -> Unit) {
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        DropdownMenuItem(
            text = {
                Text(
                    L10n.t(R.string.s_2f4aaddde3),
                    fontSize = 14.sp,
                    color = SfColors.Error,
                )
            },
            onClick = {
                onDismiss()
                onDelete()
            },
        )
    }
}

/**
 * 开始/结束/耗时一行（对齐鸿蒙 TransfersView.timesLine：未结束的结束时间显示 —）。
 * 任务落定后追加「事实速度」：bytesDone ÷ 实际耗时——完成/失败/取消记录的实际吞吐。
 */
private fun timesLine(snapshot: TransferSnapshot): String {
    val start = snapshot.startedAtMs
    val end = snapshot.finishedAtMs ?: 0L
    val text = StringBuilder()
    text.append(L10n.t(R.string.s_tr_start_at)).append(' ')
        .append(if (start > 0) formatClock(start) else "—")
    text.append(" · ").append(L10n.t(R.string.s_tr_end_at)).append(' ')
        .append(if (end > 0) formatClock(end) else "—")
    if (start > 0 && end > 0 && end >= start) {
        val elapsedMs = end - start
        text.append(" · ").append(L10n.t(R.string.s_tr_cost)).append(' ')
            .append(formatDuration(elapsedMs))
        // 事实速度：转过的字节数 ÷ 真实用时（失败/取消记录同样成立——事实既然如此）
        if (elapsedMs >= 1000) {
            val bytesPerSec = snapshot.bytesDone * 1000uL / elapsedMs.toULong()
            text.append(" · ").append(
                L10n.t(R.string.s_tr_avg_speed, formatSpeed(bytesPerSec.toLong()))
            )
        }
    }
    return text.toString()
}

@Composable
private fun TransferRow(
    snapshot: TransferSnapshot,
    title: String,
    rate: Long,
    onCancel: () -> Unit,
    onForget: () -> Unit,
    onPauseToggle: () -> Unit,
) {
    val active = snapshot.state == TransferState.QUEUED ||
        snapshot.state == TransferState.RUNNING ||
        snapshot.state == TransferState.PAUSED
    val paused = snapshot.state == TransferState.PAUSED
    val fraction = if (snapshot.bytesTotal > 0uL) {
        (snapshot.bytesDone.toFloat() / snapshot.bytesTotal.toFloat()).coerceIn(0f, 1f)
    } else {
        0f
    }
    var menu by remember { mutableStateOf(false) }

    val content: @Composable () -> Unit = {
        Surface(
            shape = RoundedCornerShape(Dimens.RadiusM),
            color = SfColors.SurfaceCard,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(
                modifier = Modifier.padding(Dimens.Space4),
                verticalArrangement = Arrangement.spacedBy(Dimens.Space2),
            ) {
                Text(
                    title,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium,
                    color = SfColors.OnSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    buildString {
                        append(stateLabel(snapshot.state))
                        append(" · ${formatSize(snapshot.bytesDone.toLong())} / ${formatSize(snapshot.bytesTotal.toLong())}")
                        if (active && !paused) {
                            if (rate > 0) append(" · ${formatSpeed(rate)}")
                            if (snapshot.bytesTotal > 0uL) append(" · ${(fraction * 100).toInt()}%")
                        }
                        if (snapshot.filesTotal > 1uL) {
                            append(L10n.t(R.string.s_4085a25baf, (snapshot.filesDone), (snapshot.filesTotal)))
                        }
                    },
                    fontSize = 11.sp,
                    color = when (snapshot.state) {
                        TransferState.FAILED -> SfColors.Error
                        TransferState.COMPLETED -> SfColors.Success
                        else -> SfColors.OnSurfaceVariant
                    },
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                // 开始/结束/耗时独立一行（对齐鸿蒙）：状态行信息密度已经很高，混进去会被截断
                Text(
                    timesLine(snapshot),
                    fontSize = 11.sp,
                    color = SfColors.OnSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                // 错误单独一行（此前拼在状态行尾部，长错误会被 maxLines 吃掉）
                snapshot.error?.takeIf { it.isNotEmpty() }?.let {
                    Text(
                        it,
                        fontSize = 11.sp,
                        color = SfColors.Error,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                if (active) {
                    SfProgressBar(fraction)
                }
            }
        }
    }

    Box {
        if (active) {
            // 交互合同：进行中行内不放按钮；左滑出「暂停/继续 + 取消」。
            // （传输时候右侧没有取消；想暂停就左滑，想删除记录就长按。）
            SwipeActionsRow(
                actions = listOf(
                    SwipeAction(
                        label = L10n.t(if (paused) R.string.s_c7db6d4f1a else R.string.s_tr_pause),
                        container = SfColors.SearchFieldBg,
                        contentColor = SfColors.OnSurfaceVariant,
                        onClick = onPauseToggle,
                    ),
                    SwipeAction(
                        label = L10n.t(R.string.s_625fb26b4b),
                        container = SfColors.Error,
                        contentColor = Color.White,
                        onClick = onCancel,
                    ),
                ),
                backgroundColor = Color.Transparent,
                modifier = Modifier.padding(vertical = Dimens.Space1),
                onLongClick = { menu = true },
                content = content,
            )
        } else {
            // 已结束行：左滑移除（维持既有双按钮操作条）
            SwipeRevealRow(
                onDelete = onForget,
                deleteLabel = L10n.t(R.string.s_86048b4fea),
                backgroundColor = Color.Transparent,
                modifier = Modifier.padding(vertical = Dimens.Space1),
                onLongClick = { menu = true },
                content = content,
            )
        }
        DeleteRecordMenu(
            expanded = menu,
            onDismiss = { menu = false },
            onDelete = {
                if (active) onCancel()
                onForget()
            },
        )
    }
}

@Composable
private fun ResumableRow(pending: PendingTransfer, onResume: () -> Unit, onForget: () -> Unit) {
    val name = pending.sources.firstOrNull()?.trimEnd('/')?.substringAfterLast('/') ?: pending.id
    val extra = if (pending.sources.size > 1) L10n.t(R.string.s_80f66a2be2, (pending.sources.size)) else ""
    val dest = pending.destDir.trimEnd('/').substringAfterLast('/').ifEmpty { L10n.t(R.string.s_c2b9f4b9fc) }
    var menu by remember { mutableStateOf(false) }
    Box {
        // 左滑＝「忽略」，行内保留「继续」（正面动作常驻）；长按＝删除登记项
        SwipeRevealRow(
            onDelete = onForget,
            deleteLabel = L10n.t(R.string.s_c0d5d68f5f),
            backgroundColor = Color.Transparent,
            modifier = Modifier.padding(vertical = Dimens.Space1),
            onLongClick = { menu = true },
    ) {
        Surface(
            shape = RoundedCornerShape(Dimens.RadiusM),
            color = SfColors.SurfaceCard,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Row(
                modifier = Modifier.padding(Dimens.Space4),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Dimens.Space2),
            ) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(
                        "$name$extra",
                        fontSize = 14.sp,
                        fontWeight = FontWeight.Medium,
                        color = SfColors.OnSurface,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        L10n.t(R.string.s_bcb00b46d8, (if (pending.isMove) L10n.t(R.string.s_68d982a1cc) else L10n.t(R.string.s_79d3abe929))) +
                            L10n.t(R.string.s_fc24c2ecf3, (formatSize(pending.bytesDone.toLong())), (formatSize(pending.bytesTotal.toLong())), (dest)),
                        fontSize = 11.sp,
                        color = SfColors.OnSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                TextButton(onClick = onResume) { Text(L10n.t(R.string.s_c7db6d4f1a), fontSize = 12.sp) }
                TextButton(onClick = onForget) { Text(L10n.t(R.string.s_c0d5d68f5f), fontSize = 12.sp) }
            }
        }
    }
        DeleteRecordMenu(
            expanded = menu,
            onDismiss = { menu = false },
            onDelete = onForget,
        )
    }
}

/** 近邻流水卡片行：与传输任务行同版式（圆角卡 + 14 号标题/11 号次信息 + 右侧大小）。 */
@Composable
private fun LocalSendRecordRow(r: LocalSendReceived) {
    val context = LocalContext.current
    val fmt = java.text.SimpleDateFormat("MM-dd HH:mm", java.util.Locale.getDefault())
    Surface(
        shape = RoundedCornerShape(Dimens.RadiusM),
        color = SfColors.SurfaceCard,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier.padding(Dimens.Space4),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Dimens.Space3),
        ) {
            Text(if (r.incoming) "⇣" else "⇡", fontSize = 16.sp, color = SfColors.Primary)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    r.name,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium,
                    color = SfColors.OnSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    (r.peer?.let { "$it · " } ?: "") + fmt.format(java.util.Date(r.atMs)),
                    fontSize = 11.sp,
                    color = SfColors.OnSurfaceVariant,
                )
            }
            Text(
                android.text.format.Formatter.formatShortFileSize(context, r.sizeBytes),
                fontSize = 11.sp,
                color = SfColors.OnSurfaceVariant,
            )
        }
    }
}
