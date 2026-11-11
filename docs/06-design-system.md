# 设计系统 v0 —— 双端基准

目的：**一份基准，多端忠实实现**。统一的是变量与组件状态表，不是交互行为——
iOS 用 HIG 手势（swipe 删除）、Android 用 Material 语义（trailing 按钮）、TV 用焦点遍历，
这些**平台正确性高于表面一致性**。

工具路径：当前阶段**仓库即基准**（本文 + tokens 表）；人员和屏幕变多之后再上
Figma Variables → Style Dictionary 导出双端常量。校验终将靠
Paparazzi（Android）/ swift-snapshot-testing（iOS）**同 spec 截图**（M5 前引入）。

## 1. 色彩

**品牌基线以 Figma「superfiles」稿实测值为准**（`design/tokens.json` 是唯一机器可读真相源）：
暖米白底 `#F8F7F4`、墨色 `#292E35`、次色 `#777D86`、弱化 `#A4A8AE`、卡片 `#FFFFFF`、
信息卡 `#EAF0F8`。运行时 Android 仍跟随 Material You、iOS 跟随系统 accent——
基线色只作 Figma 摆稿与动态取色不可用场景的回退。语义角色两端必须同义使用：

| 用途 | 角色 |
|---|---|
| 目录图标、主操作（FAB）、链接态 | `primary`（演示值 `#466DA6`，**决策①待定**，备选暖棕 `#A18460`） |
| 文件名 | `onSurface`（`#292E35`） |
| 次要信息（尺寸、日期、mime） | `onSurfaceVariant`（`#777D86`） |
| 弱化提示（chevron、空态图标） | `outline`（`#A4A8AE`） |
| 危险操作（删除） | `error` |
| 在线/成功态（ServerCard 状态点） | `success`（`#6F8D7D`） |
| 只读标记（未来 badge） | `tertiary` / `.orange` |

深色模式：`tokens.json` `color.dark` 段已有 **v0.2 派生草案**（从浅色基线同语义角色
反相得到；Android 随系统夜间模式生效），Figma 正式深色稿出来后按稿校准；
TV 用高对比深色，不做动态取色自定义（墙取色在电视上不可靠）。

## 2. 间距刻度（4 基栅）

只允许取以下值（Figma 稿里的 5/7/13 均属 AI 噪点，已 snap 进栅）：

| token | dp 或 pt | 典型用途 |
|---|---|---|
| `space-1` | 4 | 文字行内微调 |
| `space-2` | 8 | 空态元素间距、垂直紧凑留白 |
| `space-3` | 12 | FileRow 图标–文字间距 |
| `space-4` | 16 | 组件内 padding |
| `space-6` | 24 | **屏幕左右安全边距**（Figma 实测；`safe-margin` 语义别名） |
| `space-8` | 32 | 段落级空白（预留） |

FileRow 图标槽固定 **28**（iOS `.frame(width: 28)`；Android 对齐同值）。
FileRow 标准行高 74（名称 14w500 + 元信息 10w400 两行自洽）。

## 2.5 圆角

| token | dp | 用途 |
|---|---|---|
| `radius-s` | 10 | 芯片 / 排序器 / 小卡 |
| `radius-m` | 14 | 常规卡片（文件夹、详情预览） |
| `radius-l` | 20 | 主卡（用量卡） |
| `radius-pill` | 999 | 搜索框 / chip / CTA |

## 3. 字号

字栈 `Noto Sans SC → PingFang SC → system-ui`（中文优先；数字允许 Inter/系统数字字）：

| 用途 | 规格 |
|---|---|
| AppBar 标题 | 17 w700 |
| 文件名 | **14 w500**（Figma 实测；74 行高自洽，高于平台默认列表密度） |
| 次信息（尺寸·日期·mime） | 10 w400 |
| 分组标题（我的文件夹/最近打开） | 12 w500 |
| 空态主/辅文案 | 15 w500 / 13 w400 |
| 底部状态栏 | 10 w400 |

Android 实现落在 M3 体系对应位阶上（允许 ±1pt 对齐平台字阶）；超出此表的新字
级需先在 `design/tokens.json` 登记。

## 4. 组件状态表（V0 已存在组件）

### FileRow（列表行）

| 状态 | 表现（双端一致规则） |
|---|---|
| 默认 | 图标(28) + 名称(单行省略) + 次信息；目录图标 primary、文件 onSurfaceVariant |
| 按下/触摸 | 平台原生（iOS 高亮、Android ripple），**无自定义态** |
| TV 聚焦 | 边框 primary 2dp + 背景 surfaceVariant + `scale=1.00`（**不允许缩放**，列表会抖动）；M5 细化 |
| 隐藏文件 | 名称 alpha 0.6（未实现，待 M1 批量功能一起） |
| 只读 | 名称后 `lock` 小图标（未实现，随只读分享一起） |
| 可点性 | **仅目录可下钻**；文件单击 = 系统默认程序打开（MIUI/原生消歧逻辑），打不开时从「⋯」用「打开方式」强选；M1「播放/预览」内嵌后单点优先走内嵌 |

### 列表容器（方案 A，2026-11 起）

文件浏览页、首页「我的收藏 / 最近打开 / 我的网络存储」统一：**一组一张白色圆角卡**
（`radius-m`），卡内行保持平铺（FileRow 74dp），行间 0.5dp 发丝线，起点缩进 74
（`space-4` 行内边距 + 46 徽章 + `space-3`）。长列表用「首/末行圆角、中间直角」实现
**滚动卡片**——列表短时卡自然收在最后一行，不出现固定高度面板的空白。

- **不要逐行圆角卡**：同质文件流逐行卡片会双层圆角（徽章 r10 + 行 r14）、且一屏少看约 15% 文件。
- 选择器/对话框内的候选列表同一套语言，行高压缩到 56、徽章 40、发丝线缩进 68。

### 对话框（品牌风）

容器 `surface`（暖底 `#F8F7F4`）+ `radius-l`；内容用白卡（`surfaceCard`）分组，
标题 17 w700、辅助/路径 12 `onSurfaceVariant`、正文 14 w500、次信息 11。
主操作实心 `primary` + 白字（`radius-s`），次操作纯文字 `onSurfaceVariant`；
不使用 M3 默认 `AlertDialog` 的紫色容器与全大写按钮。

### AppBar + SearchField

- 标题单行省略（middle truncate iOS / ellipsis Android）。
- 搜索框常驻于 AppBar 下方（当前 M0 形态），`space-4` 外边距，leading icon。
- M1 起会换成「点击放大镜展开」的 M3 SearchBar praat；布局语义不变。

### FAB（索引入口）

extended FAB：图标 + 文案（`建立索引` / `索引 N 项`）。State = idle | running(进度) | error(走 Snackbar)。

### 删除确认

平台原生：iOS `confirmationDialog` / Android `AlertDialog`。文案统一模板：「确定删除「{name}」？」。

### EmptyState

垂直居中：40pt 弱化图标 + `.headline` 主文案 + `.footnote/.bodySmall` 辅文案，间距 `space-2`。

### ProgressOverlay

`CircularProgressIndicator` / `ProgressView` 居中覆盖，不打断手势（非模态）。

## 5. TV 焦点模型（合同）

- 一切可交互元素必须可通过 D-pad 顺序到达（Compose `focusable()`/SwiftUI `focusSection()`），无「鼠标专有点」。
- 焦点样式唯一合法组合：**primary 边框 + surfaceVariant 背景**；禁止缩放（滚动抖动）、禁止阴影（低端机会卡）。
- 安全区 overscan 5%：内容容器整体 inset，Android 用 `android:clipChildren=false` + 平台默认边距。
- 遥控器长按 = 打开上下文菜单（等价桌面右键）；M5 落地。

## 6. 平台差异白名单（**允许**不同的清单，其余必须一致）

| 项 | iOS | Android |
|---|---|---|
| 删除手势 | swipe actions | 行尾按钮（将来长按 menu） |
| 返回 | 左上 chevron + 右滑 | 左上箭头 + 物理返回键 |
| 取色 | 静态系统蓝（默认） | Material You 动态取色 |
| 刷新手势 | `refreshable` 下拉 | 同语义（M1 加） |

## 7. 自适应布局（横屏 / 大屏）

断点实现在 `apps/android/.../ui/AdaptiveLayout.kt`，iOS 待 M2 跟进：

| 断点 | 判定 | 布局 |
| --- | --- | --- |
| Compact | width < 600dp | Figma 单列，首页 480dp 限宽居中 |
| Medium | 600–840dp | 首页双列（左：问候/用量/本地存储；右：网络/收藏/最近） |
| Expanded | ≥ 840dp | 首页双列（总宽 ≤ 984dp 居中）；文件列表 840dp 限宽居中 |
| 矮窗 | height < 480dp（横屏手机） | 底部导航 → `NavigationRail` |

合同：

- 竖屏（< 600dp）像素级沿用 Figma 稿，禁止重排；
- 宽窗只做「重排 + 限宽」，不放大字号与间距（tokens 不变）；
- 可读宽度：首页单列 480dp、详情单列 640dp、列表/表单 840dp、首页双列 984dp、详情双列 1040dp；
- 矮窗或 Expanded 下必须用侧栏导航，把高度还给内容（横屏手机底栏约占 20% 高度）；
- 详情页宽窗「左预览 / 右信息」双列；底栏按钮与内容同宽居中；
- 对话框统一 560dp 上限；收藏 / 我的 / 传输中心 / 近邻传输 / 网络存储表单按 840dp 限宽居中。

## 8. 现状差距（v0 → 待办）

- [x] `Dimens.kt` / `Spacing.swift` 常量抽取（FileRow/搜索框/空态已接入；2/6pt 两个栅格外数值保留待设计决策）
- [x] Android 横屏/大屏自适应（首页双列 + 侧栏导航 + 列表限宽；竖屏不变）
- [ ] FileRow 隐藏/只读态渲染（依赖 M1 功能）
- [ ] TV 焦点样式与 D-pad 走查（M5）
- [ ] 截图回归（Paparazzi / swift-snapshot-testing）接入 `just check`
- [ ] Figma Variables 化（团队 >1 个设计师时）
