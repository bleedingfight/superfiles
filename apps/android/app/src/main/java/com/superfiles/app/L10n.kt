package com.superfiles.app

import android.content.Context
import androidx.annotation.StringRes

/**
 * 轻量文案入口：资源仍是标准的 `values/strings.xml`（中文默认）与
 * `values-en/strings.xml`（英文），系统/单应用语言切换由 Android 资源配置完成。
 *
 * 之所以不直接在 Compose 里用 `stringResource`：本项目大量文案产生于
 * ViewModel / 通知栏 / 后台任务（非 composable 上下文），需要一个不依赖
 * CompositionLocal 的取值方式。初始化发生在 Application.onCreate。
 */
object L10n {
    @Volatile
    private var appContext: Context? = null

    fun init(context: Context) {
        appContext = context.applicationContext
    }

    fun t(@StringRes id: Int): String = appContext?.getString(id) ?: ""

    fun t(@StringRes id: Int, vararg args: Any?): String {
        val context = appContext ?: return ""
        val safe = args.map { it ?: "" }.toTypedArray()
        return context.getString(id, *safe)
    }
}
