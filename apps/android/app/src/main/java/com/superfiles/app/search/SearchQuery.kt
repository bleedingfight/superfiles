package com.superfiles.app.search

import com.superfiles.core.EntryKind

/**
 * 搜索查询契约：**所有搜索入口最终都归一为一个 [SearchQuery]**。
 *
 * 这样做的目的：字面搜索只是其中一种解析器（[LiteralQueryParser]），
 * 未来接自然语言时新增一个解析器（如 [LlmQueryParser]），把
 * 「上个月的 PDF 报告」翻译成等价的 [SearchQuery] 字段，执行层完全复用。
 */

/** 结果排序方式（未来可扩展相关度/大小等）。 */
enum class SortMode { MODIFIED_DESC, NAME_ASC }

/** 结构化查询条件。空字段 = 不限制。 */
data class SearchQuery(
    /** 关键词（子串 / 拼音，由索引层负责匹配；空字符串 = 全量候选）。 */
    val text: String = "",
    /** 扩展名白名单（小写无点），如 setOf("pdf","docx")。 */
    val extensions: Set<String> = emptySet(),
    /** 条目类型限制：文件/目录。null 或空 = 不限。 */
    val kinds: Set<EntryKind> = emptySet(),
    val modifiedAfterMs: Long? = null,
    val modifiedBeforeMs: Long? = null,
    val minSizeBytes: Long? = null,
    val maxSizeBytes: Long? = null,
    /** 限定在哪些根/目录（id 前缀匹配，如挂载 id 或绝对路径）。空 = 全根。 */
    val roots: List<String> = emptyList(),
    val limit: Int = 200,
    val sort: SortMode = SortMode.MODIFIED_DESC,
)

/** 解析时可见的上下文（当前根、类型筛选页、已挂载的根等）。 */
data class SearchContext(
    val currentRootId: String = "",
    val filterLabel: String? = null,
    val filterExts: Set<String> = emptySet(),
    val mountedRootIds: List<String> = emptyList(),
    val appRootPath: String = "",
    val sharedRootPath: String = "",
)

/** 查询解析器：输入原始文本 → 结构化查询。 */
fun interface QueryParser {
    suspend fun parse(input: String, context: SearchContext): SearchQuery
}

/**
 * 字面解析器（当前默认行为）：
 * 文本即关键词；类型筛选页（如「个人文档」）把范围扩展名并入查询。
 */
object LiteralQueryParser : QueryParser {
    override suspend fun parse(input: String, context: SearchContext): SearchQuery = SearchQuery(
        text = input,
        extensions = context.filterExts,
        limit = 200,
    )
}

/**
 * **自然语言解析器占位**：接入模型时构造它并 `viewModel.setQueryParser(...)`。
 *
 * ```
 * val parser = LlmQueryParser { input, ctx ->
 *     val json = myModel.chat(
 *         system = PROMPT,
 *         user = "输入：$input\n可用根：${ctx.mountedRootIds}\n今天：${...}"
 *     )
 *     SearchQueryJson.decode(json, ctx)   // 映射为 SearchQuery，未知字段忽略
 * }
 * ```
 *
 * 契约要点：
 * - 必须容忍模型输出不完整/非法（异常时回退字面解析，执行层兜底）；
 * - 时间/大小等相对表达（"上个月"、"2MB 以上"）由解析器换算成绝对毫秒/字节；
 * - `roots` 只能引用 [SearchContext] 提供的合法根，避免越权；
 * - 解析器应保持轻量可取消（在协程中执行，可被新的输入打断）。
 */
class LlmQueryParser(
    private val translate: suspend (input: String, context: SearchContext) -> SearchQuery,
) : QueryParser {
    override suspend fun parse(input: String, context: SearchContext): SearchQuery =
        runCatching { translate(input, context) }.getOrElse {
            LiteralQueryParser.parse(input, context)
        }
}
