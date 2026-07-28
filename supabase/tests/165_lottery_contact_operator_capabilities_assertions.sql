BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = public, extensions, pg_temp;
SELECT plan(38);
SELECT set_config('request.jwt.claim.role', 'service_role', FALSE);

DELETE FROM public.summer_lottery_campaigns
WHERE id = 'operator-capability-test';
DELETE FROM public.profiles WHERE id IN (
  '99999999-9999-4999-8999-999999999999',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
);
DELETE FROM auth.users WHERE id IN (
  '99999999-9999-4999-8999-999999999999',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
);

INSERT INTO auth.users (id, email) VALUES
  ('99999999-9999-4999-8999-999999999999', 'capability-admin@example.test'),
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'capability-operator@example.test'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'capability-outsider@example.test'),
  ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'capability-winner@example.test');

INSERT INTO public.profiles (id, username, role) VALUES
  ('99999999-9999-4999-8999-999999999999', '授权管理员', 'super_admin'),
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '兑奖专员', 'user'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', '普通用户', 'user'),
  ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', '测试中奖者', 'user')
ON CONFLICT (id) DO UPDATE
SET username = EXCLUDED.username,
    role = EXCLUDED.role;

INSERT INTO public.summer_lottery_campaigns (
  id, title, starts_at, closes_at, draws_at, status, prize_plan,
  public_randomness_chain, public_randomness_round,
  drawn_at, contact_retention_until
) VALUES (
  'operator-capability-test',
  'Operator Capability Test',
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
  'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
  'operator-capability-test',
  'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
  'email',
  'olc1.test-key.aaaaaaaaaaaaaaaa.d2lubmVyQGV4YW1wbGUudGVzdA.bbbbbbbbbbbbbbbbbbbbbb',
  TRUE
);

INSERT INTO public.summer_lottery_winners (
  campaign_id, entry_id, user_id, prize_tier, winner_order
) VALUES (
  'operator-capability-test',
  'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
  'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
  'first',
  1
);

CREATE TEMP TABLE operator_capability_results (
  key TEXT PRIMARY KEY,
  value JSONB NOT NULL
);

SELECT ok(
  NOT has_table_privilege('service_role', 'public.summer_lottery_operator_grants', 'SELECT'),
  'service_role cannot enumerate active operator grants directly'
);
SELECT ok(
  NOT has_table_privilege('service_role', 'public.summer_lottery_operator_grants', 'INSERT'),
  'service_role cannot forge active operator grants directly'
);
SELECT ok(
  NOT has_table_privilege('service_role', 'public.summer_lottery_operator_grant_audit', 'SELECT'),
  'service_role cannot enumerate grant audit rows directly'
);
SELECT ok(
  NOT has_table_privilege('service_role', 'public.summer_lottery_operator_grant_audit', 'INSERT'),
  'service_role cannot forge grant audit rows directly'
);
SELECT ok(
  NOT has_function_privilege(
    'anon',
    'public.has_summer_lottery_operator_capability(text,uuid,text)',
    'EXECUTE'
  ),
  'anonymous callers cannot inspect operator capabilities'
);
SELECT ok(
  NOT has_function_privilege(
    'authenticated',
    'public.set_summer_lottery_operator_capability(text,uuid,text,boolean,uuid)',
    'EXECUTE'
  ),
  'authenticated callers cannot manage operator capabilities'
);
SELECT ok(
  has_function_privilege(
    'service_role',
    'public.has_summer_lottery_operator_capability(text,uuid,text)',
    'EXECUTE'
  ),
  'service_role can inspect one authenticated operator capability'
);
SELECT ok(
  has_function_privilege(
    'service_role',
    'public.set_summer_lottery_operator_capability(text,uuid,text,boolean,uuid)',
    'EXECUTE'
  ),
  'service_role can use the audited grant manager'
);
SELECT ok(
  has_function_privilege(
    'service_role',
    'public.list_summer_lottery_operator_grants(text,uuid)',
    'EXECUTE'
  ),
  'service_role can list grants through the super-admin wrapper'
);
SELECT ok(
  has_function_privilege(
    'service_role',
    'public.list_summer_lottery_contact_targets(text,uuid)',
    'EXECUTE'
  ),
  'service_role can use the actor-bound target list'
);
SELECT ok(
  NOT has_function_privilege(
    'service_role',
    'public.list_summer_lottery_contact_targets_internal(text)',
    'EXECUTE'
  ),
  'service_role cannot bypass target-list capability checks'
);
SELECT ok(
  NOT has_function_privilege(
    'service_role',
    'public.read_summer_lottery_contact_internal(uuid,uuid,text)',
    'EXECUTE'
  ),
  'service_role cannot bypass contact-read capability checks'
);
SELECT ok(
  NOT has_function_privilege(
    'service_role',
    'public.purge_summer_lottery_contact_internal(uuid,uuid,text)',
    'EXECUTE'
  ),
  'service_role cannot bypass contact-purge capability checks'
);

SELECT is(
  public.has_summer_lottery_operator_capability(
    'operator-capability-test',
    '99999999-9999-4999-8999-999999999999',
    'contact_read'
  ),
  FALSE,
  'super-admin role does not implicitly grant contact access'
);
SELECT throws_ok(
  $$SELECT public.list_summer_lottery_contact_targets(
    'operator-capability-test',
    '99999999-9999-4999-8999-999999999999'
  )$$,
  '42501',
  'lottery_operator_capability_required',
  'a super-admin without an explicit grant cannot list contact targets'
);
SELECT is(
  public.has_summer_lottery_operator_capability(
    'operator-capability-test',
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    'contact_read'
  ),
  FALSE,
  'a normal profile starts without contact capabilities'
);
SELECT throws_ok(
  $$SELECT public.set_summer_lottery_operator_capability(
    'operator-capability-test',
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    'contact_read',
    TRUE,
    'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
  )$$,
  '42501',
  'lottery_operator_grant_admin_required',
  'a non-super-admin actor cannot grant operator access'
);
SELECT throws_ok(
  $$SELECT public.set_summer_lottery_operator_capability(
    'operator-capability-test',
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    'draw',
    TRUE,
    '99999999-9999-4999-8999-999999999999'
  )$$,
  '22023',
  'invalid_lottery_operator_grant_request',
  'the grant manager rejects capabilities outside the contact allowlist'
);

INSERT INTO operator_capability_results (key, value)
SELECT 'grant_read', public.set_summer_lottery_operator_capability(
  'operator-capability-test',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'contact_read',
  TRUE,
  '99999999-9999-4999-8999-999999999999'
);
SELECT is(
  (SELECT (value->>'changed')::BOOLEAN FROM operator_capability_results WHERE key = 'grant_read'),
  TRUE,
  'granting contact-read access records a state change'
);

INSERT INTO operator_capability_results (key, value)
SELECT 'grant_read_again', public.set_summer_lottery_operator_capability(
  'operator-capability-test',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'contact_read',
  TRUE,
  '99999999-9999-4999-8999-999999999999'
);
SELECT is(
  (SELECT (value->>'changed')::BOOLEAN FROM operator_capability_results WHERE key = 'grant_read_again'),
  FALSE,
  'granting an existing capability is idempotent'
);
SELECT is(
  public.has_summer_lottery_operator_capability(
    'operator-capability-test',
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    'contact_read'
  ),
  TRUE,
  'the operator capability check sees the explicit grant'
);
SELECT is(
  (SELECT COUNT(*) FROM public.summer_lottery_operator_grant_audit
   WHERE campaign_id = 'operator-capability-test'
     AND operation = 'grant'
     AND capability = 'contact_read'),
  1::BIGINT,
  'an idempotent repeated grant does not duplicate audit rows'
);

INSERT INTO operator_capability_results (key, value)
SELECT 'grants', public.list_summer_lottery_operator_grants(
  'operator-capability-test',
  '99999999-9999-4999-8999-999999999999'
);
SELECT is(
  jsonb_array_length((SELECT value->'grants' FROM operator_capability_results WHERE key = 'grants')),
  1,
  'the super-admin grant list contains the explicit operator capability'
);

INSERT INTO operator_capability_results (key, value)
SELECT 'targets', public.list_summer_lottery_contact_targets(
  'operator-capability-test',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
);
SELECT is(
  jsonb_array_length((SELECT value->'targets' FROM operator_capability_results WHERE key = 'targets')),
  1,
  'a contact-read operator can list one winner target'
);
SELECT ok(
  POSITION('contactValue' IN (SELECT value::TEXT FROM operator_capability_results WHERE key = 'targets')) = 0,
  'the capability-gated target list still excludes contact values'
);

INSERT INTO operator_capability_results (key, value)
SELECT 'read', public.read_summer_lottery_contact(
  'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'winner_notification'
);
SELECT matches(
  (SELECT value->>'contactValue' FROM operator_capability_results WHERE key = 'read'),
  '^olc1\.',
  'a contact-read operator receives only the encrypted envelope'
);
SELECT is(
  (SELECT actor_user_id FROM public.summer_lottery_contact_access_audit
   WHERE entry_id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
     AND operation = 'contact_read'),
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::UUID,
  'the contact-read audit records the capability holder as actor'
);
SELECT throws_ok(
  $$SELECT public.purge_summer_lottery_contact(
    'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    'manual_privacy_request'
  )$$,
  '42501',
  'lottery_operator_capability_required',
  'contact-read access alone cannot purge a contact'
);

INSERT INTO operator_capability_results (key, value)
SELECT 'grant_purge', public.set_summer_lottery_operator_capability(
  'operator-capability-test',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'contact_purge',
  TRUE,
  '99999999-9999-4999-8999-999999999999'
);
SELECT is(
  (SELECT (value->>'changed')::BOOLEAN FROM operator_capability_results WHERE key = 'grant_purge'),
  TRUE,
  'granting contact-purge access records a separate state change'
);

INSERT INTO operator_capability_results (key, value)
SELECT 'purge', public.purge_summer_lottery_contact(
  'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'manual_privacy_request'
);
SELECT is(
  (SELECT (value->>'cleared')::BOOLEAN FROM operator_capability_results WHERE key = 'purge'),
  TRUE,
  'a contact-purge operator can clear one selected winner contact'
);
SELECT is(
  (SELECT contact_value FROM public.summer_lottery_entries
   WHERE id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'),
  NULL::TEXT,
  'the capability-gated purge removes the encrypted contact'
);

INSERT INTO operator_capability_results (key, value)
SELECT 'revoke_read', public.set_summer_lottery_operator_capability(
  'operator-capability-test',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'contact_read',
  FALSE,
  '99999999-9999-4999-8999-999999999999'
);
SELECT is(
  (SELECT (value->>'changed')::BOOLEAN FROM operator_capability_results WHERE key = 'revoke_read'),
  TRUE,
  'revoking contact-read access records a state change'
);
SELECT is(
  public.has_summer_lottery_operator_capability(
    'operator-capability-test',
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    'contact_read'
  ),
  FALSE,
  'the revoked contact-read capability is no longer active'
);

INSERT INTO operator_capability_results (key, value)
SELECT 'revoke_read_again', public.set_summer_lottery_operator_capability(
  'operator-capability-test',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'contact_read',
  FALSE,
  '99999999-9999-4999-8999-999999999999'
);
SELECT is(
  (SELECT (value->>'changed')::BOOLEAN FROM operator_capability_results WHERE key = 'revoke_read_again'),
  FALSE,
  'revoking an absent capability is idempotent'
);
SELECT is(
  (SELECT COUNT(*) FROM public.summer_lottery_operator_grant_audit
   WHERE campaign_id = 'operator-capability-test'),
  3::BIGINT,
  'only two grants and one revoke are written to grant audit'
);
SELECT throws_ok(
  $$UPDATE public.summer_lottery_operator_grant_audit
    SET operation = 'grant'
    WHERE campaign_id = 'operator-capability-test'$$,
  '55000',
  'summer_lottery_operator_grant_audit_immutable',
  'operator grant audit rows cannot be updated'
);
SELECT throws_ok(
  $$DELETE FROM public.summer_lottery_operator_grant_audit
    WHERE campaign_id = 'operator-capability-test'$$,
  '55000',
  'summer_lottery_operator_grant_audit_immutable',
  'operator grant audit rows cannot be deleted'
);
SELECT throws_ok(
  'TRUNCATE public.summer_lottery_operator_grant_audit',
  '55000',
  'summer_lottery_operator_grant_audit_immutable',
  'operator grant audit table cannot be truncated'
);

SELECT * FROM finish();
ROLLBACK;
