# 生产就绪清单

当前仓库可用于开发演示和继续集成，但默认配置不代表已经适合处理真实用户数据或真实奖品。

## 发布阻塞项

- [x] 选择 Apache License 2.0 并加入标准 `LICENSE`；
- [ ] 确认所有品牌图片、字体和文案可再分发；
- [x] 为 `main-site` 联系方式实现 AES-256-GCM 应用层静态加密与 key id 轮换；
- [x] 实现联系方式保留期限、每日删除任务和管理员单条访问审计；
- [ ] 将兑奖权限从主站 `super_admin` 拆分为独立最小权限角色；
- [x] 使用固定 Quicknet 链公钥验证 drand BLS 签名与 round；
- [x] 将抽奖敏感入口的内存限流替换为 PostgreSQL 原子共享限流；
- [x] 移除活动站长期运营 Bearer 入口，改用主站短期管理员身份与事务审计；
- [ ] 增加真实浏览器 E2E，覆盖 OAuth、跨浏览器 state、ticket 重放和并发参与；
- [ ] 建立数据库备份、恢复、迁移失败回滚和 secret 轮换流程；
- [ ] 完成隐私政策、活动规则、领奖期限和联系方式删除承诺。

## 部署前检查

- [ ] `LOTTERY_PROVIDER` 明确为 `main-site`，生产拒绝 `demo`；
- [ ] 活动站 session/data secret 与主站 draw seed 彼此不同且至少 32 随机字节；
- [ ] 联系方式 active key 指向有效的独立 32 字节密钥，旧 key 仅在历史数据仍需解密时保留；
- [ ] `contact_retention_until` 与活动规则中的领奖期限一致，且 `CRON_SECRET` 已配置；
- [ ] 活动 ID、数据库时间、页面时区和奖品数量一致；
- [ ] Turnstile 域名、site key、secret 和 PoW 签名密钥已配置；
- [ ] SSO Cookie 均为 host-only，生产使用 Secure；
- [ ] 普通网关对 `prepare`、`draw` 返回 `action_not_allowed`，活动站 `/api/admin/*` 返回 404；
- [ ] 主站管理员操作要求有效短期身份、Origin 和精确活动确认词，并产生不可修改审计；
- [ ] 迁移 163 已应用，SSO、报名和运营动作能返回数据库生成的 `Retry-After`；
- [ ] 公开快照不包含联系方式、邮箱、内部角色或源 session；
- [ ] prepare 在第一条参与记录产生前成功，commitment 已保存；
- [ ] 生产环境日志、错误追踪和告警均会清除 token 与联系方式；
- [ ] 已确认每日联系方式清理任务成功，并为失败结果设置告警；
- [ ] 已演练开奖失败后的安全重试，但没有提前执行真实开奖。

## 当前安全声明

固定链公钥验证能证明公示 beacon 来自指定 drand Quicknet 链，但不能消除运营方在活动配置、候选资格、私有 seed 保管和部署完整性方面的信任。其他发布阻塞项完成前，项目不应宣传为“无需信任运营方”。
