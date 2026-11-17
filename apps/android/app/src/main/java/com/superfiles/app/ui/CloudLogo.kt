package com.superfiles.app.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * 云盘品牌 logo（矢量绘制，不依赖图片资源）。
 * 未识别的 provider 回退到「首字母色块」。
 */
@Composable
fun CloudProviderLogo(id: String, size: Dp = 26.dp) {
    when (id) {
        "google_drive" -> GoogleDriveLogo(size)
        "dropbox" -> DropboxLogo(size)
        "onedrive" -> OneDriveLogo(size)
        "pan115" -> BadgeLogo("115", Color(0xFF2E7CF6), size)
        "baidu" -> BadgeLogo("百", Color(0xFF2932E1), size)
        "aliyun" -> BadgeLogo("云", Color(0xFFFF6A00), size)
        "123pan" -> BadgeLogo("123", Color(0xFF00A870), size)
        "pan123" -> BadgeLogo("123", Color(0xFF00A870), size)
        "box" -> BadgeLogo("box", Color(0xFF0061D5), size)
        else -> BadgeLogo(id.take(1).uppercase(), Color(0xFF6B7280), size)
    }
}

/**
 * 网络存储协议图标：WebDAV / SMB / S3 / SFTP 各自绘制，云盘复用品牌 logo。
 * 用于「我的网络存储」列表和索引管理页，保证同一协议在两端长得一样。
 */
@Composable
fun StorageProtoLogo(protocol: String, size: Dp = 24.dp) {
    when (protocol.lowercase()) {
        "webdav" -> ProtoBadge(size, Color(0xFF2563EB)) { w, h ->
            val stroke = w * 0.075f
            val r = w * 0.30f
            val c = Offset(w / 2f, h / 2f)
            drawCircle(Color.White, r, c, style = Stroke(stroke))
            drawOval(
                Color.White,
                topLeft = Offset(w / 2f - r * 0.46f, h / 2f - r),
                size = Size(r * 0.92f, r * 2f),
                style = Stroke(stroke),
            )
            drawLine(
                Color.White,
                Offset(w / 2f - r, h / 2f),
                Offset(w / 2f + r, h / 2f),
                stroke,
            )
        }
        "smb", "samba" -> ProtoBadge(size, Color(0xFF2E7D32)) { w, h ->
            val stroke = w * 0.075f
            val radius = CornerRadius(w * 0.06f, w * 0.06f)
            drawRoundRect(
                Color.White,
                topLeft = Offset(w * 0.18f, h * 0.20f),
                size = Size(w * 0.64f, h * 0.24f),
                cornerRadius = radius,
                style = Stroke(stroke),
            )
            drawRoundRect(
                Color.White,
                topLeft = Offset(w * 0.18f, h * 0.56f),
                size = Size(w * 0.64f, h * 0.24f),
                cornerRadius = radius,
                style = Stroke(stroke),
            )
            drawLine(
                Color.White,
                Offset(w * 0.5f, h * 0.44f),
                Offset(w * 0.5f, h * 0.56f),
                stroke,
            )
        }
        "s3" -> ProtoBadge(size, Color(0xFFFF9900)) { w, h ->
            val stroke = w * 0.075f
            drawPath(
                Path().apply {
                    moveTo(w * 0.26f, h * 0.38f)
                    lineTo(w * 0.74f, h * 0.38f)
                    lineTo(w * 0.66f, h * 0.80f)
                    lineTo(w * 0.34f, h * 0.80f)
                    close()
                },
                Color.White,
                style = Stroke(stroke),
            )
            drawOval(
                Color.White,
                topLeft = Offset(w * 0.26f, h * 0.26f),
                size = Size(w * 0.48f, h * 0.16f),
                style = Stroke(stroke),
            )
        }
        "sftp" -> ProtoBadge(size, Color(0xFF6D28D9)) { w, h ->
            val stroke = w * 0.075f
            drawRoundRect(
                Color.White,
                topLeft = Offset(w * 0.16f, h * 0.22f),
                size = Size(w * 0.68f, h * 0.56f),
                cornerRadius = CornerRadius(w * 0.08f, w * 0.08f),
                style = Stroke(stroke),
            )
            drawPath(
                Path().apply {
                    moveTo(w * 0.30f, h * 0.40f)
                    lineTo(w * 0.42f, h * 0.50f)
                    lineTo(w * 0.30f, h * 0.60f)
                },
                Color.White,
                style = Stroke(stroke),
            )
            drawLine(
                Color.White,
                Offset(w * 0.50f, h * 0.60f),
                Offset(w * 0.66f, h * 0.60f),
                stroke,
            )
        }
        // 云盘：沿用品牌 logo，保证和「云存储」列表里的图标一致。
        "gdrive" -> CloudProviderLogo("google_drive", size)
        "pan115", "115" -> CloudProviderLogo("pan115", size)
        "pan123", "123pan" -> CloudProviderLogo("123pan", size)
        else -> CloudProviderLogo(protocol, size)
    }
}

@Composable
private fun ProtoBadge(size: Dp, color: Color, glyph: DrawScope.(Float, Float) -> Unit) {
    Canvas(
        Modifier
            .size(size)
            .clip(RoundedCornerShape(size * 0.28f))
            .background(color),
    ) {
        glyph(this.size.width, this.size.height)
    }
}

@Composable
private fun BadgeLogo(text: String, color: Color, size: Dp) {
    Box(
        modifier = Modifier
            .size(size)
            .clip(RoundedCornerShape(size * 0.28f))
            .background(color),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = text,
            color = Color.White,
            fontSize = (size.value * 0.34f).sp,
            fontWeight = FontWeight.Bold,
            maxLines = 1,
        )
    }
}

@Composable
private fun GoogleDriveLogo(size: Dp) {
    Canvas(Modifier.size(size)) {
        val w = this.size.width
        val h = this.size.height
        val blue = Color(0xFF4285F4)
        val green = Color(0xFF34A853)
        val yellow = Color(0xFFFBBC04)
        // 右侧蓝色边
        drawPath(
            Path().apply {
                moveTo(w * 0.5f, 0f)
                lineTo(w, h * 0.86f)
                lineTo(w * 0.72f, h * 0.86f)
                lineTo(w * 0.36f, h * 0.24f)
                close()
            },
            blue,
        )
        // 左侧绿色边
        drawPath(
            Path().apply {
                moveTo(w * 0.5f, 0f)
                lineTo(w * 0.14f, h * 0.86f)
                lineTo(0f, h * 0.55f)
                lineTo(w * 0.36f, 0f)
                close()
            },
            green,
        )
        // 底部黄色
        drawPath(
            Path().apply {
                moveTo(0f, h * 0.55f)
                lineTo(w * 0.14f, h * 0.86f)
                lineTo(w, h * 0.86f)
                lineTo(w * 0.86f, h * 0.55f)
                close()
            },
            yellow,
        )
    }
}

@Composable
private fun DropboxLogo(size: Dp) {
    Canvas(Modifier.size(size)) {
        val w = this.size.width
        val h = this.size.height
        val blue = Color(0xFF0061FF)
        // 四个菱形
        diamond(this, w * 0.25f, h * 0.30f, w * 0.22f, blue)
        diamond(this, w * 0.75f, h * 0.30f, w * 0.22f, blue)
        diamond(this, w * 0.25f, h * 0.62f, w * 0.22f, blue)
        diamond(this, w * 0.75f, h * 0.62f, w * 0.22f, blue)
        // 底部小三角
        drawPath(
            Path().apply {
                moveTo(w * 0.5f, h * 0.74f)
                lineTo(w * 0.72f, h * 0.88f)
                lineTo(w * 0.5f, h * 1.0f)
                lineTo(w * 0.28f, h * 0.88f)
                close()
            },
            blue,
        )
    }
}

private fun diamond(scope: DrawScope, cx: Float, cy: Float, r: Float, color: Color) {
    scope.drawPath(
        Path().apply {
            moveTo(cx, cy - r)
            lineTo(cx + r, cy)
            lineTo(cx, cy + r)
            lineTo(cx - r, cy)
            close()
        },
        color,
    )
}

@Composable
private fun OneDriveLogo(size: Dp) {
    Canvas(Modifier.size(size)) {
        val w = this.size.width
        val h = this.size.height
        val blue = Color(0xFF0078D4)
        drawOval(blue, topLeft = Offset(w * 0.06f, h * 0.46f), size = Size(w * 0.52f, h * 0.42f))
        drawOval(blue, topLeft = Offset(w * 0.36f, h * 0.30f), size = Size(w * 0.52f, h * 0.58f))
        drawOval(blue, topLeft = Offset(w * 0.56f, h * 0.52f), size = Size(w * 0.40f, h * 0.36f))
    }
}
