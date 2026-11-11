package com.superfiles.app.search

import com.superfiles.core.EntryKind
import java.time.DayOfWeek
import java.time.ZonedDateTime
import java.time.temporal.TemporalAdjusters

/**
 * 轻量中文自然语言解析器（无需模型、离线可用）：
 * 把「上个月拍的照片」「大于 10MB 的 pdf」「最近的 pptx」翻译成 [SearchQuery]。
 *
 * 能力边界：解析**类型 / 时间 / 大小 / 文件夹**等结构化意图，剩余词作为文件名
 * 关键词；不解析画面内容（「海边的照片」需要视觉模型，见 docs/08）。
 */
object NaturalLanguageQueryParser : QueryParser {

    private val IMAGE = setOf(
        "jpg", "jpeg", "png", "gif", "bmp", "webp", "heic", "heif", "tif", "tiff",
        "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "raw",
    )
    private val VIDEO = setOf("mp4", "mkv", "mov", "avi", "webm", "m4v", "3gp", "ts")
    private val AUDIO = setOf("mp3", "flac", "wav", "aac", "m4a", "ogg", "opus", "amr")
    private val DOCS = setOf("pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "txt", "md", "csv")
    private val ARCHIVE = setOf("zip", "rar", "7z", "tar", "gz", "bz2", "xz")

    /** 类型词 → 扩展名集合（先匹配到的更具体规则先移除文本）。 */
    private val TYPE_RULES: List<Pair<Regex, Set<String>>> = listOf(
        Regex("(word\\s*文档|microsoft\\s*word|\\bword\\b|\\bdocx?\\b)", RegexOption.IGNORE_CASE) to setOf("doc", "docx"),
        Regex("(excel\\s*表格|\\bexcel\\b|\\bxlsx?\\b|电子表格)", RegexOption.IGNORE_CASE) to setOf("xls", "xlsx", "csv"),
        Regex("(\\bpowerpoint\\b|幻灯片|演示文稿|\\bpptx?\\b)", RegexOption.IGNORE_CASE) to setOf("ppt", "pptx"),
        Regex("(\\bpdf\\b)", RegexOption.IGNORE_CASE) to setOf("pdf"),
        Regex("(纯文本|\\btxt\\b|\\bmarkdown\\b|\\bmd\\b)", RegexOption.IGNORE_CASE) to setOf("txt", "md"),
        Regex("(压缩包|压缩文件|\\bzip\\b|\\brar\\b|\\b7z\\b)", RegexOption.IGNORE_CASE) to ARCHIVE,
        Regex("(视频|影片|录像|\\bvideo\\b)", RegexOption.IGNORE_CASE) to VIDEO,
        Regex("(音乐|音频|歌曲|\\baudio\\b|\\bmusic\\b)", RegexOption.IGNORE_CASE) to AUDIO,
        Regex("(图片|照片|相片|图像|\\bphotos?\\b|\\bimages?\\b|\\bpictures?\\b)", RegexOption.IGNORE_CASE) to IMAGE,
        Regex("(文档|\\bdocuments?\\b)", RegexOption.IGNORE_CASE) to DOCS,
        Regex("(文件夹|目录|\\bfolder\\b|\\bdirector(y|ies)\\b)", RegexOption.IGNORE_CASE) to emptySet(),
    )

    private val FOLDER_RULE = Regex("(文件夹|目录|\\bfolder\\b|\\bdirector(y|ies)\\b)", RegexOption.IGNORE_CASE)
    private val SCREENSHOT_RULE = Regex("(截图|截屏|屏幕截图|\\bscreenshots?\\b)", RegexOption.IGNORE_CASE)
    private val INTENT_PREFIX =
        Regex("^(请|麻烦|帮我|帮忙)?\\s*(找一下|帮忙找|帮我找|搜索一下|搜一下|查找|搜索|找找|找|搜|查|看看)\\s*")

    override suspend fun parse(input: String, context: SearchContext): SearchQuery {
        val now = ZonedDateTime.now()
        var working = input.trim()
        var exts: Set<String> = emptySet()
        var kinds: Set<EntryKind> = emptySet()
        var after: Long? = null
        var before: Long? = null
        var minSize: Long? = null
        var maxSize: Long? = null
        var screenshotOnly = false

        // ---- 时间 / 大小（匹配到的词从查询里移除） ----
        val dayStart = startOfDay(now)
        fun apply(regex: Regex, onMatch: (MatchResult) -> Unit) {
            working = regex.replace(working) { m ->
                onMatch(m)
                " "
            }
        }
        when {
            working.contains("前天") -> {
                after = dayStart - DAY_MS * 2
                before = dayStart - DAY_MS
                working = working.replace("前天", " ")
            }
            working.contains("昨天") || working.contains("昨日") -> {
                after = dayStart - DAY_MS
                before = dayStart
                working = working.replace(Regex("昨天|昨日"), " ")
            }
            working.contains("今天") || working.contains("今日") -> {
                after = dayStart
                working = working.replace(Regex("今天|今日"), " ")
            }
        }
        apply(Regex("(上个月|上月)")) {
            after = startOfMonth(now.minusMonths(1))
            before = startOfMonth(now)
        }
        if (after == null) apply(Regex("(本月|这个月|当月)")) { after = startOfMonth(now) }
        apply(Regex("(上个星期|上上周|上周)")) {
            val thisWeek = startOfWeek(now)
            after = thisWeek - DAY_MS * 7
            before = thisWeek
        }
        if (after == null) apply(Regex("(本周|这周|这个星期)")) { after = startOfWeek(now) }
        apply(Regex("(去年)")) {
            val yearStart = startOfYear(now)
            after = startOfYear(now.minusYears(1))
            before = yearStart
        }
        if (after == null) apply(Regex("(今年|本年)")) { after = startOfYear(now) }
        apply(Regex("(最近|近)?\\s*(\\d+)\\s*(天|日)(以内|之内|内)?")) { m ->
            val n = m.groupValues[2].toLongOrNull() ?: 0
            if (n > 0) after = now.minusDays(n).toInstant().toEpochMilli()
        }
        apply(Regex("(最近|近)?\\s*(\\d+)\\s*(周|个星期)(以内|之内|内)?")) { m ->
            val n = m.groupValues[2].toLongOrNull() ?: 0
            if (n > 0) after = now.minusWeeks(n).toInstant().toEpochMilli()
        }
        apply(Regex("(最近|近)?\\s*(\\d+)\\s*个月(以内|之内|内)?")) { m ->
            val n = m.groupValues[2].toLongOrNull() ?: 0
            if (n > 0) after = now.minusMonths(n).toInstant().toEpochMilli()
        }
        apply(Regex("(最近一周|一周内|最近一个星期)")) {
            after = now.minusWeeks(1).toInstant().toEpochMilli()
        }
        apply(Regex("(最近一个月|一个月内|近一个月)")) {
            after = now.minusMonths(1).toInstant().toEpochMilli()
        }

        val num = "(\\d+(?:\\.\\d+)?)\\s*(kb|k|mb|m|gb|g|tb|t)"
        apply(Regex("(大于|超过|多于|至少|>)\\s*$num", RegexOption.IGNORE_CASE)) { m ->
            minSize = bytesOf(m.groupValues[2], m.groupValues[3])
        }
        apply(Regex("(小于|不到|少于|至多|<)\\s*$num", RegexOption.IGNORE_CASE)) { m ->
            maxSize = bytesOf(m.groupValues[2], m.groupValues[3])
        }
        apply(Regex("$num\\s*(以上|及以上)", RegexOption.IGNORE_CASE)) { m ->
            minSize = bytesOf(m.groupValues[1], m.groupValues[2])
        }
        apply(Regex("$num\\s*(以下|以内)", RegexOption.IGNORE_CASE)) { m ->
            maxSize = bytesOf(m.groupValues[1], m.groupValues[2])
        }

        // ---- 类型 ----
        if (SCREENSHOT_RULE.containsMatchIn(working)) {
            exts = IMAGE
            kinds = setOf(EntryKind.FILE)
            screenshotOnly = true
            working = SCREENSHOT_RULE.replace(working, " ")
        }
        for ((regex, set) in TYPE_RULES) {
            if (!regex.containsMatchIn(working)) continue
            if (set.isNotEmpty()) {
                exts = if (exts.isEmpty()) set else exts + set
                kinds = setOf(EntryKind.FILE)
            }
            working = regex.replace(working, " ")
        }
        if (FOLDER_RULE.containsMatchIn(input)) {
            kinds = setOf(EntryKind.DIRECTORY)
            exts = emptySet()
        }

        // ---- 剩余词作为文件名关键词 ----
        working = INTENT_PREFIX.replace(working, " ")
        working = working
            .replace(Regex("(帮我|帮忙|麻烦|请)"), " ")
            .replace(Regex("(的|之)"), " ")
            .replace(Regex("(所有|全部|一些|相关)"), " ")
            .replace(Regex("(文件|文件们)\\s*$"), " ")
            .replace(Regex("\\s+"), " ")
            .trim()
            .trim('，', ',', '。', '.', '、', ':', '：', '"', '\'')

        if (screenshotOnly && working.isBlank()) {
            working = "screenshot"
        }

        val parsedExts = exts
        val finalExts = when {
            parsedExts.isEmpty() -> context.filterExts
            context.filterExts.isEmpty() -> parsedExts
            else -> context.filterExts intersect parsedExts
        }

        // 没有任何结构化意图、也没有剩余关键词 → 回退字面解析，避免误伤普通搜索
        if (finalExts.isEmpty() && kinds.isEmpty() && after == null && before == null &&
            minSize == null && maxSize == null && working.isBlank()
        ) {
            return LiteralQueryParser.parse(input, context)
        }

        return SearchQuery(
            text = working,
            extensions = finalExts,
            kinds = kinds,
            modifiedAfterMs = after,
            modifiedBeforeMs = before,
            minSizeBytes = minSize,
            maxSizeBytes = maxSize,
            limit = 200,
            sort = SortMode.MODIFIED_DESC,
        )
    }

    // ---- 时间辅助（毫秒时间戳） ----

    private const val DAY_MS = 86_400_000L

    private fun startOfDay(t: ZonedDateTime): Long =
        t.toLocalDate().atStartOfDay(t.zone).toInstant().toEpochMilli()

    private fun startOfMonth(t: ZonedDateTime): Long =
        t.toLocalDate().withDayOfMonth(1).atStartOfDay(t.zone).toInstant().toEpochMilli()

    private fun startOfWeek(t: ZonedDateTime): Long =
        t.toLocalDate().with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY))
            .atStartOfDay(t.zone).toInstant().toEpochMilli()

    private fun startOfYear(t: ZonedDateTime): Long =
        t.toLocalDate().withDayOfYear(1).atStartOfDay(t.zone).toInstant().toEpochMilli()

    private fun bytesOf(number: String, unit: String): Long? {
        val value = number.toDoubleOrNull() ?: return null
        val factor = when (unit.lowercase()) {
            "k", "kb" -> 1024.0
            "m", "mb" -> 1024.0 * 1024
            "g", "gb" -> 1024.0 * 1024 * 1024
            "t", "tb" -> 1024.0 * 1024 * 1024 * 1024
            else -> 1.0
        }
        return (value * factor).toLong()
    }
}
