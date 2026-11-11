package com.superfiles.app.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.unit.dp

/**
 * 自适应布局合同（docs/06 §7）。
 *
 * 断点只看窗口宽度，横屏/折叠屏不单独判定：
 * - Compact（< 600dp）：手机竖屏，沿用 Figma 单列稿；
 * - Medium / Expanded（≥ 600dp）：横屏手机、平板、折叠展开，改双列并把导航竖起来。
 *
 * 同时提供一个「矮窗」判据（height < 480dp）：横屏手机高度极窄，
 * 底部导航会吃掉 ~20% 的可用高度，必须换成侧栏。
 */
object Adaptive {
    /** Medium 断点：600dp（Material 3 window size class）。 */
    const val MEDIUM_WIDTH_DP = 600

    /** Expanded 断点：840dp。 */
    const val EXPANDED_WIDTH_DP = 840

    /** 矮窗断点：低于这个高度时底部导航会明显挤压内容。 */
    const val SHORT_HEIGHT_DP = 480

    /** 首页单列可读宽度（与 Figma 稿一致，平板居中不拉伸）。 */
    val HomeColumnMaxWidth = 480.dp

    /** 列表可读宽度：超过后一行两端距离过远，居中限宽。 */
    val ListMaxWidth = 840.dp

    /** 首页双列总宽（480 × 2 + 24 列间距），再宽也不拉伸。 */
    val HomeWideMaxWidth = 984.dp

    /** 详情页单列可读宽度（窄窗/竖屏）。 */
    val DetailsSingleMaxWidth = 640.dp

    /** 详情页双列总宽（横屏/平板：左预览 + 右信息）。 */
    val DetailsWideMaxWidth = 1040.dp

    /** 对话框宽度上限：横屏/平板上不被拉成一整屏宽。 */
    val DialogMaxWidth = 560.dp
}

/** 当前窗口是否走宽屏布局（横屏手机 / 平板 / 折叠展开）。 */
@Composable
@ReadOnlyComposable
fun isWideLayout(): Boolean =
    LocalConfiguration.current.screenWidthDp >= Adaptive.MEDIUM_WIDTH_DP

/** 是否够宽到放「列表 + 预览」双栏（平板横屏 / 折叠展开）。 */
@Composable
@ReadOnlyComposable
fun isExpandedLayout(): Boolean =
    LocalConfiguration.current.screenWidthDp >= Adaptive.EXPANDED_WIDTH_DP

/**
 * 是否把底部导航换成侧栏：
 * 矮窗（横屏手机）或 Expanded（平板横屏 / 折叠展开）。
 * 平板竖屏（例如 800 × 1280）仍保留底部导航。
 */
@Composable
@ReadOnlyComposable
fun useNavigationRail(): Boolean {
    val config = LocalConfiguration.current
    return config.screenHeightDp < Adaptive.SHORT_HEIGHT_DP ||
        config.screenWidthDp >= Adaptive.EXPANDED_WIDTH_DP
}
