package com.superfiles.app.ui

import com.superfiles.app.L10n
import com.superfiles.app.R

import android.Manifest
import android.accounts.AccountManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.CloudUpload
import androidx.compose.material.icons.outlined.DeleteSweep
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Devices
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Shield
import androidx.compose.material.icons.outlined.Storage
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.superfiles.app.VfsViewModel

/**
 * 「我的」：设置 + 状态中心。每个设置项 = 独立圆角卡：
 * 左侧浅灰圆角方块装图标，右侧为标题/副标题/操作区；不再使用分割线。
 */
@Composable
fun MineScreen(
    viewModel: VfsViewModel,
    onOpenTransfers: () -> Unit,
    onOpenLocalSend: () -> Unit = {},
    onOpenStorageCleanup: () -> Unit = {},
    onOpenIndexManage: () -> Unit = {},
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    var showLicenses by remember { mutableStateOf(false) }
    var showEditProfile by remember { mutableStateOf(false) }


    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
        LazyColumn(
            modifier = Modifier
                .widthIn(max = Adaptive.ListMaxWidth)
                .fillMaxSize()
                .padding(horizontal = Dimens.Space6),
        ) {
            item {
                Text(
                    L10n.t(R.string.s_07b1811842),
                    fontSize = 28.sp,
                    fontWeight = FontWeight.Bold,
                    color = SfColors.OnSurface,
                    modifier = Modifier.padding(top = Dimens.Space3, bottom = Dimens.Space2),
                )
            }

            item {
                UserProfileCard(
                    nickname = state.userNickname,
                    avatarChar = state.userAvatarChar,
                    onClick = { showEditProfile = true },
                )
            }

            item { MineSection(L10n.t(R.string.s_316ddc8bcb)) }
            item {
                SettingRow(
                    icon = Icons.Outlined.DeleteSweep,
                    title = L10n.t(R.string.s_b699a4247a),
                    onClick = onOpenStorageCleanup,
                    chevron = true,
                )
            }
            item {
                SettingRow(
                    icon = Icons.Outlined.Storage,
                    title = L10n.t(R.string.s_index_manage_title),
                    subtitle = L10n.t(R.string.s_index_manage_hint),
                    onClick = onOpenIndexManage,
                    chevron = true,
                )
            }
            item {
                SettingRow(
                    icon = Icons.Outlined.Shield,
                    title = L10n.t(R.string.s_124d905403),
                    subtitle = L10n.t(R.string.s_897995725e),
                    trailingContent = {
                        SfSwitch(checked = state.showHidden, onCheckedChange = viewModel::setShowHidden)
                    },
                )
            }
            item {
                val allowed = android.os.Environment.isExternalStorageManager()
                SettingRow(
                    icon = Icons.Outlined.Shield,
                    title = L10n.t(R.string.s_dc9562b892),
                    subtitle = if (allowed) L10n.t(R.string.s_e392131144) else L10n.t(R.string.s_652b094bf6),
                    trailing = if (allowed) L10n.t(R.string.s_1324e4e45b) else L10n.t(R.string.s_4a1c90d86b),
                    chevron = !allowed,
                    onClick = if (allowed) {
                        null
                    } else {
                        {
                            val intent = Intent(
                                Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                                android.net.Uri.parse("package:${context.packageName}"),
                            )
                            runCatching { context.startActivity(intent) }
                        }
                    },
                )
            }

            item { MineSection(L10n.t(R.string.s_feed0b2e46)) }
            item {
                val active = state.transfers.count {
                    it.id !in state.foregroundTransfers && (
                        it.state == com.superfiles.core.TransferState.QUEUED ||
                            it.state == com.superfiles.core.TransferState.RUNNING ||
                            it.state == com.superfiles.core.TransferState.PAUSED
                        )
                }
                SettingRow(
                    icon = Icons.Outlined.CloudUpload,
                    title = L10n.t(R.string.s_feed0b2e46),
                    subtitle = L10n.t(R.string.s_ad137e9cdf, (active), (state.resumable.size)),
                    trailing = L10n.t(R.string.s_607e7a4f37),
                    onClick = onOpenTransfers,
                    chevron = true,
                )
            }

            item {
                SettingRow(
                    icon = Icons.Outlined.Devices,
                    title = L10n.t(R.string.s_4494d7e5cb),
                    subtitle = if (state.localSendRunning) {
                        L10n.t(R.string.s_79b92c6a30, (state.localSendPeers.size))
                    } else {
                        L10n.t(R.string.s_5d4ddd7af3)
                    },
                    trailing = if (state.localSendRunning) L10n.t(R.string.s_9db7a84fcd) else L10n.t(R.string.s_08b55fea3c),
                    onClick = onOpenLocalSend,
                    chevron = true,
                )
            }

            item { MineSection(L10n.t(R.string.s_81d9f50544)) }
            item {
                SettingRow(
                    icon = Icons.Outlined.Info,
                    title = L10n.t(R.string.s_fe2df04a16),
                    trailing = "v${remember { viewModel.coreVersion() }}",
                )
            }
            item {
                SettingRow(
                    icon = Icons.Outlined.Description,
                    title = L10n.t(R.string.s_cf57fa8b1b),
                    trailing = L10n.t(R.string.s_607e7a4f37),
                    onClick = { showLicenses = true },
                )
            }
            item {
                SettingRow(
                    icon = Icons.Outlined.CloudUpload,
                    title = L10n.t(R.string.s_eca99856f2),
                    subtitle = L10n.t(R.string.s_ac32df2229),
                    trailing = L10n.t(R.string.s_55405ea6ff),
                    onClick = {
                        val file = viewModel.exportDiagnostics(context)
                        if (file == null) {
                            viewModel.notice(L10n.t(R.string.s_a039c4b07d))
                        } else {
                            val uri = FileProvider.getUriForFile(
                                context,
                                "${context.packageName}.fileprovider",
                                file,
                            )
                            val share = Intent(Intent.ACTION_SEND).apply {
                                type = "text/plain"
                                putExtra(Intent.EXTRA_STREAM, uri)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                            runCatching {
                                context.startActivity(Intent.createChooser(share, L10n.t(R.string.s_eca99856f2)))
                            }
                        }
                    },
                )
            }

            item { Spacer(Modifier.height(Dimens.Space8)) }
        }
    }

    if (showEditProfile) {
        EditProfileDialog(
            currentNickname = state.userNickname,
            onDismiss = { showEditProfile = false },
            onSave = { name ->
                showEditProfile = false
                viewModel.updateNickname(name)
            },
            notify = viewModel::notice,
        )
    }

    if (showLicenses) {
        SfDialog(
            onDismissRequest = { showLicenses = false },
            title = L10n.t(R.string.s_cf57fa8b1b),
            actions = { PrimaryConfirmButton(L10n.t(R.string.s_b15d91274e)) { showLicenses = false } },
        ) {
            SfDialogMessage(
                L10n.t(R.string.s_10a01b3e69) +
                    "· Material Icons — Apache License 2.0\n" +
                    L10n.t(R.string.s_7da73a17e7),
            )
        }
    }
}

/** 分区标题（浅灰小字，无分割线）。 */
@Composable
private fun MineSection(title: String) {
    Text(
        title,
        fontSize = 12.sp,
        color = SfColors.OnSurfaceVariant,
        modifier = Modifier.padding(top = Dimens.Space4, bottom = Dimens.Space1),
    )
}

/** 单个设置项：整行圆角卡 + 左侧浅灰圆角图标块 + 右侧内容。 */
@Composable
private fun SettingRow(
    icon: ImageVector,
    title: String,
    subtitle: String? = null,
    trailing: String? = null,
    trailingContent: (@Composable () -> Unit)? = null,
    onClick: (() -> Unit)? = null,
    chevron: Boolean = false,
) {
    Surface(
        shape = RoundedCornerShape(Dimens.RadiusM),
        color = SfColors.SurfaceCard,
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = Dimens.Space1 / 2),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .let { if (onClick != null) it.clickable(onClick = onClick) else it }
                .padding(horizontal = Dimens.Space3, vertical = Dimens.Space2),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Dimens.Space3),
        ) {
            // 左侧：浅灰圆角方块 + 图标
            Box(
                modifier = Modifier
                    .size(36.dp)
                    .clip(RoundedCornerShape(Dimens.RadiusS))
                    .background(SfColors.SearchFieldBg),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    icon,
                    contentDescription = null,
                    modifier = Modifier.size(20.dp),
                    tint = SfColors.Primary,
                )
            }
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                Text(title, fontSize = 14.sp, color = SfColors.OnSurface)
                subtitle?.let { Text(it, fontSize = 11.sp, color = SfColors.OnSurfaceVariant) }
            }
            when {
                trailingContent != null -> trailingContent()
                trailing != null -> Text(trailing, fontSize = 12.sp, color = SfColors.OnSurfaceVariant)
            }
        }
    }
}

@Composable
private fun UserProfileCard(nickname: String, avatarChar: String, onClick: () -> Unit) {
    Surface(
        shape = RoundedCornerShape(Dimens.RadiusM),
        color = SfColors.SurfaceCard,
        modifier = Modifier.fillMaxWidth().padding(vertical = Dimens.Space1),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable(onClick = onClick)
                .padding(horizontal = Dimens.Space4, vertical = Dimens.Space3),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Dimens.Space3),
        ) {
            Box(
                modifier = Modifier
                    .size(44.dp)
                    .clip(CircleShape)
                    .background(SfColors.AvatarBg),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    avatarChar.ifBlank { L10n.t(R.string.s_1681525453) },
                    fontSize = 18.sp,
                    fontWeight = FontWeight.Medium,
                    color = SfColors.PrimaryWarm,
                )
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                Text(nickname, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = SfColors.OnSurface)
                Text(L10n.t(R.string.s_ec9b0f49d2), fontSize = 11.sp, color = SfColors.OnSurfaceVariant)
            }
        }
    }
}

@Composable
private fun EditProfileDialog(
    currentNickname: String,
    onDismiss: () -> Unit,
    onSave: (String) -> Unit,
    notify: (String) -> Unit,
) {
    var draft by remember(currentNickname) { mutableStateOf(currentNickname) }
    val context = LocalContext.current

    val importLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        if (!granted) {
            notify(L10n.t(R.string.s_0c03846633))
            return@rememberLauncherForActivityResult
        }
        val name = readFirstAccountName(context)
        if (name != null) {
            draft = name
        } else {
            notify(L10n.t(R.string.s_14e46f9b28))
        }
    }

    fun startImport() {
        if (context.checkSelfPermission(Manifest.permission.GET_ACCOUNTS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            val name = readFirstAccountName(context)
            if (name != null) draft = name else notify(L10n.t(R.string.s_14e46f9b28))
        } else {
            importLauncher.launch(Manifest.permission.GET_ACCOUNTS)
        }
    }

    SfDialog(
        onDismissRequest = onDismiss,
        title = L10n.t(R.string.s_17cd044e7c),
        actions = {
            SafeCancelButton(onClick = onDismiss)
            PrimaryConfirmButton(L10n.t(R.string.s_be5fbbe34c), enabled = draft.isNotBlank()) { onSave(draft) }
        },
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(Dimens.Space2)) {
            Text(L10n.t(R.string.s_2ae76c458c), fontSize = 11.sp, color = SfColors.OnSurfaceVariant)
            SfInputField(
                value = draft,
                onValueChange = { draft = it },
                placeholder = L10n.t(R.string.s_ededa3026a),
            )
            TextButton(onClick = { startImport() }) {
                Text(L10n.t(R.string.s_9f2fb76127), fontSize = 12.sp)
            }
            Text(
                L10n.t(R.string.s_43d632ab93),
                fontSize = 11.sp,
                color = SfColors.OnSurfaceVariant,
            )
        }
    }
}

private fun readFirstAccountName(context: Context): String? = runCatching {
    val accounts = AccountManager.get(context).accounts
    val preferred = accounts.firstOrNull {
        it.type == "com.google" || it.type == "com.xiaomi"
    } ?: accounts.firstOrNull()
    preferred?.name?.substringBefore('@')?.takeIf { it.isNotBlank() }
}.getOrNull()
