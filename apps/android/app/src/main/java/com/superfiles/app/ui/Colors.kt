package com.superfiles.app.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.graphics.Color

/**
 * Figma「superfiles」稿实测基线。design/tokens.json 是唯一机器可读真相源
 * （docs/06 §1），本文件是 Android 侧的静态实现；改这里必须先改 tokens.json。
 * minSdk 26 低于动态取色门槛（31），当前直接用基线色。
 */
class SfPalette(
    val surface: Color,
    val surfaceCard: Color,
    val surfaceTint: Color,
    val primary: Color,
    val primaryWarm: Color,
    val success: Color,
    val onSurface: Color,
    val onSurfaceVariant: Color,
    val outline: Color,
    val error: Color,
    // 首页稿实测扩展值（浅色）/ 派生值（深色）
    val searchFieldBg: Color,
    val avatarBg: Color,
    val usageDeep: Color,
    val usageTrack: Color,
    val usageSegDocs: Color,
    val usageSegOther: Color,
    // 文件类型扩展名块（bg/fg 成对；fg 与 docs/05 图标特化色同族）
    val pdfBadgeBg: Color,
    val pdfBadgeFg: Color,
    val sheetBadgeBg: Color, // fg 用 success
    val docBadgeBg: Color, // fg 用 primary
)

/** 浅色 = tokens.json color.role 实测基线。 */
val SfLightPalette = SfPalette(
    surface = Color(0xFFF8F7F4),
    surfaceCard = Color(0xFFFFFFFF),
    surfaceTint = Color(0xFFEAF0F8),
    primary = Color(0xFF466DA6),
    primaryWarm = Color(0xFFA18460),
    success = Color(0xFF6F8D7D),
    onSurface = Color(0xFF292E35),
    onSurfaceVariant = Color(0xFF777D86),
    outline = Color(0xFFA4A8AE),
    error = Color(0xFFB3261E),
    searchFieldBg = Color(0xFFF0EFEB),
    avatarBg = Color(0xFFF0EBE3),
    usageDeep = Color(0xFF304D76),
    usageTrack = Color(0xFFD8E1ED),
    usageSegDocs = Color(0xFF8CA6C8),
    usageSegOther = Color(0xFFB4C0CF),
    pdfBadgeBg = Color(0xFFF6ECE8),
    pdfBadgeFg = Color(0xFFB7796E),
    sheetBadgeBg = Color(0xFFEDF2ED),
    docBadgeBg = Color(0xFFEAF0F8),
)

/**
 * 深色 = tokens.json "dark" 段（v0.2 派生草案）：同一语义角色从浅色基线
 * 反相/调明度得到——主要操作色提亮（蓝/暖棕/绿），层级面压暗并保留暖调。
 * 待设计师在 Figma 出正式深色稿后校准。
 */
val SfDarkPalette = SfPalette(
    surface = Color(0xFF1A1916),
    surfaceCard = Color(0xFF26231F),
    surfaceTint = Color(0xFF22324A),
    primary = Color(0xFFA9C3E6),
    primaryWarm = Color(0xFFC7A87F),
    success = Color(0xFF9CB8A9),
    onSurface = Color(0xFFE7E5E1),
    onSurfaceVariant = Color(0xFFA0A5AD),
    outline = Color(0xFF6A7078),
    error = Color(0xFFF2B8B5),
    searchFieldBg = Color(0xFF26231F),
    avatarBg = Color(0xFF33291F),
    usageDeep = Color(0xFFD3E2F4),
    usageTrack = Color(0xFF3B4148),
    usageSegDocs = Color(0xFF7E98B9),
    usageSegOther = Color(0xFF8E939A),
    pdfBadgeBg = Color(0xFF3B2925),
    pdfBadgeFg = Color(0xFFD9A198),
    sheetBadgeBg = Color(0xFF26332A),
    docBadgeBg = Color(0xFF22324A),
)

// 非 static：Manifest 已配置 uiMode 自处理，主题切换不重建 Activity，需要随流重组。
val LocalSfPalette = compositionLocalOf { SfLightPalette }

/**
 * 组件统一入口（保持 `SfColors.Primary` 调用形态不变）：读取当前色板。
 * 顶层非组合上下文（如 Theme.kt 的 colorScheme 常量）请直接用 SfLightPalette/SfDarkPalette。
 */
object SfColors {
    val Surface: Color @Composable @ReadOnlyComposable get() = LocalSfPalette.current.surface
    val SurfaceCard: Color @Composable @ReadOnlyComposable get() = LocalSfPalette.current.surfaceCard
    val SurfaceTint: Color @Composable @ReadOnlyComposable get() = LocalSfPalette.current.surfaceTint
    val Primary: Color @Composable @ReadOnlyComposable get() = LocalSfPalette.current.primary
    val PrimaryWarm: Color @Composable @ReadOnlyComposable get() = LocalSfPalette.current.primaryWarm
    val Success: Color @Composable @ReadOnlyComposable get() = LocalSfPalette.current.success
    val OnSurface: Color @Composable @ReadOnlyComposable get() = LocalSfPalette.current.onSurface
    val OnSurfaceVariant: Color @Composable @ReadOnlyComposable get() = LocalSfPalette.current.onSurfaceVariant
    val Outline: Color @Composable @ReadOnlyComposable get() = LocalSfPalette.current.outline
    val Error: Color @Composable @ReadOnlyComposable get() = LocalSfPalette.current.error
    val SearchFieldBg: Color @Composable @ReadOnlyComposable get() = LocalSfPalette.current.searchFieldBg
    val AvatarBg: Color @Composable @ReadOnlyComposable get() = LocalSfPalette.current.avatarBg
    val UsageDeep: Color @Composable @ReadOnlyComposable get() = LocalSfPalette.current.usageDeep
    val UsageTrack: Color @Composable @ReadOnlyComposable get() = LocalSfPalette.current.usageTrack
    val UsageSegDocs: Color @Composable @ReadOnlyComposable get() = LocalSfPalette.current.usageSegDocs
    val UsageSegOther: Color @Composable @ReadOnlyComposable get() = LocalSfPalette.current.usageSegOther
    val PdfBadgeBg: Color @Composable @ReadOnlyComposable get() = LocalSfPalette.current.pdfBadgeBg
    val PdfBadgeFg: Color @Composable @ReadOnlyComposable get() = LocalSfPalette.current.pdfBadgeFg
    val SheetBadgeBg: Color @Composable @ReadOnlyComposable get() = LocalSfPalette.current.sheetBadgeBg
    val DocBadgeBg: Color @Composable @ReadOnlyComposable get() = LocalSfPalette.current.docBadgeBg
}
