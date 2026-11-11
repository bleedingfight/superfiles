package com.superfiles.app.ui

import com.superfiles.app.L10n
import com.superfiles.app.R

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.superfiles.app.VfsViewModel
import com.superfiles.core.Entry

/**
 * 「⋯」操作面板 + 各操作弹窗的全局宿主：首页「最近打开」与文件页共用，
 * 由 AppRoot 挂一次即可任意页面触发（状态经 ViewModel.actionsTarget 传递）。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FileActionsHost(viewModel: VfsViewModel) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    var renameTarget by remember { mutableStateOf<Entry?>(null) }
    var copyTarget by remember { mutableStateOf<Entry?>(null) }
    var moveTarget by remember { mutableStateOf<Entry?>(null) }
    var uploadTarget by remember { mutableStateOf<Entry?>(null) }
    var compressTarget by remember { mutableStateOf<Entry?>(null) }
    var deleteTarget by remember { mutableStateOf<Entry?>(null) }
    var nearbyTarget by remember { mutableStateOf<List<Entry>?>(null) }

    state.actionsTarget?.let { entry ->
        ModalBottomSheet(onDismissRequest = viewModel::dismissActions, containerColor = SfColors.Surface) {
            FileActionSheet(
                entry = entry,
                uploadEnabled = true, // 上传 = 目标选择器 + 引擎复制，落到任意 VFS（本地/NAS/云盘）
                isFavorite = state.favoriteIds.contains(entry.id),
                onAction = { action ->
                    viewModel.dismissActions()
                    when (action) {
                        FileAction.Favorite -> viewModel.toggleFavorite(entry)
                        FileAction.IndexPin -> viewModel.addIndexPin(entry)
                        FileAction.Copy -> copyTarget = entry
                        FileAction.Move -> moveTarget = entry
                        FileAction.Share -> viewModel.startShare(listOf(entry))
                        FileAction.SendNearby -> nearbyTarget = listOf(entry)
                        FileAction.Details -> viewModel.openDetails(entry)
                        FileAction.Compress -> compressTarget = entry
                        FileAction.Upload -> uploadTarget = entry
                        FileAction.OpenWith ->
                            openEntryFile(context, viewModel, entry, chooser = true)
                        FileAction.Rename -> renameTarget = entry
                        FileAction.Delete -> deleteTarget = entry
                    }
                },
            )
        }
    }

    renameTarget?.let { entry ->
        RenameDialog(
            entry = entry,
            onDismiss = { renameTarget = null },
            onConfirm = { name ->
                renameTarget = null
                viewModel.renameEntry(entry, name)
            },
        )
    }

    copyTarget?.let { entry ->
        DestPickerDialog(
            viewModel = viewModel,
            title = L10n.t(R.string.s_e52ea7a274),
            confirmLabel = L10n.t(R.string.s_92cc5af208),
            onDismiss = { copyTarget = null },
            onPick = { dest ->
                copyTarget = null
                viewModel.startTransfer(listOf(entry.id), dest.id, move = false)
            },
        )
    }

    moveTarget?.let { entry ->
        DestPickerDialog(
            viewModel = viewModel,
            title = L10n.t(R.string.s_5c4c1e6183),
            confirmLabel = L10n.t(R.string.s_13b54eda03),
            onDismiss = { moveTarget = null },
            onPick = { dest ->
                moveTarget = null
                viewModel.startTransfer(listOf(entry.id), dest.id, move = true)
            },
        )
    }

    uploadTarget?.let { entry ->
        DestPickerDialog(
            viewModel = viewModel,
            title = L10n.t(R.string.s_d1cc55f96e, (entry.name)),
            confirmLabel = L10n.t(R.string.s_d1e251c741),
            onDismiss = { uploadTarget = null },
            onPick = { dest ->
                uploadTarget = null
                viewModel.startTransfer(listOf(entry.id), dest.id, move = false)
            },
        )
    }

    compressTarget?.let { entry ->
        CompressDialog(
            defaultName = entry.name.substringBeforeLast('.', entry.name) + ".zip",
            nameKey = entry.id,
            collectDirs = viewModel::collectDirs,
            onDismiss = { compressTarget = null },
            onConfirm = { name, dest, deflate ->
                compressTarget = null
                viewModel.compressEntry(entry, dest, name, deflate)
            },
        )
    }

    deleteTarget?.let { entry ->
        DangerConfirmDialog(
            title = L10n.t(R.string.s_2f4aaddde3),
            message = L10n.t(R.string.s_6cb5cdaeda, (entry.name)),
            confirmLabel = L10n.t(R.string.s_2f4aaddde3),
            onConfirm = {
                deleteTarget = null
                viewModel.delete(entry)
            },
            onCancel = { deleteTarget = null },
        )
    }

    // 详情已升级为整页（DetailsPage，AppRoot 挂载），这里不再渲染对话框

    // 同名冲突确认（复制/移动共用；来源可以是「⋯」单项或多选批量）
    state.conflictPrompt?.let { prompt ->
        ConflictDialog(
            prompt = prompt,
            onResolve = viewModel::resolveConflict,
            onCancel = viewModel::cancelConflictResolution,
        )
    }

    // 就近分享（ADR 0005）：二维码 + 链接；关闭即焚
    state.shareInfo?.let { info ->
        ShareDialog(info = info, onStop = viewModel::stopShare)
    }

    nearbyTarget?.let { entries ->
        LocalSendPeerPicker(
            viewModel = viewModel,
            entries = entries,
            onDismiss = { nearbyTarget = null },
        )
    }

    // 压缩进度（大文件可见；v1 不支持中途取消）
    state.compress?.let { c ->
        SfDialog(
            onDismissRequest = {},
            title = L10n.t(R.string.s_15c550f3b7),
            dismissOnBackPress = false,
            dismissOnClickOutside = false,
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(Dimens.Space2)) {
                LinearProgressIndicator(
                    progress = {
                        if (c.total == 0L) 0f else (c.done.toFloat() / c.total).coerceIn(0f, 1f)
                    },
                    modifier = Modifier.fillMaxWidth(),
                )
                Text(
                    "${formatSize(c.done)} / ${formatSize(c.total)}",
                    fontSize = 11.sp,
                    color = SfColors.OnSurfaceVariant,
                )
            }
        }
    }
}
