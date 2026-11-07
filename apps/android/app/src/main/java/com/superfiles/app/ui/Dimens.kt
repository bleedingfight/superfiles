package com.superfiles.app.ui

import androidx.compose.ui.unit.dp

/**
 * 间距刻度（4 基栅）与组件固定尺寸。规则见 docs/06-design-system.md §2——
 * 只允许取以下值，改这里时同步改 iOS 的 Spacing.swift。
 */
object Dimens {
    val Space1 = 4.dp
    val Space2 = 8.dp
    val Space3 = 12.dp
    val Space4 = 16.dp
    val Space6 = 24.dp
    val Space8 = 32.dp

    /** FileRow 图标槽宽度 */
    val RowIconSlot = 28.dp
}
