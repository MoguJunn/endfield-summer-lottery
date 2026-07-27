# 架构

## 请求边界

```text
浏览器
  │ 同源 API、host-only Cookie、CSRF + Origin
  ▼
Open Lottery API
  │ provider 接口
  ├─ demo：进程内用户、会话和参与记录
  └─ main-site：版本化私有 HTTP 网关
       │ 格式验证、机器人验证、AES-256-GCM 加密
       │ service role（只传递版本化联系方式密文）
       ▼
     Supabase / PostgreSQL
```

浏览器只接触本站 API。`api/_lib/provider.js` 选择 provider，`api/_lib/contracts.js` 将 provider 返回值转换为公开字段白名单。不得在路由中使用 `{ ...snapshot }` 直接透传上游对象。

## 会话

`main-site` 模式中，主站签发短期一次性 ticket，并把 ticket 放在回调 URL fragment。活动站浏览器清除 fragment 后通过同源 POST 交换；数据库只接收 ticket 和 state 的 SHA-256 hash。活动站创建自己的 session 与 CSRF Cookie，不读取主站 Cookie。

`demo` 模式直接在本站创建临时 session。所有 demo 用户代表同一个固定身份，数据随 Node 进程销毁。

## 数据面与控制面

- 普通数据面：`snapshot`、`exchange`、`enter`、`logout`、`health`，使用 `LOTTERY_BACKEND_SECRET`；
- 运营控制面：`prepare`、`draw`，使用不同的 `LOTTERY_ADMIN_BACKEND_SECRET`；
- 活动站自己的运营入口再使用 `LOTTERY_DRAW_SECRET`；
- 所有密钥都只存在于服务端。

## 多实例共享限流

抽奖 SSO 与私有网关动作调用迁移 163 提供的 PostgreSQL 原子固定窗口 RPC。主站按动作选择请求 IP 或活动 session 摘要作为预算主体，再使用对应网关密钥做 HMAC；数据库只接收 64 位匿名摘要，不保存原始 IP、Cookie 或 token。计数在所有 Vercel 实例间共享，过期窗口抽样清理并最长保留约 48 小时；数据库或 RPC 异常时敏感动作失败关闭。

## 联系方式加密边界

浏览器和独立活动站把明文联系方式通过受保护的同源与私有网关链路提交给主站。主站在格式与机器人验证通过后，使用独立 keyring 生成 `olc1` AES-256-GCM 信封，再调用数据库 RPC。数据库约束拒绝明文，快照、开奖和健康检查均不读取该字段。

当前主站网关持有对称加密 keyring。兑奖入口只允许单条解密并先写入审计，不提供批量导出；到期任务会清除在线密文。入口目前仍使用主站 `super_admin`，后续应拆出独立最小权限角色；需要进一步隔离时应使用支持“只允许加密”权限的 KMS。详细格式与轮换见 [联系方式加密](CONTACT_ENCRYPTION.md)。

## 开奖

开放参与前，运营方通过 `prepare` 保存 `SHA-256(LOTTERY_DRAW_SEED)`。开奖时读取固定公共随机轮次，对每个有效 `public_id` 计算排序 hash。开奖 RPC 在事务中锁定活动、写入中奖者并保存公开复算材料，相同参数可幂等重试。

公共随机源固定为 drand Quicknet。服务端在写入开奖结果前、浏览器在复算公示快照时，都会使用固定链哈希、RFC9380 scheme 和 G2 公钥离线验证 BLS12-381 签名；relay HTTPS 只承担传输，不再是随机源真实性的信任根。

## 数据库所有权

现有迁移是 `main-site` adapter 的共享数据库实现，依赖 `auth.users`、`profiles` 和 `app_sessions`。`demo` provider 不使用这些表。未来独立 Supabase Auth 或 OIDC provider 应实现自己的身份映射和存储 adapter，不应伪造主站表结构。
