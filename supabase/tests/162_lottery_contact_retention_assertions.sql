BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = public, extensions, pg_temp;
SELECT plan(32);
SELECT set_config('request.jwt.claim.role', 'service_role', FALSE);

DELETE FROM public.summer_lottery_campaigns WHERE id = 'contact-retention-test';
DELETE FROM public.profiles WHERE id IN (
  '33333333-3333-4333-8333-333333333333',
  '44444444-4444-4444-8444-444444444444'
);
DELETE FROM auth.users WHERE id IN (
  '33333333-3333-4333-8333-333333333333',
  '44444444-4444-4444-8444-444444444444'
);

INSERT INTO auth.users (id, email) VALUES
  ('33333333-3333-4333-8333-333333333333', 'winner@example.test'),
  ('44444444-4444-4444-8444-444444444444', 'operator@example.test');

INSERT INTO public.profiles (id, username, role) VALUES
  ('33333333-3333-4333-8333-333333333333', '测试中奖者', 'user'),
  ('44444444-4444-4444-8444-444444444444', '测试管理员', 'super_admin')
ON CONFLICT (id) DO UPDATE
SET username = EXCLUDED.username,
    role = EXCLUDED.role;

INSERT INTO public.summer_lottery_campaigns (
  id, title, starts_at, closes_at, draws_at, status, prize_plan,
  public_randomness_chain, public_randomness_round,
  drawn_at, contact_retention_until
) VALUES (
  'contact-retention-test',
  'Contact Retention Test',
  NOW() - INTERVAL '3 days',
  NOW() - INTERVAL '2 days',
  NOW() - INTERVAL '2 days',
  'drawn',
  '{"first":1,"second":0}'::JSONB,
  '52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971',
  31618612,
  NOW() - INTERVAL '2 days',
  NOW() + INTERVAL '1 day'
);

INSERT INTO public.summer_lottery_entries (
  id, campaign_id, user_id, contact_type, contact_value, eligible
) VALUES (
  '55555555-5555-4555-8555-555555555555',
  'contact-retention-test',
  '33333333-3333-4333-8333-333333333333',
  'email',
  'olc1.test-key.aaaaaaaaaaaaaaaa.d2lubmVyQGV4YW1wbGUudGVzdA.bbbbbbbbbbbbbbbbbbbbbb',
  TRUE
);

INSERT INTO public.summer_lottery_winners (
  campaign_id, entry_id, user_id, prize_tier, winner_order
) VALUES (
  'contact-retention-test',
  '55555555-5555-4555-8555-555555555555',
  '33333333-3333-4333-8333-333333333333',
  'first',
  1
);

CREATE TEMP TABLE contact_retention_results (
  key TEXT PRIMARY KEY,
  value JSONB NOT NULL
);

SELECT ok(
  has_function_privilege('service_role', 'public.list_summer_lottery_contact_targets(text)', 'EXECUTE'),
  'service_role can list non-sensitive contact targets'
);
SELECT ok(
  has_function_privilege('service_role', 'public.read_summer_lottery_contact(uuid,uuid,text)', 'EXECUTE'),
  'service_role can call the audited contact reader'
);
SELECT ok(
  has_function_privilege('service_role', 'public.purge_summer_lottery_contact(uuid,uuid,text)', 'EXECUTE'),
  'service_role can call the single-contact purge RPC'
);
SELECT ok(
  NOT has_function_privilege('anon', 'public.read_summer_lottery_contact(uuid,uuid,text)', 'EXECUTE'),
  'anonymous callers cannot read contacts'
);
SELECT ok(
  NOT has_function_privilege('authenticated', 'public.read_summer_lottery_contact(uuid,uuid,text)', 'EXECUTE'),
  'authenticated browser callers cannot read contacts'
);
SELECT ok(
  NOT has_column_privilege('service_role', 'public.summer_lottery_entries', 'contact_value', 'SELECT'),
  'service_role cannot bypass auditing by selecting the encrypted contact column'
);
SELECT ok(
  has_column_privilege('service_role', 'public.summer_lottery_entries', 'public_id', 'SELECT'),
  'service_role retains access to safe entry metadata'
);
SELECT ok(
  NOT has_table_privilege('anon', 'public.summer_lottery_contact_access_audit', 'SELECT'),
  'anonymous callers cannot read contact audits'
);
SELECT ok(
  NOT has_table_privilege('service_role', 'public.summer_lottery_contact_access_audit', 'INSERT'),
  'service_role cannot forge contact audit rows directly'
);

INSERT INTO contact_retention_results (key, value)
SELECT 'targets', public.list_summer_lottery_contact_targets('contact-retention-test');

SELECT is(
  jsonb_array_length((SELECT value->'targets' FROM contact_retention_results WHERE key = 'targets')),
  1,
  'the target list includes exactly one winner'
);
SELECT ok(
  POSITION('contactValue' IN (SELECT value::TEXT FROM contact_retention_results WHERE key = 'targets')) = 0,
  'the target list never contains the encrypted or plaintext contact value'
);

INSERT INTO contact_retention_results (key, value)
SELECT 'read', public.read_summer_lottery_contact(
  '55555555-5555-4555-8555-555555555555',
  '44444444-4444-4444-8444-444444444444',
  '联系一等奖中奖者'
);

SELECT matches(
  (SELECT value->>'contactValue' FROM contact_retention_results WHERE key = 'read'),
  '^olc1\.',
  'the audited reader returns only the encrypted envelope'
);
SELECT is(
  (SELECT COUNT(*) FROM public.summer_lottery_contact_access_audit
   WHERE entry_id = '55555555-5555-4555-8555-555555555555'
     AND operation = 'contact_read'),
  1::BIGINT,
  'a successful encrypted contact read creates one audit row'
);
SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM public.summer_lottery_contact_access_audit
    WHERE reason LIKE '%winner@example.test%'
       OR reason LIKE '%olc1.%'
  ),
  'contact audit rows contain neither plaintext nor encrypted contact values'
);
SELECT throws_ok(
  $$SELECT public.read_summer_lottery_contact(
    '55555555-5555-4555-8555-555555555555', NULL, '无管理员身份'
  )$$,
  '22023',
  'invalid_contact_access_request',
  'the contact reader requires an administrator actor id'
);

INSERT INTO contact_retention_results (key, value)
SELECT 'manual_purge', public.purge_summer_lottery_contact(
  '55555555-5555-4555-8555-555555555555',
  '44444444-4444-4444-8444-444444444444',
  '中奖者要求提前删除联系方式'
);
SELECT is(
  (SELECT (value->>'cleared')::BOOLEAN FROM contact_retention_results WHERE key = 'manual_purge'),
  TRUE,
  'a manual purge clears one winner contact'
);
SELECT is(
  (SELECT contact_value FROM public.summer_lottery_entries
   WHERE id = '55555555-5555-4555-8555-555555555555'),
  NULL::TEXT,
  'the manual purge removes the encrypted contact value'
);
SELECT is(
  (public.purge_summer_lottery_contact(
    '55555555-5555-4555-8555-555555555555',
    '44444444-4444-4444-8444-444444444444',
    '重复删除请求'
  )->>'cleared')::BOOLEAN,
  FALSE,
  'a repeated manual purge is idempotent'
);
SELECT is(
  (SELECT COUNT(*) FROM public.summer_lottery_contact_access_audit
   WHERE entry_id = '55555555-5555-4555-8555-555555555555'
     AND operation = 'contact_manual_purge'),
  1::BIGINT,
  'an idempotent manual purge does not duplicate audit rows'
);

UPDATE public.summer_lottery_entries
SET contact_value = 'olc1.test-key.aaaaaaaaaaaaaaaa.d2lubmVyQGV4YW1wbGUudGVzdA.bbbbbbbbbbbbbbbbbbbbbb'
WHERE id = '55555555-5555-4555-8555-555555555555';
UPDATE public.summer_lottery_campaigns
SET contact_retention_until = NOW() - INTERVAL '1 hour'
WHERE id = 'contact-retention-test';

SELECT throws_ok(
  $$SELECT public.read_summer_lottery_contact(
    '55555555-5555-4555-8555-555555555555',
    '44444444-4444-4444-8444-444444444444',
    '过期后读取应失败'
  )$$,
  '55000',
  'contact_retention_expired',
  'expired contacts cannot be read even before cleanup runs'
);

INSERT INTO contact_retention_results (key, value)
SELECT 'retention_purge', public.purge_expired_summer_lottery_contacts(
  'contact-retention-test',
  '44444444-4444-4444-8444-444444444444'
);
SELECT is(
  (SELECT (value->>'clearedCount')::INTEGER FROM contact_retention_results WHERE key = 'retention_purge'),
  1,
  'the retention purge clears all remaining campaign contacts'
);
SELECT is(
  (SELECT contact_value FROM public.summer_lottery_entries
   WHERE id = '55555555-5555-4555-8555-555555555555'),
  NULL::TEXT,
  'the retention purge removes the encrypted envelope'
);
SELECT is(
  (SELECT COUNT(*) FROM public.summer_lottery_entries WHERE campaign_id = 'contact-retention-test'),
  1::BIGINT,
  'contact cleanup preserves the public entry record'
);
SELECT is(
  (SELECT COUNT(*) FROM public.summer_lottery_winners WHERE campaign_id = 'contact-retention-test'),
  1::BIGINT,
  'contact cleanup preserves the winner record'
);
SELECT matches(
  (SELECT public_id::TEXT FROM public.summer_lottery_entries
   WHERE id = '55555555-5555-4555-8555-555555555555'),
  '^[0-9a-f-]{36}$',
  'contact cleanup preserves the public verification id'
);
SELECT ok(
  (SELECT contacts_cleared_at IS NOT NULL FROM public.summer_lottery_campaigns
   WHERE id = 'contact-retention-test'),
  'contact cleanup records its completion time'
);
SELECT is(
  (SELECT COUNT(*) FROM public.summer_lottery_contact_access_audit
   WHERE campaign_id = 'contact-retention-test'
     AND operation = 'contact_retention_purge'),
  1::BIGINT,
  'retention cleanup writes one campaign-level audit row'
);
SELECT is(
  (public.purge_expired_summer_lottery_contacts(
    'contact-retention-test',
    '44444444-4444-4444-8444-444444444444'
  )->>'clearedCount')::INTEGER,
  0,
  'repeated retention cleanup is idempotent'
);
SELECT is(
  (SELECT COUNT(*) FROM public.summer_lottery_contact_access_audit
   WHERE campaign_id = 'contact-retention-test'
     AND operation = 'contact_retention_purge'),
  1::BIGINT,
  'repeated retention cleanup does not duplicate audit rows'
);
SELECT throws_ok(
  $$UPDATE public.summer_lottery_contact_access_audit
    SET reason = '篡改'
    WHERE campaign_id = 'contact-retention-test'$$,
  '55000',
  'summer_lottery_contact_audit_immutable',
  'contact audit rows cannot be updated'
);
SELECT throws_ok(
  $$DELETE FROM public.summer_lottery_contact_access_audit
    WHERE campaign_id = 'contact-retention-test'$$,
  '55000',
  'summer_lottery_contact_audit_immutable',
  'contact audit rows cannot be deleted'
);
SELECT throws_ok(
  'TRUNCATE public.summer_lottery_contact_access_audit',
  '55000',
  'summer_lottery_contact_audit_immutable',
  'the contact audit table cannot be truncated'
);

SELECT * FROM finish();
ROLLBACK;
