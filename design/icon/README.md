# Super Files · 图标

概念「叠页」：三页文档绕底部轴心 ±9° 扇形展开、逐级提亮，前页端正居中，
暖米白 + 右上折角。配色全部取自 `../tokens.json`：
底板 `#5A87B9 → #466DA6 → #39597F` 纵向渐变，前页 `#FCFBF8 → #F0ECE2`（surface 系），
折角 `#E2D3B4`（primaryWarm 的浅暖版）。

| 文件 | 用途 |
|---|---|
| `superfiles.svg` | 主图标（1024×1024，r=228 ≈ iOS squircle，「叠页」方向） |
| `superfiles-bolt.svg` | **当前 Android 程序图标**（bolt×S 徽章方向，参考 superfiles-icons/sbadge，配色同 tokens） |
| `superfiles-mono.svg` | 单色标志：透明底、默认 `#466DA6`（根元素 `fill` 改一处即换色），README 页眉 / CLI / 水印 |

导出 PNG（按需改尺寸；Android 自适应图标直接引用 SVG 作 foreground 亦可）：

```bash
rsvg-convert -w 1024 -h 1024 superfiles.svg -o superfiles-1024.png   # App Store / 桌面
rsvg-convert -w 512  -h 512  superfiles.svg -o superfiles-512.png    # Play
rsvg-convert -w 128  -h 128  superfiles-mono.svg -o mono-128.png
```

注意：`superfiles.svg` 底板自带圆角，用于 Android 自适应图标时建议把底板改为满幅
（去 rx），把叠页组 `scale` 降到 ~0.66 放进安全区；需要时再加一份 `superfiles-adaptive.svg`。
