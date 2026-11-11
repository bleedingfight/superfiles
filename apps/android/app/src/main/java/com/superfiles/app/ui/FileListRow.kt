package com.superfiles.app.ui

import com.superfiles.app.L10n
import com.superfiles.app.R

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.superfiles.core.Entry
import com.superfiles.core.EntryKind

/**
 * Figma FileRow 合同（docs/06 §2）：行高 74（下限）、名称 14w500 + 元信息 11、
 * 图标槽 46×50 r=10 的「类型徽章」——PDF/XLS/DOC 特化色为 Figma 首页稿实测，
 * 目录用暖米+暖棕，其余文件中性兜底（SurfaceTint/OnSurfaceVariant）。
 *
 * 首页「最近打开」、「文件」浏览页、类型筛选页、搜索结果共用这一个组件，
 * 保证全 App 文件列表一致。样式简表见 docs/05-icons.md 颜色策略节。
 */

/** 徽章视图参数（ext=null 时只画图标）。 */
data class FileBadge(
    val icon: ImageVector,
    val bg: Color,
    val fg: Color,
    val ext: String?,
)

private val RowHeight = 74.dp
private val BadgeWidth = 46.dp
private val BadgeHeight = 50.dp

@Composable
fun FileBadgeView(badge: FileBadge) {
    Column(
        modifier = Modifier
            .width(BadgeWidth)
            .height(BadgeHeight)
            .clip(RoundedCornerShape(Dimens.RadiusS))
            .background(badge.bg),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(badge.icon, contentDescription = null, tint = badge.fg)
        badge.ext?.let { Text(it, fontSize = 8.sp, fontWeight = FontWeight.SemiBold, color = badge.fg) }
    }
}

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun FileListRow(
    badge: FileBadge,
    name: String,
    meta: String,
    modifier: Modifier = Modifier,
    selected: Boolean = false,
    onClick: (() -> Unit)? = null,
    onLongClick: (() -> Unit)? = null,
    leading: @Composable () -> Unit = {},
    trailing: @Composable () -> Unit = {},
) {
    val clickModifier = when {
        onLongClick != null -> Modifier.combinedClickable(
            onClick = { onClick?.invoke() },
            onLongClick = onLongClick,
        )
        onClick != null -> Modifier.clickable(onClick = onClick)
        else -> Modifier
    }
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = RowHeight) // 74 为合同下限，字体放大时自适应
            .clip(RoundedCornerShape(Dimens.RadiusS))
            .background(if (selected) SfColors.SurfaceTint else Color.Transparent)
            .then(clickModifier),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Dimens.Space3),
    ) {
        leading()
        FileBadgeView(badge)
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(Dimens.Space1),
        ) {
            Text(
                name,
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
                color = SfColors.OnSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(meta, fontSize = 11.sp, color = SfColors.OnSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        trailing()
    }
}

/** Entry → 徽章（docs/05 fallback 链 + Figma 实测色对）。 */
@Composable
fun fileBadgeOf(entry: Entry): FileBadge {
    if (entry.kind == EntryKind.DIRECTORY) {
        return FileBadge(FileIcon.of(entry), SfColors.AvatarBg, SfColors.PrimaryWarm, null)
    }
    val ext = entry.name.substringAfterLast('.', "").lowercase()
    val (bg, fg) = when (ext) {
        "pdf" -> SfColors.PdfBadgeBg to SfColors.PdfBadgeFg
        "xls", "xlsx", "csv" -> SfColors.SheetBadgeBg to SfColors.Success
        "doc", "docx", "txt", "md" -> SfColors.DocBadgeBg to SfColors.Primary
        else -> SfColors.SurfaceTint to SfColors.OnSurfaceVariant
    }
    return FileBadge(
        FileIcon.of(entry),
        bg,
        fg,
        ext.uppercase().take(4).takeIf { it.isNotEmpty() },
    )
}

/** 多选态左侧圆形勾选按钮：未选空心描边，选中实心品牌蓝 + 白勾。 */
@Composable
fun SelectionCircle(selected: Boolean) {
    Box(
        modifier = Modifier
            .size(22.dp)
            .clip(CircleShape)
            .background(if (selected) SfColors.Primary else Color.Transparent)
            .border(
                width = 1.5.dp,
                color = if (selected) SfColors.Primary else SfColors.Outline,
                shape = CircleShape,
            )
            .semantics { contentDescription = if (selected) L10n.t(R.string.s_543b044d8a) else L10n.t(R.string.s_7d32bb7888) },
        contentAlignment = Alignment.Center,
    ) {
        if (selected) {
            Icon(
                Icons.Outlined.Check,
                contentDescription = null,
                modifier = Modifier.size(14.dp),
                tint = Color.White,
            )
        }
    }
}

// ---- 方案 A：分组卡列表容器（docs/06 §2.6）----

/** 分组白卡：卡内行保持平铺（[FileListRow] 74dp），只靠行间发丝线分区。 */
@Composable
fun ListSectionCard(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(Dimens.RadiusM),
        color = SfColors.SurfaceCard,
    ) {
        Column(modifier = Modifier.fillMaxWidth(), content = content)
    }
}

/** 行间发丝线：起始缩进对齐 FileListRow 文本列（Space4 内边距 + 46 徽章 + Space3 间距）。 */
@Composable
fun RowDivider(start: Dp = 74.dp) {
    HorizontalDivider(
        modifier = Modifier.padding(start = start),
        thickness = 0.5.dp,
        color = SfColors.Outline.copy(alpha = 0.35f),
    )
}

/**
 * 长列表的「滚动卡片」行容器：同一张白卡的行连续排列，只有首/末行带圆角，
 * 中间行直角——滚动时视觉上始终是一张卡，列表短时卡片自然收在最后一行，
 * 不会像固定高度的面板那样留出大片空白。
 *
 * 用法：`ListGroupItem(first, last) { FileListRow(modifier = padding(horizontal = Space4)); RowDivider() }`
 */
@Composable
fun ListGroupItem(
    first: Boolean,
    last: Boolean,
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    val r = Dimens.RadiusM
    val shape = when {
        first && last -> RoundedCornerShape(r)
        first -> RoundedCornerShape(topStart = r, topEnd = r)
        last -> RoundedCornerShape(bottomStart = r, bottomEnd = r)
        else -> RectangleShape
    }
    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(shape)
            .background(SfColors.SurfaceCard),
        content = content,
    )
}

/**
 * 品牌进度条：6dp 圆角轨道 + 主色进度。
 * 不用 M3 [androidx.compose.material3.LinearProgressIndicator]，因为 1.3 默认带
 * 缺口 + 尾部停靠点，和设计系统里的「实心圆角条」不一致。
 */
@Composable
fun SfProgressBar(
    fraction: Float,
    modifier: Modifier = Modifier,
    height: Dp = 6.dp,
) {
    val shape = RoundedCornerShape(height / 2)
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(height)
            .clip(shape)
            .background(SfColors.UsageTrack),
    ) {
        Box(
            modifier = Modifier
                .fillMaxHeight()
                .fillMaxWidth(fraction.coerceIn(0f, 1f))
                .clip(shape)
                .background(SfColors.Primary),
        )
    }
}
