package com.superfiles.app.ui

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.superfiles.app.L10n
import com.superfiles.app.R
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resumeWithException

/**
 * 全屏扫码（LocalSend 一键组网码）：CameraX + vendored zxing 解码。
 * 相机权限被拒时退化为提示文本；识别成功回调一次即由调用方关闭。
 */
@Composable
fun QrScanSheet(onClose: () -> Unit, onResult: (String) -> Unit) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    var granted by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED,
        )
    }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted = it }
    LaunchedEffect(Unit) { if (!granted) launcher.launch(Manifest.permission.CAMERA) }

    val found = remember { java.util.concurrent.atomic.AtomicBoolean(false) }
    val previewView = remember { PreviewView(context) }

    LaunchedEffect(granted) {
        if (!granted) return@LaunchedEffect
        val provider = suspendCancellableCoroutine<ProcessCameraProvider> { cont ->
            val future = ProcessCameraProvider.getInstance(context)
            future.addListener(
                {
                    try {
                        cont.resume(future.get()) { }
                    } catch (e: Throwable) {
                        cont.resumeWithException(e)
                    }
                },
                ContextCompat.getMainExecutor(context),
            )
        }
        try {
            provider.unbindAll()
            val preview = Preview.Builder().build().also { it.setSurfaceProvider(previewView.surfaceProvider) }
            val analysis = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
            analysis.setAnalyzer(ContextCompat.getMainExecutor(context)) { proxy ->
                val text = decodeQrOnce(proxy)
                if (text != null && found.compareAndSet(false, true)) {
                    onResult(text)
                }
            }
            provider.bindToLifecycle(lifecycleOwner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
        } catch (e: Exception) {
            onClose()
        }
    }

    Box(modifier = Modifier.fillMaxSize().background(Color.Black)) {
        if (granted) {
            AndroidView(factory = { previewView }, modifier = Modifier.fillMaxSize())
        } else {
            Text(
                L10n.t(R.string.s_lswiz_cam_denied),
                color = Color.White,
                fontSize = 13.sp,
                modifier = Modifier.align(Alignment.Center),
            )
        }
        IconButton(
            onClick = onClose,
            modifier = Modifier.align(Alignment.TopStart).padding(16.dp),
        ) {
            Icon(Icons.Filled.Close, contentDescription = null, tint = Color.White)
        }
        Text(
            L10n.t(R.string.s_lswiz_scan_frame_hint),
            color = Color.White.copy(alpha = 0.85f),
            fontSize = 13.sp,
            modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 48.dp),
        )
    }
}

/** 单帧解码（QR only）；任何情况下都负责关闭 ImageProxy。 */
private fun decodeQrOnce(proxy: ImageProxy): String? {
    try {
        val plane = proxy.planes[0]
        val stride = plane.rowStride
        val w = proxy.width
        val h = proxy.height
        val data: ByteArray = if (stride == w) {
            ByteArray(plane.buffer.remaining()).also { plane.buffer.get(it) }
        } else {
            // rowStride 带对齐填充：逐行拷掉 padding
            ByteArray(w * h).also { out ->
                val row = ByteArray(stride)
                for (y in 0 until h) {
                    plane.buffer.position(y * stride)
                    plane.buffer.get(row, 0, w)
                    System.arraycopy(row, 0, out, y * w, w)
                }
            }
        }
        val source = PlanarYUVLuminanceSource(data, w, h, 0, 0, w, h, false)
        val reader = MultiFormatReader().apply {
            setHints(mapOf(DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE)))
        }
        val result = reader.decode(BinaryBitmap(HybridBinarizer(source)))
        return result.text
    } catch (e: Exception) {
        return null
    } finally {
        proxy.close()
    }
}
