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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.CloudUpload
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.superfiles.app.VfsViewModel
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
    val active = tasks.filter {
        it.state == TransferState.QUEUED || it.state == TransferState.RUNNING
    }
    val finished = tasks.filter {
        it.state != TransferState.QUEUED && it.state != TransferState.RUNNING
    }
    LaunchedEffect(Unit) { viewModel.refreshResumable() }

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

            if (active.isEmpty() && finished.isEmpty() && state.resumable.isEmpty()) {
                EmptyTransfers()
                return@Column
            }

            LazyColumn(
                modifier = Modifier.fillMaxSize().padding(horizontal = Dimens.Space6),
            ) {
                if (active.isNotEmpty()) {
                    item { SectionTitle(L10n.t(R.string.s_25f9246234), active.size) }
                    items(active.size) { idx ->
                        TransferRow(
                            snapshot = active[idx],
                            rate = state.transferRates[active[idx].id] ?: 0L,
                            onCancel = { viewModel.cancelTransfer(active[idx].id) },
                            onForget = { viewModel.forgetTransfer(active[idx].id) },
                        )
                    }
                }

                if (finished.isNotEmpty()) {
                    item { SectionTitle(L10n.t(R.string.s_fad5222ca0), finished.size) }
                    items(finished.size) { idx ->
                        TransferRow(
                            snapshot = finished[idx],
                            rate = state.transferRates[finished[idx].id] ?: 0L,
                            onCancel = { viewModel.cancelTransfer(finished[idx].id) },
                            onForget = { viewModel.forgetTransfer(finished[idx].id) },
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
                    items(state.resumable.size) { idx ->
                        ResumableRow(
                            pending = state.resumable[idx],
                            onResume = { viewModel.resumeTransfer(state.resumable[idx].id) },
                            onForget = { viewModel.forgetResumable(state.resumable[idx].id) },
                        )
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
    TransferState.COMPLETED -> L10n.t(R.string.s_fad5222ca0)
    TransferState.FAILED -> L10n.t(R.string.s_acd5cb847a)
    TransferState.CANCELLED -> L10n.t(R.string.s_2111ccbb19)
}

/** 速度格式（与 formatSize 同口径：KB/MB/GB 一位小数 + /s）。 */
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

@Composable
private fun TransferRow(
    snapshot: TransferSnapshot,
    rate: Long,
    onCancel: () -> Unit,
    onForget: () -> Unit,
) {
    val active = snapshot.state == TransferState.QUEUED || snapshot.state == TransferState.RUNNING
    val fraction = if (snapshot.bytesTotal > 0uL) {
        (snapshot.bytesDone.toFloat() / snapshot.bytesTotal.toFloat()).coerceIn(0f, 1f)
    } else {
        0f
    }
    Surface(
        shape = RoundedCornerShape(Dimens.RadiusM),
        color = SfColors.SurfaceCard,
        modifier = Modifier.fillMaxWidth().padding(vertical = Dimens.Space1),
    ) {
        Column(
            modifier = Modifier.padding(Dimens.Space4),
            verticalArrangement = Arrangement.spacedBy(Dimens.Space2),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    snapshot.current ?: snapshot.id,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium,
                    color = SfColors.OnSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                if (active) {
                    TextButton(onClick = onCancel) { Text(L10n.t(R.string.s_625fb26b4b), fontSize = 12.sp) }
                } else {
                    TextButton(onClick = onForget) { Text(L10n.t(R.string.s_86048b4fea), fontSize = 12.sp) }
                }
            }
            Text(
                buildString {
                    append(stateLabel(snapshot.state))
                    append(" · ${formatSize(snapshot.bytesDone.toLong())} / ${formatSize(snapshot.bytesTotal.toLong())}")
                    if (active) {
                        if (rate > 0) append(" · ${formatSpeed(rate)}")
                        if (snapshot.bytesTotal > 0uL) append(" · ${(fraction * 100).toInt()}%")
                    }
                    if (snapshot.filesTotal > 1uL) {
                        append(L10n.t(R.string.s_4085a25baf, (snapshot.filesDone), (snapshot.filesTotal)))
                    }
                    snapshot.error?.let { append(" · $it") }
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
            if (active) {
                SfProgressBar(fraction)
            }
        }
    }
}

@Composable
private fun ResumableRow(pending: PendingTransfer, onResume: () -> Unit, onForget: () -> Unit) {
    val name = pending.sources.firstOrNull()?.trimEnd('/')?.substringAfterLast('/') ?: pending.id
    val extra = if (pending.sources.size > 1) L10n.t(R.string.s_80f66a2be2, (pending.sources.size)) else ""
    val dest = pending.destDir.trimEnd('/').substringAfterLast('/').ifEmpty { L10n.t(R.string.s_c2b9f4b9fc) }
    Surface(
        shape = RoundedCornerShape(Dimens.RadiusM),
        color = SfColors.SurfaceCard,
        modifier = Modifier.fillMaxWidth().padding(vertical = Dimens.Space1),
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
