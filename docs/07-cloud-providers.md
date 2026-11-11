# 07 · 云存储接入框架（OAuth）

> 状态：**框架已就绪，未接入任何真实云盘**。代码位置：
> `apps/android/app/src/main/java/com/superfiles/app/cloud/`（Kotlin 侧）、
> `crates/vfs-core/src/backends/`（Rust 后端位）。

## 1. 分层

```
┌──────────────────────── Android ────────────────────────┐
│ CloudProviders        静态注册表（id / 名称 / OAuth 端点 / client 凭据）│
│ CloudAuthManager      OAuth2+PKCE 授权、code 交换、自动刷新、登出      │
│ CloudAuthBus          深链总线（superfiles://oauth/callback）        │
│ KeystoreCrypto        AES-256-GCM（密钥在 Android Keystore）         │
│ NetworkSheet          添加云存储 → 选择 provider → 授权 → 已授权态    │
└────────────────────────────┬────────────────────────────┘
                             │ access_token / refresh_token
┌────────────────────────────▼────────────────────────────┐
│ vfs-core Backend（每家一个实现：文件 ID 语义、分页、临时直链、分片上传）│
│ sfiles-ffi  mount_cloud(providerId, accessToken, extras…) │
│ 浏览/搜索/收藏/流式打开：复用现有 UI 与 Provider 机制              │
└─────────────────────────────────────────────────────────┘
```

## 2. 接入一家新云盘的完整步骤

1. **开放平台注册**：拿到 `clientId` / `clientSecret`（是否需要 PKCE、回调白名单以各家文档为准）。
2. **登记 provider**：编辑 `cloud/CloudContracts.kt` 的 `CloudProviders.all`：
   ```kotlin
   CloudProvider(
       id = "aliyun",
       displayName = "阿里云盘",
       endpoints = OAuthEndpoints(authorizationUrl = "...", tokenUrl = "..."),
       scopes = listOf("user:base", "file:all:read"),
       client = OAuthClient(clientId = "…", clientSecret = "…"),   // ← 填这里
       tokenParser = null,                                          // 非标响应再挂钩子
   )
   ```
   填好后 UI 自动从「未配置」变成「点击授权」，无需改界面代码。
3. **Rust 后端**：`crates/vfs-core/src/backends/<provider>.rs` 实现 `Backend` trait
   （`list/stat/read/write/rename/remove/capabilities`；文件 ID ↔ 我们 Entry.id 的映射、
   分页聚合、`dlink` 临时下载地址 + Range、上传 precreate/分片/complete）。
   单测走 mock-server 模式（参考 SMB/WebDAV 的 live matrix 做法）。
4. **FFI 挂载**：`sfiles-ffi` 增加 `mount_cloud(providerId, accessToken, extras)`，
   返回 root id 并注册到 `mounts`；token 过期时用 `refresh_token` 刷新后重试一次。
5. **凭据生命周期**：token 存 `cloud_oauth`（Keystore 加密）；登出 = 删除该项；
   pending 授权会话 30 分钟过期。

## 3. 已内置的通用能力

- OAuth2 授权码 + **PKCE(S256)**（公共客户端安全）
- `state` 校验、`error/error_description` 规范化
- 通用 token 响应解析（`access_token/refresh_token/expires_in`），非标响应可挂 `tokenParser`
- 令牌 `expiresAtMs` 计算 + `refresh()` 接口
- 深链 `superfiles://oauth/callback`（Manifest 已注册，MainActivity 已接）
- 授权成功即持久化；后端接入后可直接 `core.mountCloud(...)` 挂载

## 4. 各家差异备忘

| provider | 端点（示例）| 备注 |
|---|---|---|
| 百度网盘 | `openapi.baidu.com/oauth/2.0/{authorize,token}` | dlink 下载需 `User-Agent: pan.baidu.com`；限速/风控严格 |
| 阿里云盘 | `openapi.alipan.com/oauth/{authorize,access_token}` | file_id 语义；`refresh_token` 长效；下载换临时 URL |
| 123盘 | `open-api.123pan.com/oauth2/{authorize,token}` | 开放平台 API Key 体系，最轻量，建议第一家 |

> 端点与字段以各家开放平台最新文档为准；`CloudProviders` 里的值只是占位骨架。

## 5. 替代方案（零开发）

自建 **Alist/OpenList** 聚合上述云盘并暴露 WebDAV → 直接用本 App 现有的 WebDAV 客户端。
适合先验证产品形态，再决定是否投入原生后端。
