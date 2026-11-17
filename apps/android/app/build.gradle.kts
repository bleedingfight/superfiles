import java.util.Properties
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.superfiles.app"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.superfiles.app"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"

        // 云盘 OAuth 凭据放 local.properties（已 gitignore），不进仓库。
        val secrets = Properties().apply {
            val f = rootProject.file("local.properties")
            if (f.exists()) f.inputStream().use { load(it) }
        }
        buildConfigField(
            "String",
            "GOOGLE_CLIENT_ID",
            "\"${secrets.getProperty("google.clientId", "")}\"",
        )
        buildConfigField(
            "String",
            "GOOGLE_CLIENT_SECRET",
            "\"${secrets.getProperty("google.clientSecret", "")}\"",
        )
        buildConfigField(
            "String",
            "DROPBOX_CLIENT_ID",
            "\"${secrets.getProperty("dropbox.clientId", "")}\"",
        )
        buildConfigField(
            "String",
            "ONEDRIVE_CLIENT_ID",
            "\"${secrets.getProperty("onedrive.clientId", "")}\"",
        )
        buildConfigField(
            "String",
            "PAN115_CLIENT_ID",
            "\"${secrets.getProperty("pan115.clientId", "")}\"",
        )
        // 云盘列表是否展示「未配置」的 OAuth 条目：
        // debug/内测需要看到全部，正式包只展示已接入的。
        buildConfigField("boolean", "SHOW_UNCONFIGURED_CLOUD", "false")
    }

    signingConfigs {
        // release 测试签名（不是发布 keystore；见 docs/07 分发规范）
        create("release") {
            storeFile = file(
                System.getProperty("user.home") + "/.android/release-test.keystore",
            )
            storePassword = "android"
            keyAlias = "android"
            keyPassword = "android"
        }
    }

    buildTypes {
        debug {
            buildConfigField("boolean", "SHOW_UNCONFIGURED_CLOUD", "true")
        }
        // Non-debuggable build signed with the debug key, so it can be installed
        // over an existing debug APK without wiping app data. Used for
        // day-to-day manual testing when debug-build composition cost hides
        // real performance.
        create("benchmark") {
            initWith(getByName("release"))
            signingConfig = signingConfigs.getByName("debug")
            isDebuggable = false
            isMinifyEnabled = false
            matchingFallbacks += listOf("release")
        }
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            signingConfig = signingConfigs.getByName("release")
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    lint {
        abortOnError = false
        checkReleaseBuilds = false
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // UniFFI generated Kotlin lives at the repository root, shared with the
    // other platforms. Regenerate with `scripts/gen-bindings.sh`.
    sourceSets["main"].java.srcDirs("../../../bindings/kotlin")

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2024.12.01"))
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")

    // 内置预览：视频播放（与 HarmonyOS 的 PreviewView 对齐）
    implementation("androidx.media3:media3-exoplayer:1.4.1")
    implementation("androidx.media3:media3-ui:1.4.1")

    // 一键组网扫码：CameraX 相机流（解码用上面 vendored 的 zxing）
    implementation("androidx.camera:camera-camera2:1.3.4")
    implementation("androidx.camera:camera-lifecycle:1.3.4")
    implementation("androidx.camera:camera-view:1.3.4")

    // UniFFI's generated Kotlin binding talks to the Rust core through JNA.
    implementation("net.java.dev.jna:jna:5.14.0@aar")

    // 就近分享（ADR 0005）：发送侧链接 → 二维码
    // vended 本地 jar（zxing-core 零传递依赖）：外网/代理不可用时构建仍离线可重复
    implementation(files("libs/zxing-core-3.5.3.jar"))

    debugImplementation("androidx.compose.ui:ui-tooling")
}
