# 09 · 语义模型：图像内容检索与跨平台推理接口

> 目标：把「按文件名搜索」升级为「按画面内容搜索」。模型可插拔、运行时（runtime）可插拔，
> 同一套 Rust 代码在 Android / iOS / HarmonyOS 上工作。
>
> 本文记录两件事：
> 1. **可行性实测**：纯 Rust 的 tract 能否跑通中文 CLIP 的 uint8 ONNX（结论：能，但有明确的性能代价）。
> 2. **接口设计**：通用的 `EmbeddingModel` / `InferenceRuntime` / `ModelManifest`，以及存储、下载、
>    SQLite 向量表与检索策略。
>
> 术语：`artifact` = 模型文件本体；`manifest` = 描述 artifact 的元数据；
> `dual-encoder` = 文本塔 + 视觉塔，输出同一向量空间。

---

## 1. 结论摘要（TL;DR）

| 问题 | 结论 |
| --- | --- |
| tract 能加载 `Xenova/chinese-clip-vit-base-patch16` 的 uint8 ONNX 吗？ | **能**。2135 个节点全部有实现（MatMulInteger / DynamicQuantizeLinear / ConvInteger / Erf …）。但必须先把符号维度绑定为具体值，否则 `into_optimized()` 在 `ConvInteger` / `Unsqueeze` 处报符号无法合一。 |
| 数值正确吗？ | 文本塔与 ONNX 参考实现 **cos≈1.0000（max\|Δ\|=6e-8）**；视觉塔 **cos=0.984**；同一图片对 4 条中文提示词的排序完全一致（猫 0.4095 > 狗 0.3552 > 日落 0.3366 > 汽车 0.3300）。 |
| 性能？ | 宿主 x86 单核：文本 52 token **0.55s**、77 token **0.74s**；视觉 224² **1.70s**；合并模型一次图文 **2.45s**。同机 ONNX Runtime 单线程为 **79ms / 257ms**，tract 慢约 **6–7×**。 |
| 内存？ | 峰值 RSS：合并模型 **470MB**，拆分后文本塔 **268MB**、视觉塔 **256MB**（文件本身 190MB，tract 的 plan/常量展开约 2.5×）。 |
| 能上移动端吗？ | 能编译能跑，但**视觉塔索引吞吐是瓶颈**（手机估计 3–7s/张）。建议默认用 **RN50 视觉塔**（FLOPs 约为 ViT-B/16 的 1/4），或对 Android/iOS 增加 ORT 后端。 |
| 跨平台构建？ | `aarch64-linux-android` ✅、`aarch64-unknown-linux-ohos` ✅（需 C/汇编器，tract 的 arm64 kernel 用 NDK clang 通过）、iOS 需 macOS/Xcode（本机无法验证）。 |
| 运行时体积 | tract + ONNX 解析器编进 `cdylib`：**10.5MB/ABI**（LTO + opt-level=z + strip）；不开 LTO 为 19.5MB。 |
| 模型体积 | ViT-B/16：文本 103MB + 视觉 87MB = **190MB**；RN50 估计 **~128MB**。fp16/fp32 不可行（380/750MB）。 |

**推荐路径**：先把通用接口和 tract 后端落地（纯 Rust，一次覆盖三端）；
默认模型用**拆分后的 int8 双塔**；视觉塔优先评估 RN50；若真机实测单张 >3s，
在 Android/iOS 上加 ORT 后端（同一 trait，feature 切换），OHOS 继续用 tract。

---

## 2. 分层架构

```
┌──────────────────────────────────────────────────────────────┐
│ UI (Compose / SwiftUI / ArkTS)                               │
│   SemanticSearchScreen · 索引进度 · 模型下载进度              │
└───────────────▲──────────────────────────────────────────────┘
                │ UniFFI facade（同步方法 + start/poll + cancel）
┌───────────────┴──────────────────────────────────────────────┐
│ crates/semantic                                              │
│                                                              │
│  SemanticSearch  ──uses──▶  ModelStore (下载/校验/版本/布局)   │
│        │                        │                            │
│        │                        ▼                            │
│        │                  ModelManifest (JSON, 带 sha256)     │
│        ▼                                                     │
│  RuntimeRegistry ──select──▶ dyn InferenceRuntime             │
│                                   │ load()                   │
│                                   ▼                          │
│                            dyn EmbeddingModel                 │
│                            ├─ embed_text(&str)               │
│                            └─ embed_image(&DecodedImage)     │
│                                                              │
│  VectorIndex ──▶ SQLite (embeddings 表, 与 entries 同库)      │
└──────────────────────────────────────────────────────────────┘
        │                    │                     │
   tract (纯 Rust)      ONNX Runtime         Core ML / NNAPI
   Android/iOS/OHOS     Android/iOS          可选加速后端
```

关键原则：

- **模型与运行时解耦**：artifact 是标准 ONNX，谁跑都行；`ModelManifest` 不绑定 runtime。
- **平台与运行时解耦**：默认 `tract`；`runtime-ort` / `runtime-coreml` / `runtime-mnn` 是 feature，
  同一份上层代码不改。
- **UI 不感知模型家族**：只认 `ModelKind` 与 `Capabilities`，换模型不改 UI。

---

## 3. Rust 接口

### 3.1 Manifest

```rust
// crates/semantic/src/manifest.rs
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum ModelKind {
    /// 双塔：文本与图像映射到同一向量空间（CLIP 类）
    DualEncoder,
    /// 纯文本 embedding（bge / m3e）
    TextEmbedding,
    /// 纯图像 embedding（相似图、去重）
    ImageEmbedding,
    /// 版面/文字识别，输出文本后走 FTS
    Ocr,
    /// 重排（cross-encoder），对候选精排
    Rerank,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Modality { Text = 1, Image = 2 }

bitflags::bitflags! {
    pub struct Capabilities: u32 {
        const TEXT        = 1 << 0;
        const IMAGE       = 1 << 1;
        const MULTIMODAL  = Self::TEXT.bits() | Self::IMAGE.bits();
        const BATCH       = 1 << 2;
    }
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ModelManifest {
    pub id: String,                 // "chinese-clip-vit-b16-int8"
    pub version: String,            // "2026-11-1"（语义化或日期）
    pub kind: ModelKind,
    pub embedding_dim: u32,         // 512
    pub normalized: bool,           // true → 余弦 = 点积
    pub license: String,            // "Apache-2.0"（发布前需核实上游）
    pub min_runtime: MinRuntime,
    pub tokenizer: Option<TokenizerSpec>,
    pub image: Option<ImageSpec>,
    pub artifacts: Vec<Artifact>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Artifact {
    pub role: ArtifactRole,         // TextModel / ImageModel / Tokenizer / Vocab / Config
    pub file: String,               // 相对模型目录的文件名
    pub sha256: String,
    pub bytes: u64,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct TokenizerSpec {
    pub kind: TokenizerKind,        // BertWordPiece
    pub vocab: String,              // "vocab.txt"
    pub lowercase: bool,            // true
    pub cjk_char_split: bool,       // true
    pub max_tokens: u32,            // 52（中文 CLIP 默认）
    pub cls: String,                // "[CLS]"
    pub sep: String,                // "[SEP]"
    pub pad: String,                // "[PAD]"
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ImageSpec {
    pub size: u32,                  // 224
    pub resize: ResizeMode,         // ShortestSideThenCenterCrop
    pub mean: [f32; 3],             // CLIP 均值
    pub std: [f32; 3],
    pub layout: PixelLayout,        // NCHW / RGB
}

#[derive(Debug, Clone, Copy)]
pub struct MinRuntime { pub tract: &'static str, pub ort: &'static str }
```

Manifest 随 artifact 一起下载，但**不要信任下载到的 manifest**：内置一份 registry
（`models.json` 编进二进制或随 app 发布），用内置的 sha256 校验，manifest 只用于读取参数。

### 3.2 模型与运行时 trait

```rust
// crates/semantic/src/runtime.rs
pub struct DecodedImage {
    pub width: u32,
    pub height: u32,
    /// RGBA8，row-major，由平台解码（Android Bitmap / iOS CGImage / OHOS PixelMap）
    pub rgba: Vec<u8>,
    pub exif_orientation: u16,
}

// 图像解码：JPEG/PNG/WebP 用纯 Rust 的 `image` crate（三端可用、无系统依赖）；
// HEIC/RAW 走平台 API（Android ImageDecoder / iOS ImageIO / OHOS ImageSource），
// 解出 RGBA 后传进来。EXIF 方向在进模型前归一化（旋转/镜像）。

pub struct Embedding {
    pub model_id: String,
    pub model_version: String,
    pub modality: Modality,
    pub dim: u32,
    /// 已归一化（manifest.normalized=true 时）
    pub values: Vec<f32>,
}

pub struct LoadOptions {
    /// 只加载需要的那一塔，移动端内存减半
    pub role: ModelRole,            // TextOnly / ImageOnly / Both
    pub threads: u8,                // tract 目前恒为 1；留给 ORT
    pub max_tokens: u32,
}

pub trait EmbeddingModel: Send + Sync {
    fn manifest(&self) -> &ModelManifest;
    fn capabilities(&self) -> Capabilities;

    fn embed_text(&self, text: &str) -> Result<Embedding>;
    fn embed_image(&self, image: &DecodedImage) -> Result<Embedding>;

    fn embed_text_batch(&self, texts: &[String]) -> Result<Vec<Embedding>> {
        texts.iter().map(|t| self.embed_text(t)).collect()
    }
    fn embed_image_batch(&self, images: &[DecodedImage]) -> Result<Vec<Embedding>> {
        images.iter().map(|i| self.embed_image(i)).collect()
    }
}

pub trait InferenceRuntime: Send + Sync {
    /// "tract" / "ort" / "coreml" / "mindspore" / "mnn"
    fn id(&self) -> &'static str;
    fn supports(&self, artifact: &ModelManifest) -> bool;
    /// 同步加载：调用方负责放到后台线程（与现有 FFI 约定一致）
    fn load(&self, dir: &Path, manifest: &ModelManifest, opts: &LoadOptions)
        -> Result<Box<dyn EmbeddingModel>>;
}

/// 编译期注册；运行期按优先级挑选第一个 supports() 的实现
pub struct RuntimeRegistry { runtimes: Vec<Box<dyn InferenceRuntime>> }
impl RuntimeRegistry {
    pub fn platform_default() -> Self { /* cfg!(feature = "runtime-ort") ... */ }
    pub fn load(&self, dir: &Path, m: &ModelManifest, o: &LoadOptions)
        -> Result<Box<dyn EmbeddingModel>>;
}
```

设计取舍：

- **trait 留在 Rust，不导出到 UniFFI**。UniFFI 0.32 能导出 trait interface，但那会把
  "选哪个 runtime / 怎么加载" 复制到 Kotlin、Swift、ArkTS 三份代码里。
  FFI 只暴露一个小门面 `SemanticSearch`，平台侧零逻辑。
- `embed_*` 用 `&self`：tract 的 `RunnableModel::run(&self)` 本身可重入；
  ORT 的 session 也是线程安全的。模型实例由索引线程独占持有，不跨线程共享。
- `LoadOptions.role` 让"查询走文本塔、索引走视觉塔"变成两个进程内实例，
  避免同时驻留两塔（470MB → 260MB）。

### 3.3 UniFFI 门面（与现有 `SuperFiles` 风格一致：同步 + start/poll + cancel）

```rust
#[derive(uniffi::Record)]
pub struct SemanticHit {
    pub entry_id: String,
    pub score: f32,          // 余弦，[-1, 1]
    pub modality: Modality,
}

#[derive(uniffi::Enum)]
pub enum InstallState { NotInstalled, Downloading { done: u64, total: u64 },
                        Verifying, Ready, Failed { reason: String } }

#[derive(uniffi::Object)]
pub struct SemanticSearch { /* ModelStore + RuntimeRegistry + Index */ }

#[uniffi::export]
impl SemanticSearch {
    #[uniffi::constructor]
    pub fn open(app_data_dir: String, index_path: String) -> Result<Arc<Self>, SfError>;

    pub fn models(&self) -> Vec<ModelInfo>;                  // 内置 registry + 安装状态
    pub fn install_state(&self, model_id: String) -> InstallState;

    pub fn start_install(&self, model_id: String);           // 后台线程下载/校验
    pub fn cancel_install(&self);

    pub fn start_index(&self, roots: Vec<String>, model_id: String); // 扫描图片 → 向量
    pub fn index_progress(&self) -> IndexProgress;           // done / total / skipped / failed
    pub fn cancel_index(&self);

    pub fn search(&self, query: String, limit: u32) -> Result<Vec<SemanticHit>, SfError>;
}
```

`search` 内部：`embed_text(query)` → 与 `embeddings` 表做点积 → top-K → join `entries` 返回。
文本塔加载是懒加载（首次搜索时），并在后台预热。

---

## 4. 存储、下载与索引

### 4.1 目录布局（三端一致，由 app 传入 `app_data_dir`）

```
<app_data>/semantic/
  models/
    chinese-clip-vit-b16-int8/
      2026-11-1/
        manifest.json
        text.onnx          103 MB
        vision.onnx         87 MB
        vocab.txt          110 KB
        .complete          安装完成标记（原子 rename 落盘）
      2026-11-1.part/      下载中（可断点续传）
  # 向量表在现有 index.sqlite 里（同一库，join entries 才便宜）
```

- **Android**: `context.filesDir/semantic`（无需存储权限）
- **iOS**: `Library/Application Support/semantic`（不要放 Documents，避免 iCloud 备份 190MB；
  需要设置 `NSURLIsExcludedFromBackupKey`）
- **OHOS**: `context.filesDir/semantic`

### 4.2 下载与校验

1. 内置 registry 给出 URL 列表（可多镜像）、`bytes`、`sha256`。
2. `GET` 到 `.part`，`Range: bytes=<已下载>-` 续传；流式写盘同时更新 sha256。
3. 完成后校验 sha256 → `fsync` → 原子 `rename` 目录 → 写 `.complete`。
4. 失败保留 `.part`，下次续传；超过 N 次或校验失败则删除重下。
5. 首启可选"随包内置"（Android Asset Delivery / iOS on-demand resources），逻辑不变。

网络层复用 workspace 已有的 `reqwest + rustls`，不引入新依赖。

### 4.3 SQLite schema（追加到 `crates/index`，`user_version` 升到 2）

```sql
CREATE TABLE IF NOT EXISTS semantic_models (
    id           TEXT NOT NULL,
    version      TEXT NOT NULL,
    kind         TEXT NOT NULL,
    dim          INTEGER NOT NULL,
    installed_ms INTEGER NOT NULL,
    PRIMARY KEY (id, version)
);

CREATE TABLE IF NOT EXISTS embeddings (
    entry_id        TEXT    NOT NULL,
    model_id        TEXT    NOT NULL,
    model_version   TEXT    NOT NULL,
    modality        INTEGER NOT NULL,          -- 1=text 2=image
    vec             BLOB    NOT NULL,          -- f16 LE, dim*2 字节
    source_size     INTEGER NOT NULL,          -- 失效判断
    source_mtime_ms INTEGER NOT NULL,
    created_ms      INTEGER NOT NULL,
    PRIMARY KEY (entry_id, model_id, model_version, modality)
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS idx_embeddings_model
    ON embeddings(model_id, model_version, modality);

CREATE TABLE IF NOT EXISTS embedding_failures (
    entry_id   TEXT NOT NULL,
    model_id   TEXT NOT NULL,
    reason     TEXT NOT NULL,
    failed_ms  INTEGER NOT NULL,
    PRIMARY KEY (entry_id, model_id)
);
```

要点：

- **向量不进 FTS、不建索引**：SQLite 没有向量索引；BLOB 全表扫 + Rust 里算点积，
  在移动端规模下足够快（见下）。
- `entry_id` 用现有 `entries.id`（root 前缀的 URI），删文件时级联清理（扫描后
  `DELETE FROM embeddings WHERE entry_id NOT IN (SELECT id FROM entries)`）。
- `source_size/mtime` 用于增量：文件变了才重算；否则跳过。
- `embedding_failures` 防止坏图/超大图无限重试。
- 换模型不删旧向量（`model_id/version` 区分），可回滚；超出预算再按 LRU 清理。

### 4.4 检索策略与容量估算

模型输出已 L2 归一化（实测 norm=1.0），所以**余弦相似度 = 点积**：

```
score = Σ vec_q[i] * vec_d[i]     // f16 反量化到 f32 后累加
```

| 图片数 | f16 向量体积 | 全表扫（含 SQLite 读） | 结论 |
| --- | --- | --- | --- |
| 1 万 | 10 MB | ~10–30 ms | 直接扫 |
| 5 万 | 50 MB | ~50–150 ms | 直接扫，可接受 |
| 20 万 | 200 MB | ~0.5–1.5 s | 按目录/时间分片，或引入 HNSW |
| 100 万 | 1 GB | 秒级 | 需要 ANN（sqlite-vec / 自建 HNSW），不在本期 |

实现细节：

- 用 `PRAGMA cache_size` 与 `mmap_size` 提升 BLOB 读性能；查询只 `SELECT entry_id, vec`，
  流式遍历，不把整表读进内存。
- top-K 用固定大小堆（K=limit*2），再做一次 f32 重排可选。
- 结构化过滤（roots、扩展名、时间）先压到 SQL 的 `JOIN entries ... WHERE`，再算向量，
  避免对全库算相似度。
- 相似图去重：同一张表，`modality=image`，查询向量来自本地图片。

---

## 5. tract 可行性实测

环境：Intel i7-10700KF（8C/16T，AVX2），Linux x86_64，Rust 1.99.1，
`tract-onnx 0.23.10`，Python 3.12 + onnx 1.23.2 + onnxruntime 1.31.1。
探针工程：`/tmp/opencode/tract-probe`（**未进仓库**）。
模型：`/tmp/opencode/cc/model_uint8.onnx`（Xenova `onnx/model_uint8.onnx`，
190,213,447 B，sha256 `af7e63ff…e0416107`，opset 14，2135 nodes，733 initializers）。

### 5.1 算子覆盖

| 算子 | 数量 | tract |
| --- | --- | --- |
| Mul / Add / Cast | 407 / 321 / 148 | ✅ |
| MatMulInteger | 146 | ✅（优化为 `OptMatMul` / `OptMatMulPack`，走 int8 kernel） |
| DynamicQuantizeLinear | 99 | ✅（`DynamicQuantizeLinearU8`） |
| ConvInteger | 1 | ✅（patch embedding） |
| ReduceMean / Sub / Pow / Sqrt / Div | 102 / 52 / 55 / 51 / 77 | ✅ |
| Erf / Softmax / Gather / Transpose | 12 / 24 / 104 / 111 | ✅ |
| DequantizeLinear | 3 | ✅ |

结论：**没有缺失算子**，不需要删除或重写任何量化算子。问题不在算子，在形状。
（因此也没有尝试 fp32/fp16 降级：体积会到 380–750MB，移动端不可行；uint8 本身已被原生支持。）

### 5.2 实际阻塞点与修复

直接把 `model_for_path()` 的结果交给 `into_optimized()` 会失败，依次遇到两个符号维度问题：

```
# 1) ConvInteger（视觉 patch embedding）
Failed analyse for node #650 "/vision_model/embeddings/patch_embedding/Conv_quant" ConvHir:
Applying rule inputs[0].shape[1] == 1*{inputs[1].shape[1]}:
Impossible to unify Sym(num_channels) with Val(3).

# 2) Unsqueeze（文本 attention mask 路径）
Failed analyse for node #648 "/text_model/Unsqueeze_3" Unsqueeze13:
Unifying shapes text_batch_size,1,1,sequence_length and 1,1,1,77:
Impossible to unify Sym(text_batch_size) with Val(1).
```

原因：导出的图里 `Shape/Gather/Unsqueeze` 常量路径按 batch=1 固化，而输入声明的是符号维度
（`text_batch_size`、`image_batch_size`、`num_channels`、`height/width`），tract 的符号推理
不能把 `Sym` 与常量合一。**修复：加载后、`into_optimized()` 前，把符号绑成实际形状**：

```rust
let mut model = tract_onnx::onnx().model_for_path(path)?;

let mut subs: HashMap<Symbol, TDim> = HashMap::new();
for (name, val) in [
    ("text_batch_size", 1i64), ("image_batch_size", 1),
    ("sequence_length", 52),  ("num_channels", 3),
    ("height", 224),          ("width", 224),
] {
    if let Ok(TDim::Sym(sym)) = model.symbols.parse_tdim(name) {
        subs.insert(sym, val.to_dim());
    }
}
model.set_symbols(&subs)?;                       // InferenceModelExt

// 再补具体的 input fact（i64[1,52] × 2 / f32[1,3,224,224]）
model = model.with_input_fact(0, i64::fact([1, 52]).into())?;
model = model.with_input_fact(1, f32::fact([1, 3, 224, 224]).into())?;
model = model.with_input_fact(2, i64::fact([1, 52]).into())?;
let runnable = model.into_optimized()?.into_runnable()?;
```

绑定后 `into_optimized()` 成功（3777 个 plan 节点）。**这两步是 tract 集成必须写的样板代码**，
不是可选优化。

### 5.3 加载与推理耗时（宿主，warm cache）

| 阶段 | 合并模型 | 文本塔 | 视觉塔 |
| --- | --- | --- | --- |
| `model_for_path`（解析+类型） | 135 ms | 70 ms | 65 ms |
| `into_optimized` | 2.10–2.20 s | 0.70 s | 0.66 s |
| `into_runnable` | 2.7 ms | 1.4 ms | 1.3 ms |
| 推理 | **2.45 s**（1 图 + 1 文本@77） | **0.74 s**（77 tok）/ **0.55 s**（52 tok） | **1.70 s**（224²） |
| 文本 batch=4 @77 | — | 2.67 s（≈0.67 s/条） | — |
| 峰值 RSS | **470 MB** | 268 MB | 256 MB |

拆分后单塔加载 ~0.7s、内存减半；合并模型还会算用不到的 `logits_per_image/text`，属于浪费。

### 5.4 数值验证（对照 ONNX ReferenceEvaluator）

| 输入 | 余弦（tract vs 参考） | 备注 |
| --- | --- | --- |
| 4 条真实中文提示词（一只猫 / 一辆汽车 / 一只狗 / 海边的日落） | **≈1.0000**（max\|Δ\|=6e-8） | 文本塔数值等价 |
| 真实猫图 224² | **0.984** | int8 视觉塔的正常量化噪声 |
| 随机图片 | 0.990 | — |
| 随机 token ids | 0.971 | 分布外输入，忽略 |

端到端（tract 输出，已归一化）：

```
一只猫    +0.4095     参考实现 +0.4085
一只狗    +0.3552               +0.3559
海边的日落 +0.3366               +0.3411
一辆汽车   +0.3300               +0.3315
```

排序完全一致，最大偏差 0.005，**可以用于召回**。

### 5.5 与 ONNX Runtime 的差距（同机、同一模型）

| 项 | tract | ORT (1 intra-op thread) | ORT (默认线程) |
| --- | --- | --- | --- |
| 文本 52 tok | 550 ms | **79 ms** | 20 ms |
| 视觉 224² | 1700 ms | **257 ms** | 68 ms |
| 建会话/优化 | 0.66–0.70 s（单塔） | 0.12–0.17 s | 同左 |

tract 默认单线程（依赖里没有 rayon），数值正确但 kernel 不如 MLAS 精细，**慢 6–7×**。
这是选型时最重要的数字：它决定了"索引 1000 张图"是 15 分钟还是 2 小时。

### 5.6 其他实测结论

- **plan 缓存不可用**：`tract-nnef` 序列化在 `DynamicQuantizeLinearU8` 处失败
  （`No serializer found for node … DynamicQuantizeLinearU8`）。所以没有"预编译模型"可发，
  每次冷启动都要付 0.7s/塔 的优化时间（手机上估计 2–4s）。可接受，但要放在后台线程并预热。
- **iOS 无法在本机验证**：tract-linalg 的 build.rs 调用 `xcrun`，需要 macOS + Xcode。
- **无外部 C 依赖**：除了 tract-linalg 自带的 arm64 `.S`/`.c` kernel，运行时不需要 OpenCV、
  protobuf、onnxruntime 等 C/C++ 库。

---

## 6. 模型选型与移动端估算

### 6.1 候选

| 模型 | 文本塔 | 视觉塔 | int8 合计 | 视觉 FLOPs@224 | 中文 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| Chinese-CLIP ViT-B/16 | BERT-base 102M | ViT-B/16 86M | **190 MB** | ~17.6 G | ✅ | **已实测跑通**，质量最好 |
| Chinese-CLIP RN50 | BERT-base 102M | ResNet50 25M | **~128 MB** | ~4.1 G | ✅ | 视觉快 ~4×，需自行导出 ONNX |
| Taiyi-CLIP-RoBERTa-102M | RoBERTa-102M | 需配 ViT-L/H | ≥300 MB | 更大 | ✅ | 视觉塔太大，不适合端侧 |
| MobileCLIP (S0/S1) | 小 | 小 | ~50 MB | ~1–2 G | ❌ 英文 | 中文查询不可用 |
| 云端多模态 embedding | — | — | 0 | — | ✅ | 需联网/Key/隐私告知，违背本地优先 |

> 注：Chinese-CLIP ViT-B/16 的 HF 模型卡未声明 license（上游 GitHub 仓库为 Apache-2.0），
> 发布前需核实并在「关于」页做 Attribution。

### 6.2 移动端估算（**估算，非实测**）

假设手机大核比本机单核慢 2–4×（NEON dotprod vs AVX2、内存带宽、降频）：

| 路径 | 单张视觉 | 1000 张索引 | 单次文本查询 |
| --- | --- | --- | --- |
| tract + ViT-B/16 | 3.4–6.8 s | 1–2 h | 1.1–2.2 s |
| tract + RN50 | 0.8–1.7 s | 13–28 min | 1.1–2.2 s |
| ORT + ViT-B/16 | 0.5–1.0 s | 8–17 min | 0.16–0.32 s |

结论：

1. **文本塔延迟由 BERT-base 决定**，换视觉模型救不了；1–2s 的查询等待需要 UI 兜底
   （防抖 + loading + 可取消）。
2. **索引吞吐看视觉塔**。tract + ViT-B/16 不可接受；tract + RN50 勉强可用（后台任务 +
   充电/Wi-Fi 约束）；ORT + ViT-B/16 最好。
3. 真机数字必须实测后再定；本表只用于排除明显不可行的组合。

### 6.3 建议

- **默认 artifact**：拆分双塔 int8（`text.onnx` + `vision.onnx`），保留合并模型作为调试用。
- **默认 runtime**：`tract`（纯 Rust，一套代码三端，构建最简单）。
- **默认视觉塔**：先上 ViT-B/16 打通链路（已验证）；同时导出 RN50 做 A/B，
  用 200 张图片的人工标注集比较 top-1 命中率与耗时，再决定默认值。
- **逃生舱**：若真机 >3s/张，Android/iOS 切 `runtime-ort`（feature flag），OHOS 继续 tract；
  接口不变，只换 `RuntimeRegistry` 的默认实现。

---

## 7. 跨平台构建注意

### Android

- `cargo ndk -t arm64-v8a -o app/src/main/jniLibs build --release`
- NDK r27；tract-linalg 的 build.rs 需要 `CC_aarch64-linux-android` / `AR`（arm64 NEON/dotprod kernel）。
  已验证 `cargo check --target aarch64-linux-android` 通过。
- Android 15 起要求 16KB page size：链接参数加 `-C link-arg=-Wl,-z,max-page-size=16384`。
- minSdk 24；`cdylib` 10.5MB/ABI（LTO + opt-level=z + strip），建议只发 `arm64-v8a`。
- 模型不进 APK（190MB 超 Play 限制）：首次运行下载，或 Play Asset Delivery。

### iOS

- `cargo build --target aarch64-apple-ios --release`，`staticlib` + `uniffi-bindgen-swift`。
- 必须在 macOS + Xcode 上构建（tract-linalg build.rs 走 `xcrun`，本机无法验证）。
- `-C link-arg=-dead_strip`；模型放 Application Support 并排除 iCloud 备份。
- App 审核：模型是"可下载内容"，需在 UI 说明体积与用途。

### HarmonyOS (OHOS)

- `rustup target add aarch64-unknown-linux-ohos`（rust-std 可从 rsproxy 镜像安装）。
- `cargo build --target aarch64-unknown-linux-ohos --release`，产物 `libsuperfiles.so`，
  由 DevEco 的 NAPI 模块加载。
- **已验证 `cargo check` 通过**：tract-linalg 的 arm64 kernel 需要 C/汇编器；
  用 OHOS SDK 的 clang（或 NDK clang + `--sysroot` 指向 ohos/NDK sysroot）即可。
  纯 Rust 部分不需要任何系统库。
- 这是选择 tract 的核心理由：**OHOS 没有官方发布的 ONNX Runtime 包**
  （只能用社区移植，或改用 MindSpore Lite 并接受第二套运行时/模型格式），
  而 tract 是唯一"一套 Rust 代码三端通吃"的方案。

### 构建矩阵

| target | 状态 | 说明 |
| --- | --- | --- |
| `x86_64-unknown-linux-gnu` | ✅ 跑通 | 本文所有性能/精度数字 |
| `aarch64-linux-android` | ✅ `cargo check` + 链接 cdylib | NDK r27 |
| `aarch64-unknown-linux-ohos` | ✅ `cargo check` | rust-std + clang sysroot |
| `aarch64-apple-ios` | ⚠️ 需 macOS | 本机无法验证 |

---

## 8. 风险与未决问题

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| tract 视觉塔慢 6–7× | 索引 1000 张要 1–2h | RN50；或 ORT 后端；索引限后台+充电 |
| 峰值内存 470MB（合并）/ 260MB（单塔） | 4GB 机型可能被 LMK 杀 | 拆分双塔、按需加载、索引完释放视觉塔 |
| 无 plan 缓存（NNEF 不支持量化算子） | 冷启动 2–4s/塔 | 后台预热；首屏不阻塞；加载进度 UI |
| 模型 190MB 下载失败/中断 | 首次体验差 | 断点续传 + 多镜像 + 可选内置 |
| int8 视觉塔 cos≈0.984（vs 参考实现） | 召回略降 | 已实测排序不变；必要时对 top-K 用 fp32 重排 |
| 模型 license 未声明 | 合规 | 发布前核实上游；关于页 Attribution |
| `entries.id` 变化（换根/重命名） | 向量成孤儿 | 扫描后按 `entries` 清理；entry_id 用稳定 URI |

未决：

- RN50 的 ONNX 尚未导出/验证（exports 需要 `optimum-cli export onnx --model OFA-Sys/chinese-clip-rn50`，
  再用 `onnxruntime.quantization.quantize_dynamic` 量化）；导出后要重跑本文 5.3/5.4 的验证。
- 是否需要 OCR（PDF/PPTX）：本期先做文本抽取 + FTS，模型接口留 `ModelKind::Ocr` 占位。
- 文本塔能否换更小的中文模型（如 bge-small-zh）与现有视觉塔对齐？不行——
  双塔必须成对训练，不能混搭。

---

## 9. 下一步（按顺序）

1. **接口落地**：新建 `crates/semantic`（manifest / traits / registry / store / vector index），
   先只实现 `tract` 后端；`crates/index` 加 schema v2。
2. **产物准备**：用 `onnx.utils.extract_model` 拆出 `text.onnx` / `vision.onnx`
   （本文已验证），附 `vocab.txt`，算 sha256，写进内置 registry。
3. **Rust 分词器**：BERT WordPiece + CJK 逐字切分（vocab 21k，~150 行），
   与 Python `tokenizers` 对齐 20 条样例；避免引入 `tokenizers`（其 esaxx C++ 依赖会污染三端构建）。
4. **端到端 demo**：索引 500 张图 → 搜索"猫/海边/发票" → 记录 P@10 与耗时；
   同时在真机（Android）跑一次 5.3 的计时。
5. **模型决策**：导出 RN50，按 4 的同一批图对比质量/耗时，确定默认视觉塔。
6. **（条件触发）ORT 后端**：若真机 >3s/张，加 `runtime-ort` feature，仅 Android/iOS 启用。
7. **UI**：搜索框增加"按内容搜索"开关 + 索引进度/模型下载卡片；结果复用 `FileListRow`，
   副标题显示相似度。

---

## 附录：复现命令（探针在 /tmp，未提交）

```bash
# 1) 拆分双塔（Python）
python3 - <<'PY'
import onnx
m = '/tmp/opencode/cc/model_uint8.onnx'
onnx.utils.extract_model(m, '/tmp/opencode/cc/text_uint8.onnx',
                         ['input_ids', 'attention_mask'], ['text_embeds'])
onnx.utils.extract_model(m, '/tmp/opencode/cc/vision_uint8.onnx',
                         ['pixel_values'], ['image_embeds'])
PY

# 2) tract 加载/优化/推理（Rust 探针）
cd /tmp/opencode/tract-probe
cargo run --release -- /tmp/opencode/cc/vision_uint8.onnx bench
cargo run --release -- /tmp/opencode/cc/text_uint8.onnx  bench

# 3) 交叉编译检查
NDK=$HOME/Android/Sdk/ndk/27.0.11718014/toolchains/llvm/prebuilt/linux-x86_64/bin
CC_aarch64-linux-android=$NDK/aarch64-linux-android24-clang \
  cargo check --release --target aarch64-linux-android
cargo check --release --target aarch64-unknown-linux-ohos   # rust-std + clang sysroot
```

> 探针源码要点：`src/main.rs` 里的 `bind_symbols()` + `with_input_fact()` 是 tract 跑通该模型的
> 最小修复；`src/lib.rs` 验证了 tract 可编进 `cdylib`（移动端形态）。
>
> 参考实现用的 `onnx.reference.ReferenceEvaluator` 不支持 opset 14 的 `DequantizeLinear`，
> 对比时把 `text_uint8.onnx` 的 `opset_import` 临时改到 19（语义相同的子集），
> 视觉塔无需修改。
