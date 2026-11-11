package com.superfiles.app.ui

import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned

/**
 * 滑动多选命中测试：记录每一行在窗口坐标系里的矩形，拖动时按手指位置找到对应行。
 *
 * 之所以用窗口坐标而不是列表局部坐标：拖拽手势挂在单行上，手指移出该行后
 * `change.position` 仍是相对起手行，必须换算回窗口坐标才能命中其它行。
 */
class DragSelectTracker {
    private val bounds = HashMap<String, Rect>()

    fun update(id: String, rect: Rect) {
        bounds[id] = rect
    }

    fun remove(id: String) {
        bounds.remove(id)
    }

    fun topLeftOf(id: String): Offset? = bounds[id]?.topLeft

    fun hit(position: Offset): String? =
        bounds.entries.firstOrNull { it.value.contains(position) }?.key
}

/**
 * 让一行支持「长按后拖动」多选。手势常驻：普通滚动/点击不受影响，
 * 只有长按之后才开始拦截拖动，因此可以「长按第一项 → 不松手继续滑」。
 */
internal fun Modifier.dragSelectable(
    id: String,
    tracker: DragSelectTracker,
    onSelect: (String) -> Unit,
): Modifier = this
    .onGloballyPositioned { coordinates ->
        tracker.update(id, coordinates.boundsInWindow())
    }
    .pointerInput(id) {
        detectDragGesturesAfterLongPress(
            onDragStart = { onSelect(id) },
            onDrag = { change, _ ->
                change.consume()
                val origin = tracker.topLeftOf(id) ?: Offset.Zero
                tracker.hit(origin + change.position)?.let(onSelect)
            },
        )
    }
