# 配置参考

所有服务端配置都从环境变量读取。`.env.example` 只包含占位值，不能直接用于生产。

## 运行模式

| 变量 | 说明 |
|---|---|
| `LOTTERY_PROVIDER` | `demo` 或 `main-site` |
| `LOTTERY_SITE_URL` | 活动站公开 origin，不带结尾斜杠 |
| `LOTTERY_CAMPAIGN_ID` | 数据库和 provider 共同使用的活动标识 |
| `LOTTERY_TIME_ZONE` | 页面日期显示时区，例如 `Asia/Shanghai` |

## main-site provider

| 变量 | 说明 |
|---|---|
| `MAIN_SITE_URL` | 主站公开 origin |
| `LOTTERY_SSO_AUDIENCE` | 一次性 SSO ticket 的 audience |
| `LOTTERY_BACKEND_SECRET` | 普通数据面网关密钥 |
| `LOTTERY_ADMIN_BACKEND_SECRET` | 只允许准备和开奖的控制面密钥 |

两个网关密钥必须不同。主站和活动站服务端各配置同一对值，浏览器不能读取。

联系方式加密密钥不属于独立活动站配置。它只配置在 `main-site` 主站服务端：

| 变量 | 说明 |
|---|---|
| `LOTTERY_CONTACT_ENCRYPTION_ACTIVE_KEY_ID` | 新报名使用的 key id |
| `LOTTERY_CONTACT_ENCRYPTION_KEYS_JSON` | key id 到 32 字节 base64url 密钥的 JSON；轮换期间可同时保留旧 key |

这组密钥不得使用 `VITE_` 前缀，也不得与两个网关密钥、数据库 service role、会话或开奖密钥复用。生成与轮换步骤见 [联系方式加密](CONTACT_ENCRYPTION.md)。

## 本站会话与运营

| 变量 | 说明 |
|---|---|
| `LOTTERY_SESSION_SECRET` | 派生活动站 session token hash |
| `LOTTERY_SESSION_TTL_SECONDS` | 活动站会话最长有效期 |
| `LOTTERY_DRAW_SECRET` | 活动站 `/api/admin/*` bearer 凭据 |
| `LOTTERY_DRAW_SEED` | 开放参与前固定，开奖后公开 |

生产密钥至少来自 32 个随机字节。不要复用主站 session secret、数据库密钥或 CAPTCHA secret。

## 页面与奖品

`LOTTERY_BRAND_*`、`LOTTERY_HERO_*` 与 `LOTTERY_ENTRY_PREFIX` 控制页面文案。`LOTTERY_PRIZES_JSON` 是最多 8 项的 JSON 数组，每项支持：

```json
{
  "tier": "first",
  "rank": "01",
  "title": "一等奖",
  "description": "奖品说明",
  "icon": "gift",
  "imageUrl": "/prize-placeholder.svg"
}
```

`icon` 只接受 `gift`、`sparkles`、`ticket`。`imageUrl` 可以是 `public` 下的路径或完整 HTTPS CDN URL。部署私有品牌素材时不要把它误提交到公共仓库。

## 联系方式与通知

`LOTTERY_CONTACT_FORMAT` 支持：

- `text`：2–120 个字符；
- `email`：常规邮箱格式，最长 254；
- `qq`：5–12 位且不以 0 开头。

`LOTTERY_NOTIFICATION_REQUIRED=true` 时，用户必须勾选通知渠道确认。通知渠道名称、值和说明由 `LOTTERY_NOTIFICATION_*` 配置。服务端仍会重新验证格式和确认状态。

## CAPTCHA / PoW

`VITE_AUTH_CAPTCHA_MODE` 支持 `off`、`monitor`、`enforce`。生产应使用 `enforce`。Turnstile site key 可以进入浏览器构建，secret 必须留在 provider 后端。国内环境可通过 `VITE_AUTH_CAPTCHA_REGION_STRATEGY=cn-pow` 优先使用 PoW。

`demo` 模式的 PoW challenge 明确标记为演示用途，服务端不把它当成真实反滥用证明。
