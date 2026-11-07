# 设计系统 v0 —— 双端基准

目的：**一份基准，多端忠实实现**。统一的是变量与组件状态表，不是交互行为——
iOS 用 HIG 手势（swipe 删除）、Android 用 Material 语义（trailing 按钮）、TV 用焦点遍历，
这些**平台正确性高于表面一致性**。

工具路径：当前阶段**仓库即基准**（本文 + tokens 表）；人员和屏幕变多之后再上
Figma Variables → Style Dictionary 导出双端常量。校验终将靠
Paparazzi（Android）/ swift-snapshot-testing（iOS）**同 spec 截图**（M5 前引入）。

## 1. 色彩

不自建色板：Android 用 Material You 动态取色（`Theme.kt` 已接），iOS 用系统
accent + 语义色。语义角色两端必须同义使用：

| 用途 | 角色 |
|---|---|
| 目录图标、主操作（FAB）、链接态 | `primary` / `.accentColor` |
| 文件名 | `onSurface` / `.primary` |
| 次要信息（尺寸、日期、mime） | `onSurfaceVariant` / `.secondary` |
| 弱化提示（chevron、空态图标） | `outline` / `.tertiary` |
| 危险操作（删除） | `error` / `.red` |
| 只读标记（未来 badge） | `tertiary` / `.orange` |

深色模式：不写死颜色就不破（已遵守）；TV 用高对比 M3 深色，不做动态取色自定义（墙取色在电视上不可靠）。

## 2. 间距刻度（4 基栅）

只允许取以下值（`Dimens` 常量抽取待办，见 §7）：

| token | dp 或 pt | 典型用途 |
|---|---|---|
| `space-1` | 4 | 文字行内微调 |
| `space-2` | 8 | 空态元素间距、垂直紧凑留白 |
| `space-3` | 12 | FileRow 图标–文字间距 |
| `space-4` | 16 | 屏幕左右安全边距、搜索框外距 |
| `space-6` | 24 | 分组间隔（预留） |
| `space-8` | 32 | 段落级空白（预留） |

FileRow 图标槽固定 **28**（iOS `.frame(width: 28)`；Android 对齐同值）。

## 3. 字号

平台体系字阶，不自定义大小：

| 用途 | Android M3 | iOS |
|---|---|---|
| 文件名/标题行 | `bodyLarge` | `.body` |
| 次信息（尺寸·日期） | `bodySmall` / `bodyMedium` | `.caption` |
| AppBar 标题 | `titleLarge` | `.headline`（inline displayMode） |
| 空态主文案 | `titleMedium` | `.headline` |
| 空态辅文案 | `bodySmall` | `.footnote` |
| 底部状态栏 | `labelSmall` | `.caption2` |

## 4. 组件状态表（V0 已存在组件）

### FileRow（列表行）

| 状态 | 表现（双端一致规则） |
|---|---|
| 默认 | 图标(28) + 名称(单行省略) + 次信息；目录图标 primary、文件 onSurfaceVariant |
| 按下/触摸 | 平台原生（iOS 高亮、Android ripple），**无自定义态** |
| TV 聚焦 | 边框 primary 2dp + 背景 surfaceVariant + `scale=1.00`（**不允许缩放**，列表会抖动）；M5 细化 |
| 隐藏文件 | 名称 alpha 0.6（未实现，待 M1 批量功能一起） |
| 只读 | 名称后 `lock` 小图标（未实现，随只读分享一起） |
| 可点性 | **仅目录可下钻**；文件行点击进入是 M1「播放/预览」待接 |

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

## 7. 现状差距（v0 → 待办）

- [x] `Dimens.kt` / `Spacing.swift` 常量抽取（FileRow/搜索框/空态已接入；2/6pt 两个栅格外数值保留待设计决策）
- [ ] FileRow 隐藏/只读态渲染（依赖 M1 功能）
- [ ] TV 焦点样式与 D-pad 走查（M5）
- [ ] 截图回归（Paparazzi / swift-snapshot-testing）接入 `just check`
- [ ] Figma Variables 化（团队 >1 个设计师时）
