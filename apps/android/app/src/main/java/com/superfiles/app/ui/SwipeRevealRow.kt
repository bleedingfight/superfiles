package com.superfiles.app.ui

import com.superfiles.app.L10n
import com.superfiles.app.R

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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

/**
 * 列表行的「左滑露出操作」容器：向左拖动后行内容平移，右侧露出「取消 / 删除」两个按钮。
 *
 * - 拖动超过一半自动吸附到展开态，否则回弹；
 * - 展开后点「取消」收起，点「删除」执行 [onDelete]（调用方负责是否再弹确认）；
 * - 只有水平拖动才拦截手势，纵向滚动不受影响。
 *
 * 行内容自带白底，保证收起时不会透出背后的操作条。
 */
@Composable
fun SwipeRevealRow(
    onDelete: () -> Unit,
    modifier: Modifier = Modifier,
    contentPadding: PaddingValues = PaddingValues(0.dp),
    backgroundColor: Color = SfColors.SurfaceCard,
    deleteLabel: String = L10n.t(R.string.s_2f4aaddde3),
    cancelLabel: String = L10n.t(R.string.s_625fb26b4b),
    enabled: Boolean = true,
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
