package com.superfiles.app.ui

import com.superfiles.app.L10n
import com.superfiles.app.R

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.InsertDriveFile
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.superfiles.app.CleanupItem
import com.superfiles.app.VfsViewModel
import java.io.File

/**
 * 存储清理页：扫描用户数据目录 + 应用沙盒，按大小从大到小排序。
 * 目录可点击进入、左滑删除；长按进入多选，支持全选与批量删除。
 */
@Composable
fun StorageCleanupScreen(viewModel: VfsViewModel, onBack: () -> Unit) {
    val cleanupItems by viewModel.cleanupItems.collectAsStateWithLifecycle()
    val scanning by viewModel.cleanupScanning.collectAsStateWithLifecycle()
    val cleanupPath by viewModel.cleanupPath.collectAsStateWithLifecycle()
    val context = LocalContext.current

    var pendingDelete by remember { mutableStateOf<List<CleanupItem>>(emptyList()) }
    var selecting by remember { mutableStateOf(false) }
    var selected by remember { mutableStateOf<Set<String>>(emptySet()) }

    LaunchedEffect(Unit) { viewModel.scanStorageForCleanup() }
    // 切换目录时退出多选
    LaunchedEffect(cleanupPath) {
        selecting = false
        selected = emptySet()
    }

    val selectedItems = cleanupItems.filter { it.path in selected }
    val selectedSize = selectedItems.sumOf { it.size }

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
                if (selecting) {
                    IconButton(onClick = {
                        selecting = false
                        selected = emptySet()
                    }) {
                        Icon(
                            Icons.Outlined.Close,
                            contentDescription = L10n.t(R.string.s_625fb26b4b),
                        )
                    }
                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(1.dp),
                    ) {
                        Text(
                            L10n.t(R.string.s_cleanup_selected, selected.size.toString()),
                            fontSize = 17.sp,
                            fontWeight = FontWeight.Bold,
                            color = SfColors.OnSurface,
                        )
                        Text(
                            formatSize(selectedSize),
                            fontSize = 11.sp,
                            color = SfColors.OnSurfaceVariant,
                        )
                    }
                    TextButton(
                        onClick = { selected = cleanupItems.map { it.path }.toSet() },
                    ) {
                        Text(L10n.t(R.string.s_cleanup_select_all))
                    }
                    TextButton(
                        enabled = selected.isNotEmpty(),
                        onClick = { pendingDelete = selectedItems },
                    ) {
                        Text(
                            L10n.t(R.string.s_cleanup_delete_n, selected.size.toString()),
                            color = SfColors.Error,
                        )
                    }
                } else {
                    IconButton(onClick = { if (!viewModel.cleanupGoUp()) onBack() }) {
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = L10n.t(R.string.s_5f411223ca),
                        )
                    }
                    Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                        Text(
                            cleanupPath?.let { File(it).name } ?: L10n.t(R.string.s_cleanup_title),
                            fontSize = 17.sp,
                            fontWeight = FontWeight.Bold,
                            color = SfColors.OnSurface,
                        )
                        Text(
                            L10n.t(R.string.s_cleanup_hint),
                            fontSize = 11.sp,
                            color = SfColors.OnSurfaceVariant,
                        )
                    }
                }
            }

            Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
                when {
                    scanning -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator(color = SfColors.Primary)
                    }
                    cleanupItems.isEmpty() -> Box(
                        Modifier.fillMaxSize(),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            L10n.t(R.string.s_cleanup_empty),
                            fontSize = 13.sp,
                            color = SfColors.OnSurfaceVariant,
                        )
                    }
                    else -> LazyColumn(
                        modifier = Modifier.fillMaxSize(),
                        contentPadding = PaddingValues(
                            horizontal = Dimens.Space4,
                            vertical = Dimens.Space2,
                        ),
                    ) {
                        items(cleanupItems, key = { it.path }) { item ->
                            SwipeRevealRow(
                                onDelete = { pendingDelete = listOf(item) },
                                enabled = !selecting,
                                backgroundColor = SfColors.Surface,
                            ) {
                                FileListRow(
                                    badge = cleanupBadge(item),
                                    name = item.name,
                                    meta = formatSize(item.size),
                                    selected = selecting && item.path in selected,
                                    onClick = {
                                        if (selecting) {
                                            selected = if (item.path in selected) {
                                                selected - item.path
                                            } else {
                                                selected + item.path
                                            }
                                        } else {
                                            viewModel.openCleanupItem(context, item)
                                        }
                                    },
                                    onLongClick = {
                                        selecting = true
                                        selected = selected + item.path
                                    },
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    if (pendingDelete.isNotEmpty()) {
        val totalSize = pendingDelete.sumOf { it.size }
        SfDialog(
            onDismissRequest = { pendingDelete = emptyList() },
            title = L10n.t(R.string.s_cleanup_confirm_title),
        ) {
            Text(
                if (pendingDelete.size == 1) {
                    L10n.t(
                        R.string.s_cleanup_confirm_msg,
                        (pendingDelete.first().name),
                        (formatSize(totalSize)),
                    )
                } else {
                    L10n.t(
                        R.string.s_cleanup_confirm_batch,
                        (pendingDelete.size.toString()),
                        (formatSize(totalSize)),
                    )
                },
                fontSize = 13.sp,
                color = SfColors.OnSurface,
            )
            Row(
                modifier = Modifier.fillMaxWidth().padding(top = Dimens.Space3),
                horizontalArrangement = Arrangement.End,
            ) {
                TextButton(onClick = { pendingDelete = emptyList() }) {
                    Text(L10n.t(R.string.s_625fb26b4b))
                }
                TextButton(
                    onClick = {
                        val batch = pendingDelete
                        pendingDelete = emptyList()
                        if (batch.size == 1) {
                            viewModel.deleteCleanupItem(batch.first())
                        } else {
                            viewModel.deleteCleanupItems(batch)
                        }
                        selecting = false
                        selected = emptySet()
                    },
                ) {
                    Text(L10n.t(R.string.s_2f4aaddde3), color = SfColors.Error)
                }
            }
        }
    }
}

@Composable
private fun cleanupBadge(item: CleanupItem): FileBadge =
    if (item.isDir) {
        FileBadge(Icons.Outlined.Folder, SfColors.AvatarBg, SfColors.PrimaryWarm, null)
    } else {
        FileBadge(
            Icons.Outlined.InsertDriveFile,
            SfColors.SurfaceTint,
            SfColors.OnSurfaceVariant,
            null,
        )
    }
