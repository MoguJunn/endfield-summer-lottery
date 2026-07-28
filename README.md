# Open Lottery

一个可配置、可复算、支持身份适配器的社区抽奖活动站。前端使用 React/Vite，服务端 API 可部署到 Vercel；当前提供无需外部账号系统的演示 provider，以及复用既有主站账号和 Supabase 数据库的 `main-site` provider。

本项目采用 [Apache License 2.0](LICENSE) 开源。你可以在遵守许可证条款的前提下使用、修改和分发项目源码；第三方依赖、字体及部署者自行注入的品牌素材仍遵循各自许可证或授权条件。

## 已有能力

- 活动名称、主视觉、时区、奖品、联系方式、通知渠道和编号前缀均由环境变量配置；
- `demo` provider 单仓库即可体验登录、PoW、参与幂等和结果页面；
- `main-site` provider 使用一次性 SSO ticket，不共享 Cookie、密码或长期 token；
- PoW 与 Cloudflare Turnstile 可按网络环境切换；
- 每个身份每期只生成一条有效参与记录；
- `main-site` 适配器在入库前使用 AES-256-GCM 加密联系方式，并支持按 key id 轮换；
- 领奖联系方式不会进入公开活动快照、参与编号、中奖名单或开奖复算材料；
- 浏览器响应经过显式字段白名单，provider 多返回的私有字段不会被透传；
- 普通数据网关使用独立密钥，准备/开奖只接受主站短期管理员身份；
- SSO、报名和私有网关动作使用 PostgreSQL 原子共享限流，多实例部署不会各自重置计数；
- 开奖采用预先承诺的私有种子与固定 drand Quicknet 公共随机源，服务端和浏览器均使用固定链公钥验证 BLS 签名，并公开候选清单供复算；
- 亮暗主题、移动端布局、键盘焦点和减少动效偏好。

## 五分钟体验

要求 Node.js 22.17 LTS，或 Node.js 24–26；npm 10 或更高版本。Node.js 23 不在工具链支持范围内。

```bash
npm ci
npm run dev:demo
```

打开 `http://localhost:5175`，点击“登录活动账号”即可创建临时演示会话。演示数据只保存在当前 Node 进程内，重启后清空，不连接主站或数据库，也不适合生产使用。

服务器运行时可在另一个终端执行 `npm run demo:check`，自动验证登录、PoW、参与、私密字段白名单和重复参与幂等。

## 开发检查

```bash
npm run lint
npm test
npm run build
# 或一次运行全部检查
npm run check
```

首次运行 `npm run local:e2e` 会下载经过校验的 Supabase CLI 并启动本地实例；之后可额外执行数据库断言：

```bash
npm run db:test
```

## 两种 provider

| provider | 用途 | 外部依赖 | 生产可用 |
|---|---|---|---|
| `demo` | 体验 UI、贡献前端、验证基础流程 | 无 | 否 |
| `main-site` | 接入已有账号、会话和 Supabase 数据库 | 受信任主站网关 | 需要完成生产验收 |

provider 边界位于 `api/_lib/provider.js`。浏览器只调用本站同源 API，不知道身份与数据具体来自哪里。内部网关契约版本为 `1`，字段白名单位于 `api/_lib/contracts.js`。

## 配置

复制 `.env.example` 为 `.env.local`，然后按 [配置参考](docs/CONFIGURATION.md) 填写。生产环境至少需要分别生成：

- `LOTTERY_SESSION_SECRET`：本站会话；
- `LOTTERY_BACKEND_SECRET`：活动站到主站的普通用户数据面。

这两个值必须彼此不同，且每个值至少来自 32 个随机字节。`LOTTERY_DRAW_SEED` 只配置在主站服务端；准备与开奖通过主站短期管理员会话执行，活动站不再持有 seed 或运营 Bearer 凭据。不要把 `.env`、日志、数据库导出或领奖联系方式提交到仓库。

## 主站集成

`main-site` provider 需要主站实现三个接口：

- `GET /api/summer-lottery-sso/start`
- `POST /api/summer-lottery-backend`
- `POST /api/auth-pow-challenge`

数据库迁移 `supabase/migrations/160_create_summer_lottery.sql` 依赖主站的 `auth.users`、`profiles` 和 `app_sessions`，因此它是“主站适配器迁移”，不是独立 Supabase 初始化脚本。接口、动作、鉴权和字段契约见 [主站适配器](docs/MAIN_SITE_ADAPTER.md)。

Windows 本地完整集成流程仍可使用：

```powershell
npm run local:e2e
npm run local:e2e:check
npm run local:e2e:draw
npm run local:e2e:verify
npm run local:e2e:stop
```

这套流程要求相邻位置提供兼容的主站源码，并要求 Docker Desktop；普通贡献者只需使用 `npm run dev:demo`。

## 隐私与公平性

联系方式是私密运营数据。`main-site` 适配器会在入库前生成 AES-256-GCM 信封；兑奖只允许超级管理员单条审计读取，模板默认在计划开奖 30 天后停止读取并由每日任务清除在线密文。部署前仍必须把期限改成活动规则承诺的准确时间，并建立备份过期策略。详见 [隐私说明](docs/PRIVACY.md) 与 [联系方式加密](docs/CONTACT_ENCRYPTION.md)。

当前 `main-site` provider 固定 drand Quicknet 链哈希、RFC9380 scheme 和 G2 公钥；服务端在开奖写库前验证 round、randomness 和 BLS12-381 签名，浏览器对公示快照离线执行同样验证。生产限制见 [生产就绪清单](docs/PRODUCTION_READINESS.md)。

## 项目状态

当前版本是 `0.1.0` 初始开源版：演示模式、配置边界、接口白名单、联系方式静态加密、单条兑奖审计、数据保留自动化、drand BLS 验证、CI、Apache-2.0 许可证和治理文件已具备；通用 OIDC adapter、独立兑奖角色和独立生产数据库仍在路线图中。

参与贡献前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md) 与 [SECURITY.md](SECURITY.md)。
