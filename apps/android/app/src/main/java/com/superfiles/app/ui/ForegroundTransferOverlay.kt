package com.superfiles.app.ui

import com.superfiles.app.L10n
import com.superfiles.app.R

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.background
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.DriveFileMove
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.superfiles.app.VfsViewModel

/**
 * 前台传输浮层（复制/移动）。
 *
 * 任务一开始只在 App 内展示进度，**不**进传输中心、也**不**发通知；用户可以选择
 * 「终止」或「后台传输」。按下「后台传输」后这批任务才交给传输中心 + FGS 通知栏
 * 继续跑（[VfsViewModel.sendForegroundTransfersToBackground]）。App 被切到后台时
 * 自动等同于按下「后台传输」，避免界面不可见却也没有保活。
 *
 * 模态但不可取消：点外部/返回键都不打断传输，必须显式选两个按钮之一。
 */
@Composable
fun ForegroundTransferOverlay(viewModel: VfsViewModel) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val active = state.transfers.filter { it.id in state.foregroundTransfers }
    if (active.isEmpty()) return

    val bytesDone = active.sumOf { it.bytesDone.toLong() }
    val bytesTotal = active.sumOf { it.bytesTotal.toLong() }
    val filesDone = active.sumOf { it.filesDone.toLong() }
    val filesTotal = active.sumOf { it.filesTotal.toLong() }
    val rate = active.sumOf { state.transferRates[it.id] ?: 0L }
    val moving = active.any { it.id in state.foregroundMoves }
    val copying = active.any { it.id !in state.foregroundMoves }
    val title = when {
        moving && copying -> L10n.t(R.string.s_06b403e86d)
        moving -> L10n.t(R.string.s_3902590e27)
        else -> L10n.t(R.string.s_1c72b75f2a)
    }
    val current = active.firstNotNullOfOrNull { it.current?.takeIf { name -> name.isNotBlank() } }
        ?: L10n.t(R.string.s_dcfb689011)
    val fraction = if (bytesTotal > 0) (bytesDone.toFloat() / bytesTotal).coerceIn(0f, 1f) else 0f

    Dialog(
        onDismissRequest = {},
        properties = DialogProperties(dismissOnBackPress = false, dismissOnClickOutside = false),
    ) {
        Surface(
            shape = RoundedCornerShape(Dimens.RadiusL),
            color = SfColors.Surface,
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(Dimens.Space6),
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(Dimens.Space3),
                ) {
                    androidx.compose.foundation.layout.Box(
                        modifier = Modifier
                            .size(40.dp)
                            .clip(RoundedCornerShape(Dimens.RadiusS))
                            .background(SfColors.AvatarBg),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            if (moving) Icons.Outlined.DriveFileMove else Icons.Outlined.ContentCopy,
                            contentDescription = null,
                            modifier = Modifier.size(20.dp),
                            tint = SfColors.PrimaryWarm,
                        )
                    }
                    Column(Modifier.weight(1f)) {
                        Text(title, fontSize = 17.sp, fontWeight = FontWeight.Bold, color = SfColors.OnSurface)
                        Text(
                            if (filesTotal > 1) L10n.t(R.string.s_b5d2d7be2c, (filesTotal)) else L10n.t(R.string.s_32a1bd2536),
                            fontSize = 12.sp,
                            color = SfColors.OnSurfaceVariant,
                        )
                    }
                }

                Spacer(Modifier.height(Dimens.Space4))

                // 进度本体放在白卡里，和首页/选择器同一套分组卡语言
                ListSectionCard {
                    Column(modifier = Modifier.padding(Dimens.Space4)) {
                        Text(
                            current,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.Medium,
                            color = SfColors.OnSurface,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Spacer(Modifier.height(Dimens.Space3))
                        SfProgressBar(fraction)
                        Spacer(Modifier.height(Dimens.Space2))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                if (filesTotal > 1) {
                                    L10n.t(R.string.s_9a2d499961, (filesDone.coerceAtMost(filesTotal)), (filesTotal)) +
                                        "${formatSize(bytesDone)} / ${formatSize(bytesTotal)}"
                                } else {
                                    "${formatSize(bytesDone)} / ${formatSize(bytesTotal)}"
                                },
                                fontSize = 11.sp,
                                color = SfColors.OnSurfaceVariant,
                            )
                            Spacer(Modifier.weight(1f))
                            Text(
                                if (rate > 0) "${formatSize(rate)}/s" else "…",
                                fontSize = 11.sp,
                                fontWeight = FontWeight.Medium,
                                color = SfColors.Primary,
                            )
                        }
                    }
                }

                Spacer(Modifier.height(Dimens.Space4))

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(Dimens.Space2, Alignment.End),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    TextButton(onClick = viewModel::cancelForegroundTransfers) {
                        Text(L10n.t(R.string.s_ff6c6ad72b), fontSize = 13.sp, color = SfColors.Error)
                    }
                    Button(
                        onClick = viewModel::sendForegroundTransfersToBackground,
                        shape = RoundedCornerShape(Dimens.RadiusS),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = SfColors.Primary,
                            contentColor = Color.White,
                        ),
                        contentPadding = androidx.compose.foundation.layout.PaddingValues(
                            horizontal = 18.dp,
                            vertical = 6.dp,
                        ),
                    ) { Text(L10n.t(R.string.s_d61215e8e5), fontSize = 13.sp) }
                }
            }
        }
    }
}
