package com.superfiles.app.ui

import com.superfiles.app.IndexTarget
import com.superfiles.app.L10n
import com.superfiles.app.R
import com.superfiles.app.VfsViewModel

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.Cloud
import androidx.compose.material.icons.outlined.PhoneAndroid
import androidx.compose.material.icons.outlined.Storage
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle

/**
 * 索引管理：本地存储默认建立索引；每个网络存储（SMB/WebDAV/S3/云盘）由
 * 用户自己决定是否建立索引、何时重建、何时删除。
 */
@Composable
fun IndexManageScreen(viewModel: VfsViewModel, onBack: () -> Unit) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    var pendingLocalDelete by remember { mutableStateOf<IndexTarget?>(null) }

    LaunchedEffect(Unit) { viewModel.refreshIndexTargets() }

    val local = state.indexTargets.filter { it.isLocal }
    val network = state.indexTargets.filterNot { it.isLocal }

    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
        Column(
            modifier = Modifier
                .widthIn(max = Adaptive.ListMaxWidth)
                .fillMaxSize(),
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = Dimens.Space2, vertical = Dimens.Space1),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(onClick = onBack) {
                    Icon(
                        Icons.AutoMirrored.Filled.ArrowBack,
                        contentDescription = L10n.t(R.string.s_5f411223ca),
                    )
                }
                Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    Text(
                        L10n.t(R.string.s_index_manage_title),
                        fontSize = 17.sp,
                        fontWeight = FontWeight.Bold,
                        color = SfColors.OnSurface,
                    )
                    Text(
                        L10n.t(R.string.s_index_manage_hint),
                        fontSize = 11.sp,
                        color = SfColors.OnSurfaceVariant,
                    )
                }
            }

            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(
                    horizontal = Dimens.Space4,
                    vertical = Dimens.Space2,
                ),
                verticalArrangement = Arrangement.spacedBy(Dimens.Space1),
            ) {
                item {
                    IndexSummaryCard(
                        entries = state.indexTargets.sumOf { it.entries },
                        bytes = viewModel.indexFileBytes(),
                    )
                }
                item { SectionTitle(L10n.t(R.string.s_index_section_local)) }
                items(local, key = { it.id }) { target ->
                    // 与其他列表一致：左滑露出删除；本地索引删除前给出警告和原因。
                    SwipeRevealRow(
                        onDelete = { pendingLocalDelete = target },
                        // 行内容本身是圆角卡片，外层不要铺满底色，否则圆角会被盖掉
                        backgroundColor = androidx.compose.ui.graphics.Color.Transparent,
                        enabled = target.indexed,
                    ) {
                        IndexTargetRow(
                            target = target,
                            running = viewModel.isIndexTargetRunning(target),
                            progress = state.scanFraction,
                            onRebuild = { viewModel.rebuildIndexTarget(target) },
                        )
                    }
                }

                item { SectionTitle(L10n.t(R.string.s_index_section_network)) }
                if (network.isEmpty()) {
                    item {
                        Text(
                            L10n.t(R.string.s_index_empty_network),
                            fontSize = 12.sp,
                            color = SfColors.OnSurfaceVariant,
                            modifier = Modifier.padding(vertical = Dimens.Space2),
                        )
                    }
                } else {
                    items(network, key = { it.id }) { target ->
                        // 网络存储索引没有额外后果（只影响搜索/分类覆盖范围），左滑直接删。
                        SwipeRevealRow(
                            onDelete = { viewModel.clearIndexTarget(target) },
                            backgroundColor = androidx.compose.ui.graphics.Color.Transparent,
                            enabled = target.indexed,
                        ) {
                            IndexTargetRow(
                                target = target,
                                running = viewModel.isIndexTargetRunning(target),
                                progress = state.scanFraction,
                                onRebuild = { viewModel.rebuildIndexTarget(target) },
                            )
                        }
                    }
                }
            }
        }
    }

    pendingLocalDelete?.let { target ->
        DangerConfirmDialog(
            title = L10n.t(R.string.s_index_delete_local_title),
            message = L10n.t(R.string.s_index_delete_local_message),
            confirmLabel = L10n.t(R.string.s_index_delete),
            onConfirm = {
                pendingLocalDelete = null
                viewModel.clearIndexTarget(target)
            },
            onCancel = { pendingLocalDelete = null },
        )
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(
        text,
        fontSize = 12.sp,
        fontWeight = FontWeight.Medium,
        color = SfColors.OnSurfaceVariant,
        modifier = Modifier.padding(top = Dimens.Space2, bottom = Dimens.Space1),
    )
}

@Composable
private fun IndexSummaryCard(entries: Long, bytes: Long) {
    Surface(
        shape = RoundedCornerShape(Dimens.RadiusM),
        color = SfColors.SurfaceCard,
        modifier = Modifier.fillMaxWidth().padding(top = Dimens.Space1),
    ) {
        Column(
            modifier = Modifier.padding(horizontal = Dimens.Space3, vertical = Dimens.Space2),
            verticalArrangement = Arrangement.spacedBy(1.dp),
        ) {
            Text(
                L10n.t(R.string.s_index_summary),
                fontSize = 12.sp,
                color = SfColors.OnSurfaceVariant,
            )
            Text(
                L10n.t(
                    R.string.s_index_summary_line,
                    entries.toString(),
                    formatSize(bytes),
                ),
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
                color = SfColors.OnSurface,
            )
        }
    }
}

@Composable
private fun IndexTargetRow(
    target: IndexTarget,
    running: Boolean,
    progress: Float?,
    onRebuild: () -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(Dimens.RadiusM),
        color = SfColors.SurfaceCard,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = Dimens.Space3, vertical = Dimens.Space2),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Dimens.Space3),
        ) {
            if (target.isLocal) {
                Box(
                    modifier = Modifier
                        .size(36.dp)
                        .clip(RoundedCornerShape(Dimens.RadiusS))
                        .background(SfColors.SearchFieldBg),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        Icons.Outlined.PhoneAndroid,
                        contentDescription = null,
                        modifier = Modifier.size(20.dp),
                        tint = SfColors.Primary,
                    )
                }
            } else {
                // 与首页/网络面板同一套协议图标（WebDAV / SMB / S3 / 云盘各有区分）
                StorageProtoLogo(target.mount?.config?.protocol ?: "", 36.dp)
            }
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(1.dp),
            ) {
                Text(target.name, fontSize = 14.sp, color = SfColors.OnSurface)
                Text(
                    "${target.kind} · " + when {
                        running -> L10n.t(
                            R.string.s_index_building_pct,
                            (((progress ?: 0f) * 100).toInt()).toString(),
                        )
                        target.indexed -> L10n.t(R.string.s_index_entries, target.entries.toString())
                        else -> L10n.t(R.string.s_index_not_built)
                    },
                    fontSize = 11.sp,
                    color = if (running) SfColors.Primary else SfColors.OnSurfaceVariant,
                )
                if (running) {
                    LinearProgressIndicator(
                        progress = { (progress ?: 0f).coerceIn(0f, 1f) },
                        modifier = Modifier.fillMaxWidth().padding(top = 2.dp),
                        color = SfColors.Primary,
                    )
                }
            }
            TextButton(enabled = !running, onClick = onRebuild) {
                Text(
                    L10n.t(
                        if (target.indexed) R.string.s_index_rebuild else R.string.s_index_build,
                    ),
                    fontSize = 12.sp,
                )
            }
        }
    }
}
