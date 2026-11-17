package com.superfiles.app.ui

import com.superfiles.app.L10n
import com.superfiles.app.R

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.Star
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.superfiles.app.IndexPin
import com.superfiles.app.VfsViewModel
import com.superfiles.core.Entry
import com.superfiles.core.EntryKind
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/** 完整收藏页（首页「我的收藏 → 管理」进入；底部导航不再为它单独占位）。 */
@Composable
fun FavoritesPage(
    viewModel: VfsViewModel,
    onBack: () -> Unit,
    onOpenDirectory: () -> Unit,
) {
    // 大屏可读宽度（docs/06 §7）：页头与列表一起居中限宽
    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
        Column(modifier = Modifier.widthIn(max = Adaptive.ListMaxWidth).fillMaxSize()) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = Dimens.Space2, vertical = Dimens.Space1),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(onClick = onBack) {
                    Icon(
                        androidx.compose.material.icons.Icons.AutoMirrored.Filled.ArrowBack,
                        contentDescription = L10n.t(R.string.s_5f411223ca),
                    )
                }
                Text(L10n.t(R.string.s_ae336cd047), fontSize = 17.sp, fontWeight = FontWeight.Bold, color = SfColors.OnSurface)
            }
            Box(modifier = Modifier.weight(1f)) {
                FavoritesScreen(viewModel, onOpenDirectory = onOpenDirectory)
            }
        }
    }
}

/**
 * 收藏 Tab：两个语义独立的分区——
 * 「收藏」= 快捷访问（纯标记、零成本）；「索引位置」= 用户显式授权的索引订阅
 * （进后台增量扫描、参与闪电搜索、成本由用户判断）。
 */
@Composable
fun FavoritesScreen(viewModel: VfsViewModel, onOpenDirectory: () -> Unit = {}) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val context = LocalContext.current

    LazyColumn(modifier = Modifier.fillMaxSize().padding(horizontal = Dimens.Space6)) {
        item {
            SectionTitle(title = L10n.t(R.string.s_ae336cd047), hint = L10n.t(R.string.s_e4c866de60))
        }
        if (state.favorites.isEmpty()) {
            item {
                HintText(L10n.t(R.string.s_a2757fab59))
            }
        } else {
            items(state.favorites, key = { it.entry.id }) { fav ->
                SwipeRevealRow(
                    onDelete = { viewModel.deleteEntries(listOf(fav.entry)) },
                    backgroundColor = SfColors.Surface,
                ) {
                    FileListRow(
                        badge = fileBadgeOf(fav.entry),
                        name = fav.entry.name,
                        meta = state.favoriteLocations[fav.entry.id] ?: "",
                        onClick = {
                            if (fav.entry.kind == EntryKind.DIRECTORY) {
                                viewModel.openEntry(fav.entry)
                                onOpenDirectory() // 目录导航发生在文件 Tab，切过去才看得见
                            } else {
                                openEntryPrimary(context, viewModel, fav.entry)
                            }
                        },
                        trailing = {
                            CompactIconButton(
                                Icons.Outlined.Star,
                                L10n.t(R.string.s_f22cec2866),
                                tint = SfColors.PrimaryWarm,
                                onClick = { viewModel.toggleFavorite(fav.entry) },
                            )
                        },
                    )
                }
            }
        }
        item {
            Spacer(Modifier.height(Dimens.Space4))
            SectionTitle(
                title = L10n.t(R.string.s_9efeeda70c),
                hint = L10n.t(R.string.s_6cfcea570c),
                action = L10n.t(R.string.s_694fc5efa9),
                onAction = viewModel::refreshIndexPins,
            )
        }
        if (state.indexPins.isEmpty()) {
            item {
                HintText(L10n.t(R.string.s_755250b5af))
            }
        } else {
            items(state.indexPins, key = { it.id }) { pin ->
                PinRow(pin = pin, onRemove = { viewModel.removeIndexPin(pin) })
            }
        }
        item { Spacer(Modifier.height(Dimens.Space8)) }
    }
}

@Composable
private fun SectionTitle(
    title: String,
    hint: String,
    action: String? = null,
    onAction: (() -> Unit)? = null,
) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(top = Dimens.Space3, bottom = Dimens.Space1),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, fontSize = 17.sp, fontWeight = FontWeight.Bold, color = SfColors.OnSurface)
            Text(hint, fontSize = 11.sp, color = SfColors.OnSurfaceVariant)
        }
        if (action != null && onAction != null) {
            TextButton(onClick = onAction) { Text(action, fontSize = 13.sp) }
        }
    }
}

@Composable
private fun HintText(text: String) {
    Text(
        text,
        fontSize = 12.sp,
        color = SfColors.OnSurfaceVariant,
        modifier = Modifier.padding(vertical = Dimens.Space2),
    )
}

@Composable
private fun PinRow(pin: IndexPin, onRemove: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = false) {}
            .padding(vertical = Dimens.Space2),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Dimens.Space3),
    ) {
        Icon(
            Icons.Outlined.FolderOpen,
            contentDescription = null,
            modifier = Modifier.size(Dimens.Space6),
            tint = SfColors.Primary,
        )
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                pin.name,
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
                color = SfColors.OnSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                if (pin.entries >= 0) {
                    L10n.t(R.string.s_5a77a502c2, (pin.entries), (relativeTimeOf(pin.lastScanMs)))
                } else {
                    L10n.t(R.string.s_46893a685e)
                },
                fontSize = 11.sp,
                color = SfColors.OnSurfaceVariant,
            )
        }
        CompactIconButton(Icons.Outlined.Delete, L10n.t(R.string.s_a5cbbabd1e), tint = SfColors.Error, onClick = onRemove)
    }
}

private fun relativeTimeOf(ms: Long): String {
    if (ms <= 0) return L10n.t(R.string.s_53b9e4c112)
    val t = Instant.ofEpochMilli(ms).atZone(ZoneId.systemDefault())
    return DateTimeFormatter.ofPattern("MM-dd HH:mm").format(t) + L10n.t(R.string.s_5350d06277)
}
