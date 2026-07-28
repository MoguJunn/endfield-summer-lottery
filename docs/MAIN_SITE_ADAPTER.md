# main-site provider 契约

## 版本

私有网关请求必须携带：

```json
{
  "version": 1,
  "action": "snapshot",
  "payload": {}
}
```

不支持的版本应返回 `gateway_contract_version_unsupported`，不能静默猜测字段。

## 鉴权

- `snapshot`、`exchange`、`enter`、`logout`、`health` 使用 `LOTTERY_BACKEND_SECRET`；
- 私有网关不接受 `prepare`、`draw`；这两个动作只允许主站短期管理员会话调用同源管理 API；
- 私有网关使用 `Authorization: Bearer <secret>`，只接受 POST，并实现共享限流。

## 动作

`snapshot` 输入可选 `sessionTokenHash`，输出活动、公开参与数据和当前用户状态。不得输出联系方式、原始 token、邮箱或私有种子。

`exchange` 输入 ticket/state/session/CSRF hash、audience 和过期时间。ticket 必须原子消费并绑定源主站 session。

`enter` 输入 session/CSRF hash、`contactType`、`contactValue`、通知确认、CAPTCHA token 或 PoW proof。provider 必须先验证明文格式与机器人证明，再在调用数据库 RPC 前把联系方式转换成 `olc1` AES-256-GCM 信封。网关响应不得返回明文或密文联系方式。

`logout` 撤销服务端活动 session；失败时活动站不会只清 Cookie 假装成功。

主站同源接口 `/api/admin-summer-lottery-operations` 使用短期超级管理员身份、Origin 校验、活动级确认词和共享限流执行 `prepare` / `draw`。`LOTTERY_DRAW_SEED` 只配置在主站；数据库事务 wrapper 将 actor 与操作写入不可修改的审计，并且不记录 seed。

## SSO

主站 `GET /api/summer-lottery-sso/start?state=...` 必须：

1. 检查自己的 host-only session；
2. 生成至少 32 个随机字节的一次性 ticket；
3. 数据库只保存 ticket/state hash；
4. ticket 绑定 audience、user 和源 session，短期过期；
5. 使用活动站 URL fragment 返回 ticket 与 state；
6. 原子拒绝重放。

活动站不会接收主站密码、OAuth token 或 Supabase access token。

## 数据库

迁移 160 是当前 Supabase/PostgreSQL adapter；迁移 161 为已应用旧版迁移的数据库收紧联系方式约束；迁移 162 增加联系方式保留期限、追加式访问审计、单条读取/删除与到期清理 RPC；迁移 163 增加 SSO 与私有网关动作的原子共享限流；迁移 164 撤销旧 prepare/draw RPC 的 service role 权限，并增加绑定管理员 actor 的事务审计 wrapper；迁移 165 增加按活动授权的 `contact_read` / `contact_purge` capability、授权变更审计，并撤销可绕过 capability 的旧联系方式 RPC。参与 RPC 只接受版本化加密信封，拒绝明文。`service_role` 只能直接读取 entry 的安全元数据，不能绕过审计选择 `contact_value`、枚举限流摘要、伪造兑奖 actor 或执行未审计开奖。第三方实现其他数据库时应保持同等事务与保密语义，而不是照搬 PostgreSQL 异常文本作为公开协议。

限流 identifier 必须先在主站服务端使用 HMAC 匿名化；数据库拒绝原始 IP，只保留固定窗口计数和 64 位摘要约 48 小时。限流配置由数据库维护，私有网关调用方不能临时放大预算。

联系方式加密 keyring 只配置在主站服务端，不能发送给活动站或数据库。配置和轮换流程见 [联系方式加密](CONTACT_ENCRYPTION.md)。

主站管理接口 `/api/admin-summer-lottery-contacts` 接受主站有效会话，但必须持有目标活动的显式 capability：列表与单条解密需要 `contact_read`，单条隐私删除需要 `contact_purge`；全局 `super_admin` 不自动继承。超级管理员通过 `/api/admin-summer-lottery-permissions` 授予或撤销，并由数据库写入授权审计。兑奖人员使用 `/lottery-contacts`（移动端 `/m/lottery-contacts`），不能进入完整超级管理员后台或执行开奖。定时接口 `/api/summer-lottery-contact-retention` 由 Vercel Cron 使用 `CRON_SECRET` 每日调用，不向浏览器公开密文。
