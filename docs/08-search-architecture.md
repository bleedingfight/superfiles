# 08 · 搜索架构（可插拔查询解析器）

> 目标：把"搜索"从「一个字符串」升级为「结构化查询」，让字面搜索、类型筛选、
> 以及未来的**自然语言搜索（LLM）**共用同一条执行链路。

## 1. 分层

```
用户输入（原始文本）
   │
   ▼
QueryParser（可注入）                         ← 接入模型的位置
   ├── LiteralQueryParser   字面：文本=关键词（当前默认）
   └── LlmQueryParser       自然语言：模型 → SearchQuery（占位，待接入）
   │
   ▼
SearchQuery（结构化条件）
   text / extensions / kinds / modified 范围 / size 范围 / roots / limit / sort
   │
   ▼
executeQuery()（VfsViewModel）
   ├── 索引候选：跨根合并 FTS5（trigram 子串 + 拼音）查询，去重
   ├── 结构化过滤：扩展名 / 类型 / 修改时间 / 大小 / 根前缀
   ├── 排序：修改时间倒序（默认）或名称
   └── 截断 limit
   │
   ▼
UI 列表（复用 FileListRow；搜索态副标题显示所在位置）
```

代码：`apps/android/app/src/main/java/com/superfiles/app/search/SearchQuery.kt`
（契约 + 字面解析器 + LLM 占位）、`VfsViewModel.search()/executeQuery()`（执行层）。

## 2. 契约

```kotlin
data class SearchQuery(
    val text: String = "",
    val extensions: Set<String> = emptySet(),
    val kinds: Set<EntryKind> = emptySet(),
    val modifiedAfterMs: Long? = null,
    val modifiedBeforeMs: Long? = null,
    val minSizeBytes: Long? = null,
    val maxSizeBytes: Long? = null,
    val roots: List<String> = emptyList(),   // id 前缀，只能引用上下文提供的合法根
    val limit: Int = 200,
    val sort: SortMode = SortMode.MODIFIED_DESC,
)

fun interface QueryParser {
    suspend fun parse(input: String, context: SearchContext): SearchQuery
}

data class SearchContext(
    val currentRootId: String,
    val filterLabel: String?,
    val filterExts: Set<String>,        // 类型筛选页的扩展名范围
    val mountedRootIds: List<String>,   // 可用的挂载根（roots 白名单）
    val appRootPath: String,
    val sharedRootPath: String,
)
```

## 3. 接自然语言（步骤）

1. 实现模型的翻译函数（本地模型/远端 API 均可）：
   ```kotlin
   val parser = LlmQueryParser { input, ctx ->
       val prompt = """
          把用户的文件搜索请求翻译成 JSON：
          {"text":"关键词","extensions":["pdf"],"kinds":["FILE"],
           "modifiedAfterMs":123,"minSizeBytes":0,"roots":[]}
          规则：只输出 JSON；roots 只能从 ${ctx.mountedRootIds} 选择；
          当前时间 ${System.currentTimeMillis()}；不确定的字段省略。
       """.trimIndent()
       val json = myModel.chat(prompt, input)
       decodeSearchQuery(json, ctx)   // 自行实现：JSON → SearchQuery
   }
   viewModel.setQueryParser(parser)
   ```
2. `LlmQueryParser` 自带兜底：模型异常/输出非法时回退字面解析。
3. 执行层无需改动；UI 也无需改动（解析后照常展示）。

## 4. 约束与注意

- **roots 白名单**：解析器只能使用 `SearchContext.mountedRootIds / appRootPath /
  sharedRootPath`，防止模型编造越权路径。
- **相对时间/大小**：由解析器换算成绝对毫秒/字节（"上个月"、"2MB 以上"）。
- **可取消**：解析在 `viewModelScope` 协程中执行，输入变化会取消上一次任务（160ms 防抖）。
- **隐私**：优先本地模型；使用云端模型必须显式告知并取得用户同意，且只发送查询文本，
  不发送文件列表/路径（除非用户明确要求按路径搜索）。
- **性能**：结构化过滤目前是"索引候选 + 客户端过滤"；若未来条件复杂，
  可把 size/mtime/ext 下推到 SQLite WHERE（`entries` 表已存这些列）。

## 5. 已落地的轻量自然语言解析（无模型）

`NaturalLanguageQueryParser`（`apps/android/.../search/NaturalLanguageQueryParser.kt`）
已作为默认解析器接入，离线可用：

| 输入示例 | 解析结果 |
| --- | --- |
| `上个月的照片` | 扩展名=图片集合；修改时间=上个自然月；关键词空 |
| `最近 7 天的截图` | 扩展名=图片；时间=近 7 天；关键词 `screenshot` |
| `大于 10MB 的 pdf` | 扩展名=`pdf`；最小大小=10 MiB |
| `去年的 pptx` | 扩展名=`ppt/pptx`；时间=去年 |
| `海边的照片` | 扩展名=图片；关键词=`海边`（按文件名/拼音匹配） |
| `发票` | 无结构化意图 → 回退字面解析 |

注意：它解析的是**元数据意图**（类型/时间/大小/文件夹），不解析画面内容。
「猫」「海边日落」这类按图像内容搜索需要视觉-语言模型，见下节。

## 6. 图像内容搜索（下一步）

真正按画面内容搜索需要 image-text 对齐模型（CLIP 类）。两条可行路线：

1. **本地中文 CLIP**（推荐）：`Chinese-CLIP` / MobileCLIP 量化 ONNX，首次下载
   约 100–200MB，离线可用；扫描时为图片生成向量存 SQLite，查询文本向量做
   余弦相似度。Android 先落地（ONNX Runtime Mobile），iOS 后续用 Core ML。
2. **云端多模态 embedding**：开发快、支持 PDF/PPTX 文本内容，但需要 API Key、
   联网与隐私告知，违背当前「本地优先」的产品基线。

PDF/PPTX 的内容搜索可先做**文本抽取 + FTS**（PDF 文本层、PPTX XML），成本远低于
视觉模型；在图像语义搜索之后推进。

## 7. 未来扩展点

- 查询解析器可组合（先规则后模型 / 混合）。
- SearchQuery 增加 `tags`、`content`（全文）、`similarTo`（向量检索）等字段。
- 搜索 UI 显示解析结果 chip（如 `类型=PDF · 最近30天`），便于用户确认模型理解是否正确。
