package com.superfiles.app.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import com.superfiles.app.L10n

/** 浅色 = Figma 基线（SfLightPalette；docs/06 §1 语义角色同义使用）。 */
private val LightColors = lightColorScheme(
    primary = SfLightPalette.primary,
    onPrimary = Color.White,
    surface = SfLightPalette.surface,
    background = SfLightPalette.surface,
    onSurface = SfLightPalette.onSurface,
    surfaceVariant = SfLightPalette.surfaceTint,
    secondaryContainer = SfLightPalette.surfaceTint,
    onSurfaceVariant = SfLightPalette.onSurfaceVariant,
    outline = SfLightPalette.outline,
    error = SfLightPalette.error,
)

/** 深色 = tokens.json "dark" 段（v0.2 派生草案，SfDarkPalette）。 */
private val DarkColors = darkColorScheme(
    primary = SfDarkPalette.primary,
    onPrimary = Color(0xFF14253C),
    surface = SfDarkPalette.surface,
    background = SfDarkPalette.surface,
    onSurface = SfDarkPalette.onSurface,
    surfaceVariant = SfDarkPalette.surfaceTint,
    secondaryContainer = SfDarkPalette.surfaceTint,
    onSurfaceVariant = SfDarkPalette.onSurfaceVariant,
    outline = SfDarkPalette.outline,
    error = SfDarkPalette.error,
)

@Composable
fun SuperFilesTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    // 运行时由 Application 初始化；这里兜底 Compose Preview（没有 Application.onCreate）。
    val context = LocalContext.current
    remember(context) { L10n.init(context); Unit }
    CompositionLocalProvider(
        LocalSfPalette provides if (darkTheme) SfDarkPalette else SfLightPalette,
    ) {
        MaterialTheme(
            colorScheme = if (darkTheme) DarkColors else LightColors,
            content = content,
        )
    }
}
