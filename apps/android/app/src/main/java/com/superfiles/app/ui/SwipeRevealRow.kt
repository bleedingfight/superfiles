package com.superfiles.app.ui

import com.superfiles.app.L10n
import com.superfiles.app.R

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

/* 列表行的「左滑露出操作」容器：向左拖动后行内容平移，右侧露出「取消 / 删除」两个按钮。
 *
 * - 拖动超过一半自动吸附到展开态，否则回弹；
 * - 展开后点「取消」收起，点「删除」执行 [onDelete]（调用方负责是否再弹确认）；
 * - 只有水平拖动才拦截手势，纵向滚动不受影响。
 * - [onLongClick] 非空时行内容支持长按菜单，且「展开态点内容」也收起；
 *   为空则与旧行为完全一致（既有调用点零变化）。
 *
 * 行内容自带白底，保证收起时不会透出背后的操作条。
 */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun SwipeRevealRow(
    onDelete: () -> Unit,
    modifier: Modifier = Modifier,
    contentPadding: PaddingValues = PaddingValues(0.dp),
    backgroundColor: Color = SfColors.SurfaceCard,
    deleteLabel: String = L10n.t(R.string.s_2f4aaddde3),
    cancelLabel: String = L10n.t(R.string.s_625fb26b4b),
    enabled: Boolean = true,
    onLongClick: (() -> Unit)? = null,
    content: @Composable () -> Unit,
) {
    if (!enabled) {
        Box(modifier = modifier.fillMaxWidth().background(backgroundColor)) {
            Box(Modifier.padding(contentPadding)) { content() }
        }
        return
    }

    val actionWidth = 64.dp
    val actionsWidth = actionWidth * 2
    val revealPx = with(LocalDensity.current) { actionsWidth.toPx() }
    val offset = remember { Animatable(0f) }
    val scope = rememberCoroutineScope()
    val contentInteraction =
        remember { androidx.compose.foundation.interaction.MutableInteractionSource() }

    fun close() = scope.launch { offset.animateTo(0f, tween(180)) }

    Box(modifier = modifier.fillMaxWidth().clipToBounds()) {
        // 右侧操作条（在行内容下层，内容左移后露出）
        Row(
            modifier = Modifier.matchParentSize(),
            horizontalArrangement = Arrangement.End,
        ) {
            SwipeActionButton(
                label = cancelLabel,
                icon = null,
                container = SfColors.SearchFieldBg,
                contentColor = SfColors.OnSurfaceVariant,
                width = actionWidth,
                onClick = { close() },
            )
            SwipeActionButton(
                label = deleteLabel,
                icon = Icons.Outlined.Delete,
                container = SfColors.Error,
                contentColor = Color.White,
                width = actionWidth,
                onClick = onDelete,
            )
        }
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .offset { IntOffset(offset.value.roundToInt(), 0) }
                .background(backgroundColor)
                .then(
                    if (onLongClick != null) {
                        // 长按需求成立时：展开态点内容收起；长按交给菜单
                        Modifier.combinedClickable(
                            interactionSource = contentInteraction,
                            indication = null,
                            onClick = { if (offset.value < 0f) close() },
                            onLongClick = onLongClick,
                        )
                    } else {
                        Modifier
                    }
                )
                .pointerInput(revealPx) {
                    detectHorizontalDragGestures(
                        onHorizontalDrag = { change, dragAmount ->
                            change.consume()
                            scope.launch {
                                offset.snapTo((offset.value + dragAmount).coerceIn(-revealPx, 0f))
                            }
                        },
                        onDragEnd = {
                            val target = if (offset.value <= -revealPx / 2f) -revealPx else 0f
                            scope.launch { offset.animateTo(target, tween(180)) }
                        },
                        onDragCancel = {
                            scope.launch { offset.animateTo(0f, tween(180)) }
                        },
                    )
                },
        ) {
            Box(Modifier.padding(contentPadding)) { content() }
        }
    }
}

/** 左滑操作条里的单个操作（文案/图标/颜色/回调全由调用方定义）。 */
data class SwipeAction(
    val label: String,
    val icon: ImageVector? = null,
    val container: Color,
    val contentColor: Color,
    val onClick: () -> Unit,
)

/**
 * 多操作版「左滑露出」：露出条上的**每个**按钮都是真实操作（区别于
 * SwipeRevealRow 的「灰色收起 + 红色删除」。进行中的传输行用它露出
 * 「暂停/继续 + 取消」。
 *
 * - 拖动超过一半吸附展开，右拖/回弹收起；展开态点行内容收起；
 * - 点任意操作按钮：先收起再执行（操作后行状态会刷新，不让露出条悬挂）；
 * - [onLongClick] 供长按弹删除菜单（设计合同：记录删除走长按）。
 */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun SwipeActionsRow(
    actions: List<SwipeAction>,
    modifier: Modifier = Modifier,
    backgroundColor: Color = SfColors.SurfaceCard,
    enabled: Boolean = true,
    onLongClick: (() -> Unit)? = null,
    content: @Composable () -> Unit,
) {
    if (actions.isEmpty() || !enabled) {
        Box(modifier = modifier.fillMaxWidth().background(backgroundColor)) { content() }
        return
    }

    val actionWidth = 64.dp
    val revealPx = with(LocalDensity.current) { (actionWidth * actions.size).toPx() }
    val offset = remember { Animatable(0f) }
    val scope = rememberCoroutineScope()
    val contentInteraction =
        remember { androidx.compose.foundation.interaction.MutableInteractionSource() }

    fun close() = scope.launch { offset.animateTo(0f, tween(180)) }

    Box(modifier = modifier.fillMaxWidth().clipToBounds()) {
        Row(
            modifier = Modifier.matchParentSize(),
            horizontalArrangement = Arrangement.End,
        ) {
            actions.forEach { action ->
                SwipeActionButton(
                    label = action.label,
                    icon = action.icon,
                    container = action.container,
                    contentColor = action.contentColor,
                    width = actionWidth,
                    onClick = {
                        close()
                        action.onClick()
                    },
                )
            }
        }
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .offset { IntOffset(offset.value.roundToInt(), 0) }
                .background(backgroundColor)
                .combinedClickable(
                    interactionSource = contentInteraction,
                    indication = null,
                    onClick = { if (offset.value < 0f) close() },
                    onLongClick = onLongClick,
                )
                .pointerInput(revealPx) {
                    detectHorizontalDragGestures(
                        onHorizontalDrag = { change, dragAmount ->
                            change.consume()
                            scope.launch {
                                offset.snapTo((offset.value + dragAmount).coerceIn(-revealPx, 0f))
                            }
                        },
                        onDragEnd = {
                            val target = if (offset.value <= -revealPx / 2f) -revealPx else 0f
                            scope.launch { offset.animateTo(target, tween(180)) }
                        },
                        onDragCancel = {
                            scope.launch { offset.animateTo(0f, tween(180)) }
                        },
                    )
                },
        ) {
            content()
        }
    }
}

@Composable
private fun SwipeActionButton(
    label: String,
    icon: ImageVector?,
    container: Color,
    contentColor: Color,
    width: Dp,
    onClick: () -> Unit,
) {
    Column(
        modifier = Modifier
            .width(width)
            .fillMaxHeight()
            .background(container)
            .clickable(onClick = onClick),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        if (icon != null) {
            Icon(icon, contentDescription = null, tint = contentColor)
        }
        Text(
            label,
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium,
            color = contentColor,
        )
    }
}
