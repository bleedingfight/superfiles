package com.superfiles.app.ui

import com.superfiles.app.L10n
import com.superfiles.app.R

import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.os.StatFs
import android.provider.Settings
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.PhoneAndroid
import androidx.compose.material.icons.outlined.Shield
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * 「存储管理」面板（首页用量卡「管理」入口）：列出当前机器上可访问的存储位置。
 * M0 阶段只有应用沙盒可直接浏览；共享存储需要「所有文件访问」授权（浏览接入随 M2 SAF）。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StorageSheet(onDismiss: () -> Unit, onOpenFiles: () -> Unit, onOpenShared: () -> Unit) {
    val context = LocalContext.current
    val allowed = remember { Environment.isExternalStorageManager() }
    val dataStat = remember { runCatching { StatFs(Environment.getDataDirectory().absolutePath) }.getOrNull() }
    val external = Environment.getExternalStorageDirectory()
    val externalStat = remember { runCatching { StatFs(external.absolutePath) }.getOrNull() }

    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = SfColors.Surface) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(bottom = Dimens.Space6),
            verticalArrangement = Arrangement.spacedBy(Dimens.Space2),
        ) {
            Text(
                L10n.t(R.string.s_1d77fa8c1f),
                fontSize = 17.sp,
                fontWeight = FontWeight.Bold,
                color = SfColors.OnSurface,
                modifier = Modifier.padding(horizontal = Dimens.Space6, vertical = Dimens.Space2),
            )
            StorageLocationRow(
                icon = Icons.Outlined.PhoneAndroid,
                title = L10n.t(R.string.s_99f7a465ec),
                subtitle = L10n.t(R.string.s_351285aefe),
                meta = dataStat?.let { stat ->
                    L10n.t(R.string.s_c63484879a, (formatSize(stat.totalBytes - stat.availableBytes)), (formatSize(stat.totalBytes)))
                } ?: "",
                action = L10n.t(R.string.s_9c5c5cdbc5),
                onClick = { onOpenFiles(); onDismiss() },
            )
            HorizontalDivider(modifier = Modifier.padding(horizontal = Dimens.Space6))
            StorageLocationRow(
                icon = Icons.Outlined.Folder,
                title = L10n.t(R.string.s_0d81676d53),
                subtitle = external.absolutePath,
                meta = buildString {
                    externalStat?.let { stat ->
                        append(L10n.t(R.string.s_c63484879a, (formatSize(stat.totalBytes - stat.availableBytes)), (formatSize(stat.totalBytes))))
                    }
                    append(if (allowed) L10n.t(R.string.s_ee316034c4) else L10n.t(R.string.s_3f8d4105ae))
                },
                action = if (allowed) L10n.t(R.string.s_9c5c5cdbc5) else L10n.t(R.string.s_4a1c90d86b),
                onClick = {
                    if (allowed) {
                        onOpenShared()
                        onDismiss()
                    } else {
                        // 跳系统「所有文件访问」设置页（Android 11+）
                        val intent = Intent(
                            Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                            Uri.parse("package:${context.packageName}"),
                        )
                        runCatching { context.startActivity(intent) }
                            .onFailure {
                                runCatching {
                                    context.startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
                                }
                            }
                    }
                },
            )
            Row(
                modifier = Modifier.padding(horizontal = Dimens.Space6, vertical = Dimens.Space2),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Dimens.Space1),
            ) {
                Icon(
                    Icons.Outlined.Shield,
                    contentDescription = null,
                    modifier = Modifier.size(Dimens.Space4),
                    tint = SfColors.Outline,
                )
                Text(
                    L10n.t(R.string.s_71088346ba),
                    fontSize = 11.sp,
                    color = SfColors.OnSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun StorageLocationRow(
    icon: ImageVector,
    title: String,
    subtitle: String,
    meta: String,
    action: String,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = Dimens.Space6, vertical = Dimens.Space2),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Dimens.Space3),
    ) {
        Icon(icon, contentDescription = null, tint = SfColors.Primary)
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, fontSize = 14.sp, fontWeight = FontWeight.Medium, color = SfColors.OnSurface)
            Text(subtitle, fontSize = 11.sp, color = SfColors.OnSurfaceVariant)
            if (meta.isNotEmpty()) {
                Text(meta, fontSize = 11.sp, color = SfColors.OnSurfaceVariant)
            }
        }
        if (action.isNotEmpty()) {
            TextButton(onClick = onClick) { Text(action, fontSize = 13.sp) }
        } else {
            Icon(Icons.Outlined.ChevronRight, contentDescription = null, tint = SfColors.Outline)
        }
    }
}
