# Super Files 产品站

自包含静态站点（`index.html` + `ios.mp4` 实机演示视频，无构建依赖、
无站外资源），配色直接取自 `design/tokens.json`（Figma「superfiles」基线）。

`ios.mp4` 由 iPad 录屏（2732×2048@120fps HEVC，4 分 41 秒）剪掉播放器起播黑屏段后，
转 H.264（1600×1200@30fps，CRF 25，~25MB），页面以
`<video autoplay muted loop playsinline>` 内联循环播放。

## 本地预览

```bash
cd website
python3 -m http.server 8000
# 打开 http://localhost:8000
```

直接双击 `index.html` 也能打开（无跨域资源）。

## 部署（GitHub Pages）

仓库 `.github/workflows/pages.yml` 已在推送 `website/**` 变更时自动部署：

1. 首次启用：GitHub 仓库 **Settings → Pages → Source** 选 **GitHub Actions**。
2. 推送后 Actions 跑完即可访问 `https://<用户名>.github.io/super-files/`。

站内指向 `docs/`、`design/` 的链接使用 GitHub 仓库 blob 地址（Pages 站点根
只有 `website/` 一个目录，相对路径会 404）。
