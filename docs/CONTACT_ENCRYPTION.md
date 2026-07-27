# 联系方式加密与密钥轮换

`main-site` 适配器在联系方式通过格式校验和机器人验证后、调用数据库 RPC 前，使用 AES-256-GCM 加密。独立活动站、浏览器和数据库不持有明文解密密钥。

## 加密信封

数据库保存版本化字符串：

```text
olc1.<key-id>.<12-byte-iv>.<ciphertext>.<16-byte-auth-tag>
```

IV、密文和认证标签均使用无填充 base64url。活动 ID、联系方式类型和用途版本作为 GCM 附加认证信息，不写入密文；密文被复制到其他活动或更换类型后无法通过认证。

数据库迁移同时校验信封格式并拒绝明文，但它不负责解密，也不能证明任意格式正确的信封一定使用受信密钥生成。密码学认证在主站服务端解密时完成。

## 主站配置

只在主站服务端配置：

```dotenv
LOTTERY_CONTACT_ENCRYPTION_ACTIVE_KEY_ID=contact-2026-01
LOTTERY_CONTACT_ENCRYPTION_KEYS_JSON={"contact-2026-01":"<32 字节随机值的 base64url>"}
```

生成新密钥：

```bash
node --input-type=module -e "import { randomBytes } from 'node:crypto'; console.log(randomBytes(32).toString('base64url'))"
```

要求：

- 每个值解码后必须正好 32 字节；
- key id 只使用 1–32 位字母、数字、下划线或连字符；
- active key id 必须存在于 keyring；
- 不得复用网关、会话、开奖、数据库或 CAPTCHA 密钥；
- 不得添加 `VITE_` 前缀，也不得提交到仓库、日志或客户端配置。

配置缺失或非法时，参与接口返回稳定的 503，并且不会调用写入 RPC。

## 轮换步骤

1. 生成新 32 字节密钥；
2. 将新 key id 和密钥加入 `LOTTERY_CONTACT_ENCRYPTION_KEYS_JSON`，暂时保留旧 key；
3. 将 `LOTTERY_CONTACT_ENCRYPTION_ACTIVE_KEY_ID` 切换到新 key id 并部署；
4. 验证新报名信封携带新 key id，旧报名仍可在受控流程中解密；
5. 在旧数据已经重新加密、删除，或其备份全部过期后，才移除旧 key。

随机 IV 使相同联系方式产生不同密文，不能通过比较密文去重。当前参与幂等键仍是“活动 + 用户”。如未来需要联系方式检索，应单独设计带密钥的盲索引及泄露评估。

## 旧明文升级

迁移 `161_require_encrypted_lottery_contacts.sql` 检测到旧明文时会停止并返回 `unencrypted_summer_lottery_contacts_require_manual_migration`。

- 仅有本地测试数据时，停止服务并重置本地数据库；
- 已有真实数据时，先停止报名写入，通过不记录明文的受信任一次性任务逐行加密，再重新执行迁移；
- 不要为通过迁移而伪造 `olc1` 前缀，也不要把明文导出到普通 CSV、Issue、聊天或构建日志。

## 尚未覆盖

当前代码没有领奖联系方式读取接口。后续若实现解密，应使用独立兑奖角色、默认单条读取、访问审计和最短保留期；更高安全等级可将加密迁移到支持“只允许加密”权限的 KMS，使普通报名网关不具备解密能力。
