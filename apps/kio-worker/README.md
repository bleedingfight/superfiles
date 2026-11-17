# KIO worker（Dolphin 集成）

把 super-files 的内核（vfs-core 的 local/WebDAV/SMB/SFTP 后端）暴露为 KDE 的
`superfiles://` 协议：Dolphin / Konqueror / KFileDialog 地址栏输入
`superfiles:///`，即可像本地目录一样浏览所有已配置的存储、打开和复制文件。

这是 Android `DocumentsProvider` / iOS `File Provider`（M2 路线项）在 Linux
桌面上的对位物——同一份 Rust 内核，只加一层薄壳。

## 架构

```
Dolphin ──(KIO)── kio_superfiles.so ──(spawn)── sfiles kio … ── vfs-core
                C++ 薄壳，只做 JSON/协议转换         内核一切：sanbox、列目录、读
```

- C++ worker 不链接内核，全部功能通过 `sfiles kio mounts/ls/stat/cat`
  （crates/sfiles-cli/src/kio.rs）的行式 JSON IPC 完成；内核保持 100% Rust。
- 本地存储 = 与移动端相同的 jailed `LocalBackend`；远端 = 相同的 WebDAV/SMB/SFTP
  后端，经 `Vfs::mount_at` 前缀挂载，与 FFI `mount_webdav/smb/sftp` 同路径。
- URL 映射：`superfiles:///label/rest` → 名为 label 的挂载的 root_id + rest。
  根 `superfiles:///` 是虚拟目录：每个挂载一个文件夹（改配置后刷新根目录即生效）。

## 安装

```bash
just kio          # = ./scripts/install-kio.sh
```

构建并安装：

- `~/.local/bin/sfiles`（release CLI）
- KIO worker 插件：用户目录 + `/usr/lib/qt6/plugins/kf6/kio/`

> KF6 只在写死的系统插件目录里发现 KIO worker（`QT_PLUGIN_PATH` 对 worker
> 发现无效），所以脚本最后需要一次 `sudo` 把 .so 复制进系统目录；升级时
> 重跑 `just kio` 即可，`sfiles` 与配置不受影响。

## 挂载配置

`~/.config/superfiles/mounts.json`（可用 `SF_CONFIG` 覆盖路径），格式见
`mounts.example.json`：

```json
{
  "storages": [
    { "label": "Home",   "type": "local",  "root": "/home/liushuai" },
    { "label": "123pan", "type": "webdav", "base_url": "https://…", "username": "…", "password": "…" },
    { "label": "NAS",    "type": "smb",    "server": "192.168.31.10", "share": "Media" }
  ]
}
```

配置缺失/为空时回退为只挂一个 jail：`$HOME`（label `Home`）。

## 状态与边界（M0）

- [x] 浏览（listDir/stat/mimetype）、打开与复制（get），本地与 WebDAV/SMB/SFTP
- [x] 根目录即时反映配置变化（换 mount 表 = 重新 listDir 根目录）
- [x] 内核错误原样透传（`error:` → KIO 错误弹窗）
- [ ] open/read/seek 流式随机访问（目前 get 一次性流下载；视频流可走 `sfiles serve`）
- [ ] 写路径（put/mkdir/rename/delete → vfs 对应 API 已在内核就绪）
- [ ] 搜索入口（sfiles search 已可用，可做 superfiles-search:// 或 Dolphin 搜索服务）
- [ ] places 面板收录（可选：user-places 书签）

## 冒烟测试（无需 GUI）

```bash
sfiles kio mounts                                   # 注册表 JSON
sfiles kio ls "$(printf '%s' "$HOME")/super-files"  # 内核 id 列目录
kioclient stat 'superfiles:///Home'                 # 经 KIO 全链路
QT_PLUGIN_PATH=~/.local/lib/qt6/plugins kioclient ls 'superfiles:///'
```
