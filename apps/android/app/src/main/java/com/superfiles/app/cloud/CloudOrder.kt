package com.superfiles.app.cloud

import android.content.Context

import com.superfiles.app.BuildConfig

/**
 * 云盘列表的展示顺序：
 * 1. 用户手动拖动过的顺序（持久化，优先）；
 * 2. 其余按「已配置优先 + 内置优先级」排序。
 *
 * 内置优先级把 Google Drive / Dropbox 放最前，未配置的自然落到后面。
 */
object CloudOrder {
    private const val PREF = "cloud_order"
    private const val KEY = "providers"

    private val PRIORITY = listOf(
        "google_drive",
        "dropbox",
        "onedrive",
        "pan115",
        "box",
        "baidu",
        "aliyun",
        "pan123",
    )

    fun ordered(context: Context, providers: List<CloudProvider>): List<CloudProvider> {
        // 正式包隐藏「未配置」的 provider；debug 全部展示，方便联调。
        val all = if (BuildConfig.SHOW_UNCONFIGURED_CLOUD) {
            providers
        } else {
            providers.filter { it.configured }
        }
        val saved = context.getSharedPreferences(PREF, Context.MODE_PRIVATE)
            .getString(KEY, null)
            ?.split(',')
            .orEmpty()
            .filter { it.isNotEmpty() }

        val byId = all.associateBy { it.id }
        val out = LinkedHashMap<String, CloudProvider>()
        saved.forEach { id -> byId[id]?.let { out[it.id] = it } }
        all.filter { it.id !in out }
            .sortedWith(
                compareByDescending<CloudProvider> { it.configured }
                    .thenBy { PRIORITY.indexOf(it.id).let { i -> if (i < 0) 99 else i } }
                    .thenBy { it.id },
            )
            .forEach { out[it.id] = it }
        return out.values.toList()
    }

    fun save(context: Context, list: List<CloudProvider>) {
        context.getSharedPreferences(PREF, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY, list.joinToString(",") { it.id })
            .apply()
    }
}
