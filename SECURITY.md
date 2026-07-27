# 安全政策

## 支持范围

当前只维护最新的默认分支。`demo` provider 仅用于本地体验，不接受“缺少生产级持久化或鉴权”类报告；如果演示能力可以在 `main-site` 模式被意外启用，则属于有效安全问题。

## 私下报告

请不要在公开 Issue 中披露可利用的漏洞、密钥、个人联系方式或生产数据库信息。请使用仓库托管平台的 Private Vulnerability Reporting；若仓库尚未启用该功能，请联系维护者并只发送最小复现信息。

报告建议包含：

- 受影响版本或提交；
- 触发条件和最小复现；
- 可观察到的影响；
- 你已经采取的保密措施；
- 可选的修复建议。

请勿访问不属于你的账号、扩大数据读取范围、执行真实开奖、修改生产数据或造成服务中断。

## 敏感数据范围

以下内容一律按敏感信息处理：

- `LOTTERY_*_SECRET`、`LOTTERY_DRAW_SEED` 和 provider 高权限凭据；
- 原始 SSO ticket、session token、CSRF token 和 OAuth 凭据；
- 联系方式、未脱敏用户名和数据库导出；
- 开奖前的 seed reveal；
- 主站 service role、数据库连接串和备份。

## 当前已知限制

- `main-site` provider 已加密联系方式，并提供单条访问审计与自动删除任务；兑奖入口目前仍使用主站 `super_admin`，尚未拆分独立最小权限角色；
- drand Quicknet 链哈希、scheme 与 G2 公钥固定在服务端和浏览器验证模块中；round、`SHA-256(signature) = randomness` 与 RFC9380 BLS12-381 签名均需通过；
- 抽奖 SSO 与私有网关已使用 PostgreSQL 原子共享限流；数据库不可用或响应异常时敏感动作会失败关闭；
- 运营接口仍使用长期 bearer secret，虽已和普通数据网关分离，但尚未接入短期管理员身份和完整审计日志。

这些限制不能作为未授权测试生产环境的许可。
