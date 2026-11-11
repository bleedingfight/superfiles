package com.superfiles.app.ui

import com.superfiles.app.L10n
import com.superfiles.app.R

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties

/**
 * 品牌风对话框容器（docs/06 §2.6）：与首页同源的暖底 + RadiusL 圆角 +
 * 17w700 标题；正文/按钮统一间距与字号，避免各页面各自用 Material 默认
 * AlertDialog 造成「一会白底、一会紫按钮」的割裂感。
 *
 * 所有弹窗都应走这里（含确认框、表单、选择器、进度框）。
 */
@Composable
fun SfDialog(
    onDismissRequest: () -> Unit,
    title: String? = null,
    modifier: Modifier = Modifier,
    showCloseButton: Boolean = false,
    dismissOnBackPress: Boolean = true,
    dismissOnClickOutside: Boolean = true,
    actions: (@Composable RowScope.() -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    Dialog(
        onDismissRequest = onDismissRequest,
        properties = DialogProperties(
            dismissOnBackPress = dismissOnBackPress,
            dismissOnClickOutside = dismissOnClickOutside,
        ),
    ) {
        Surface(
            // 横屏/平板上限宽（docs/06 §7）：弹窗不跟着窗口拉成一整屏
            modifier = modifier.widthIn(max = Adaptive.DialogMaxWidth),
            shape = RoundedCornerShape(Dimens.RadiusL),
            color = SfColors.Surface,
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(Dimens.Space6),
            ) {
                if (title != null) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            title,
                            fontSize = 17.sp,
                            fontWeight = FontWeight.Bold,
                            color = SfColors.OnSurface,
                            modifier = Modifier.weight(1f),
                        )
                        if (showCloseButton) {
                            CompactIconButton(Icons.Filled.Close, L10n.t(R.string.s_b15d91274e), onClick = onDismissRequest)
                        }
                    }
                    Spacer(Modifier.height(Dimens.Space4))
                }
                content()
                if (actions != null) {
                    Spacer(Modifier.height(Dimens.Space4))
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(Dimens.Space2, Alignment.End),
                        verticalAlignment = Alignment.CenterVertically,
                        content = actions,
                    )
                }
            }
        }
    }
}

/** 弹窗正文的浅色信息卡（危险说明、路径、提示等），与首页分组卡同语言。 */
@Composable
fun SfDialogMessage(text: String) {
    Surface(
        shape = RoundedCornerShape(Dimens.RadiusM),
        color = SfColors.SearchFieldBg,
    ) {
        androidx.compose.foundation.text.selection.SelectionContainer {
            Text(
                text,
                fontSize = 13.sp,
                color = SfColors.OnSurface,
                modifier = Modifier.padding(Dimens.Space3),
            )
        }
    }
}

/** 弹窗主操作：实心品牌蓝 + 白字（与首页主按钮一致）。 */
@Composable
fun PrimaryConfirmButton(
    label: String,
    enabled: Boolean = true,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    Button(
        onClick = onClick,
        enabled = enabled,
        modifier = modifier,
        shape = RoundedCornerShape(Dimens.RadiusS),
        colors = ButtonDefaults.buttonColors(
            containerColor = SfColors.Primary,
            contentColor = Color.White,
            disabledContainerColor = SfColors.Outline.copy(alpha = 0.35f),
            disabledContentColor = Color.White.copy(alpha = 0.7f),
        ),
        contentPadding = PaddingValues(horizontal = 18.dp, vertical = 6.dp),
    ) {
        Text(label, fontSize = 13.sp, fontWeight = FontWeight.Medium)
    }
}
