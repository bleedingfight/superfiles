package com.superfiles.app.ui

import com.superfiles.app.L10n
import com.superfiles.app.R

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * 搜索框视觉单源（Figma 稿：`#F0EFEB` 底、r=14、46dp 高、13px 占位）。
 * 两种形态共用同一外观：
 *  - [SearchEntryBar]  只读入口（首页）——点击跳到带输入框的页面；
 *  - [SearchFieldBar]  可输入（文件页/筛选页），作用域由调用方决定：
 *                      首页 = 全盘搜索；类型筛选页 = 该类型内搜索。
 */
private val SearchFieldHeight = 46.dp

@Composable
fun SearchEntryBar(placeholder: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Surface(
        onClick = onClick,
        modifier = modifier.fillMaxWidth().heightIn(min = SearchFieldHeight),
        shape = RoundedCornerShape(Dimens.RadiusM),
        color = SfColors.SearchFieldBg,
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = Dimens.Space4),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Dimens.Space3),
        ) {
            Icon(Icons.Outlined.Search, contentDescription = null, tint = SfColors.OnSurfaceVariant)
            Text(placeholder, fontSize = 13.sp, color = SfColors.Outline)
        }
    }
}

/** 与搜索框同款外观的通用输入（新建文件夹/重命名等表单用它，保持视觉语言一致）。 */
@Composable
fun SfInputField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    modifier: Modifier = Modifier,
    onDone: (() -> Unit)? = null,
    keyboardType: KeyboardType = KeyboardType.Text,
    isPassword: Boolean = false,
) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = SearchFieldHeight)
            .clip(RoundedCornerShape(Dimens.RadiusM))
            .background(SfColors.SearchFieldBg),
        contentAlignment = Alignment.CenterStart,
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = Dimens.Space4),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            BasicTextField(
                value = value,
                onValueChange = onValueChange,
                singleLine = true,
                textStyle = TextStyle(fontSize = 14.sp, color = SfColors.OnSurface),
                cursorBrush = SolidColor(SfColors.Primary),
                keyboardOptions = KeyboardOptions(keyboardType = keyboardType, imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { onDone?.invoke() }),
                visualTransformation = if (isPassword) {
                    PasswordVisualTransformation()
                } else {
                    VisualTransformation.None
                },
                modifier = Modifier.weight(1f),
                decorationBox = { inner ->
                    Box {
                        if (value.isEmpty()) {
                            Text(placeholder, fontSize = 13.sp, color = SfColors.Outline)
                        }
                        inner()
                    }
                },
            )
        }
    }
}

@Composable
fun SearchFieldBar(
    query: String,
    onQueryChange: (String) -> Unit,
    placeholder: String,
    modifier: Modifier = Modifier,
    focusRequester: FocusRequester? = null,
) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = SearchFieldHeight)
            .clip(RoundedCornerShape(Dimens.RadiusM))
            .background(SfColors.SearchFieldBg),
        contentAlignment = Alignment.CenterStart,
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = Dimens.Space4),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Dimens.Space3),
        ) {
            Icon(Icons.Outlined.Search, contentDescription = null, tint = SfColors.OnSurfaceVariant)
            BasicTextField(
                value = query,
                onValueChange = onQueryChange,
                singleLine = true,
                textStyle = TextStyle(fontSize = 14.sp, color = SfColors.OnSurface),
                cursorBrush = SolidColor(SfColors.Primary),
                modifier = if (focusRequester != null) {
                    Modifier.weight(1f).focusRequester(focusRequester)
                } else {
                    Modifier.weight(1f)
                },
                decorationBox = { inner ->
                    Box {
                        if (query.isEmpty()) {
                            Text(placeholder, fontSize = 13.sp, color = SfColors.Outline)
                        }
                        inner()
                    }
                },
            )
            if (query.isNotEmpty()) {
                IconButton(onClick = { onQueryChange("") }, modifier = Modifier.size(Dimens.Space6)) {
                    Icon(
                        Icons.Outlined.Close,
                        contentDescription = L10n.t(R.string.s_0fb6472243),
                        modifier = Modifier.size(Dimens.Space4),
                        tint = SfColors.Outline,
                    )
                }
            }
        }
    }
}
