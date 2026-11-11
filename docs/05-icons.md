# 文件图标规范

双端（iOS SF Symbols / Android Material Icons）必须遵循同一张 fallback 链与同一张扩展名表；
新增类型时两端一起改。图标只按**类目 + 高频特化**维护，不做全扩展名覆盖。

## Fallback 链（优先级从高到低）

1. **EntryKind 特判**：directory → folder，symlink → link
2. **扩展名特化表**（见下）：按 `Entry.name` 的小写扩展名查表
3. **MIME 类目**：`Entry.mime` 前缀（`image/`、`video/`、`audio/`、`text/`）
4. **兜底**：generic file

设计原则与 `vfs-core::guess_mime` 一致：图标只支撑 UI 决策，识别不了就走兜底，
绝不画"一年见不到一次"的扩展名图标。发现列表里某类型碍眼再补进特化表。

## 特化表

| 扩展名 | iOS (SF Symbol) | Android (Material) | 备注 |
|---|---|---|---|
| pdf | `doc.richtext` | `PictureAsPdf` | |
| doc, docx | `doc.text.fill` | `Article` | |
| xls, xlsx, csv | `tablecells` | `TableChart` | |
| ppt, pptx | `play.rectangle` | `Slideshow` | |
| zip, rar, 7z, tar, gz, xz, bz2 | `doc.zipper` | `FolderZip` | |
| apk | `shippingbox` | `Android` | |
| exe | `terminal` | `Terminal` | |
| dmg, iso | `opticaldisc` | `DiscFull` | |
| epub, mobi | `book` | `MenuBook` | |
| json, xml, html | `curlybraces` | `Code` | |
| srt, ass, vtt | `captions.bubble` | `Subtitles` | 字幕在视频目录里高频 |
| m3u, m3u8 | `play.rectangle.on.rectangle` | `PlaylistPlay` | 播放列表 |
| ttf, otf, woff, woff2 | `textformat` | `FontDownload` | |
| torrent | `arrow.down.circle` | `Download` | |

## 类目表

| MIME 前缀 | iOS | Android |
|---|---|---|
| `image/` | `photo` | `Image` |
| `video/` | `film` | `Movie` |
| `audio/` | `music.note` | `AudioFile` |
| `text/` | `doc.text` | `TextSnippet` |

## 兜底

| 场景 | iOS | Android |
|---|---|---|
| directory | `folder.fill` | `Folder` |
| symlink | `link` | `Shortcut` |
| unknown file | `doc` | `InsertDriveFile` |

颜色策略：图标位统一为 46×50 r=10「类型徽章」（FileListRow.kt 单源）。按 Figma
首页稿实测特化色：pdf = `#F6ECE8/#B7796E`，xls/xlsx/csv = `#EDF2ED/#6F8D7D`，
doc/docx/txt/md = `#EAF0F8/#466DA6`；目录暖米+暖棕（`#F0EBE3/#A18460`）；
其余文件中性兜底（SurfaceTint/OnSurfaceVariant）；新增特化色先在 tokens.json 登记。
真实缩略图（M4）落地后盖在图标位之上，图标仅当底色/占位。
