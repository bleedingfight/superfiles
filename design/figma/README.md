# Figma 原型导出（参考稿）

来源文件：[`superfiles`](https://www.figma.com/design/XmoFjt7I62SXghkgpAPHrP/superfiles)
（file key `XmoFjt7I62SXghkgpAPHrP`，最后修改 2026-11-07T16:03:32Z）

2026-11-08 通过 Figma REST API 导出（`GET /v1/images`，PNG @2x，804×1800）：

| 文件 | Figma Frame | node-id |
|---|---|---|
| `01-首页-栖档.png` | 首页 · 栖档 | `2:3507` |
| `02-文件浏览-山屿品牌.png` | 文件浏览 · 山屿品牌 | `2:3613` |
| `03-搜索-山屿.png` | 搜索 · 山屿 | `2:3718` |
| `04-文件详情-山屿品牌提案.png` | 文件详情 · 山屿品牌提案 | `2:3817` |

重新导出：

```bash
curl -4 -H "X-Figma-Token: $FIGMA_TOKEN" \
  "https://api.figma.com/v1/images/XmoFjt7I62SXghkgpAPHrP?ids=2:3507,2:3613,2:3718,2:3817&format=png&scale=2"
```

注意：本机 DNS 对 `api.figma.com` 的 AAAA 记录有污染，必须 `curl -4` 走 IPv4。

## 与 `screens.md` 清单的差异（2026-11-08 快照）

- 已有稿：首页、文件浏览、搜索、文件详情（均为 iOS 风格单端稿，402×900）
- 未画：冲突对话框、传输中心、设置（M1 批）；连接向导、我的连接、远端浏览（M2 批）；TV 两屏
- 清单外的额外产出：首页（用量卡 + 文件夹卡 + 最近打开）、搜索（关键词高亮 + 过滤 chip）、文件详情（预览卡 + 元信息 + 标签 + 操作区）
- 原型中的 App 命名为「栖档」，示例数据品牌为「山屿」
