BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = public, extensions, pg_temp;
SELECT plan(22);
SELECT set_config('request.jwt.claim.role', 'service_role', FALSE);

DELETE FROM public.summer_lottery_campaigns WHERE id = 'operator-audit-test';
DELETE FROM public.profiles
WHERE id IN (
  '77777777-7777-4777-8777-777777777777',
  '88888888-8888-4888-8888-888888888888'
);
DELETE FROM auth.users
WHERE id IN (
  '77777777-7777-4777-8777-777777777777',
  '88888888-8888-4888-8888-888888888888'
);

INSERT INTO auth.users (id, email) VALUES
  ('77777777-7777-4777-8777-777777777777', 'operator-winner@example.test'),
  ('88888888-8888-4888-8888-888888888888', 'operator-admin@example.test');

UPDATE public.profiles
SET role = 'super_admin'
WHERE id = '88888888-8888-4888-8888-888888888888';

INSERT INTO public.summer_lottery_campaigns (
  id,
  title,
  starts_at,
  closes_at,
  draws_at,
  status,
  prize_plan,
  public_randomness_chain,
  public_randomness_round,
  contact_retention_until
) VALUES (
  'operator-audit-test',
  'Operator Audit Test',
  NOW() - INTERVAL '3 days',
  NOW() - INTERVAL '2 days',
  NOW() - INTERVAL '1 day',
  'scheduled',
  '{"first":1,"second":0}'::JSONB,
  '52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971',
  1000,
  NOW() + INTERVAL '30 days'
);

SELECT ok(
  has_function_privilege(
    'service_role',
    'public.prepare_summer_lottery_as_operator(text,text,uuid)',
    'EXECUTE'
  ),
  'service_role can call the audited prepare wrapper'
);
SELECT ok(
  has_function_privilege(
    'service_role',
    'public.draw_summer_lottery_as_operator(text,text,bigint,text,text,uuid)',
    'EXECUTE'
  ),
  'service_role can call the audited draw wrapper'
);
SELECT ok(
  NOT has_function_privilege(
    'anon',
    'public.prepare_summer_lottery_as_operator(text,text,uuid)',
    'EXECUTE'
  ),
  'anonymous callers cannot prepare a lottery'
);
SELECT ok(
  NOT has_function_privilege(
    'authenticated',
    'public.draw_summer_lottery_as_operator(text,text,bigint,text,text,uuid)',
    'EXECUTE'
  ),
  'authenticated browser callers cannot draw a lottery'
);
SELECT ok(
  NOT has_function_privilege(
    'service_role',
    'public.prepare_summer_lottery(text,text)',
    'EXECUTE'
  ),
  'service_role cannot bypass operator auditing for prepare'
);
SELECT ok(
  NOT has_function_privilege(
    'service_role',
    'public.draw_summer_lottery(text,text,bigint,text,text)',
    'EXECUTE'
  ),
  'service_role cannot bypass operator auditing for draw'
);
SELECT ok(
  NOT has_table_privilege(
    'service_role',
    'public.summer_lottery_operation_audit',
    'SELECT'
  ),
  'service_role cannot enumerate operator audit rows directly'
);
SELECT ok(
  NOT has_table_privilege(
    'service_role',
    'public.summer_lottery_operation_audit',
    'INSERT'
  ),
  'service_role cannot forge operator audit rows directly'
);
SELECT is(
  (SELECT max_attempts FROM public.summer_lottery_rate_limit_config
   WHERE action = 'admin_prepare'),
  5,
  'short-session prepare actions have a fixed shared budget'
);
SELECT is(
  (SELECT max_attempts FROM public.summer_lottery_rate_limit_config
   WHERE action = 'admin_draw'),
  5,
  'short-session draw actions have a fixed shared budget'
);
SELECT throws_ok(
  $$SELECT public.prepare_summer_lottery_as_operator(
    'operator-audit-test',
    repeat('a', 64),
    NULL
  )$$,
  '22023',
  'lottery_operator_actor_required',
  'prepare requires a concrete short-session administrator actor'
);
SELECT throws_ok(
  $$SELECT public.prepare_summer_lottery_as_operator(
    'operator-audit-test',
    repeat('a', 64),
    '77777777-7777-4777-8777-777777777777'
  )$$,
  '42501',
  'lottery_operator_role_required',
  'a non-admin actor cannot be forged by the service layer'
);

CREATE TEMP TABLE operator_audit_results (
  key TEXT PRIMARY KEY,
  value JSONB NOT NULL
);

INSERT INTO operator_audit_results (key, value)
SELECT 'prepare', public.prepare_summer_lottery_as_operator(
  'operator-audit-test',
  encode(digest('operator-audited-seed', 'sha256'), 'hex'),
  '88888888-8888-4888-8888-888888888888'
);

SELECT is(
  (SELECT value->>'campaignId' FROM operator_audit_results WHERE key = 'prepare'),
  'operator-audit-test',
  'the audited wrapper prepares the selected campaign'
);
SELECT is(
  (SELECT COUNT(*) FROM public.summer_lottery_operation_audit
   WHERE campaign_id = 'operator-audit-test' AND operation = 'prepare'),
  1::BIGINT,
  'prepare writes one operator audit row in the same transaction'
);
SELECT ok(
  POSITION(
    'operator-audited-seed'
    IN (SELECT string_agg(to_jsonb(audit)::TEXT, '')
        FROM public.summer_lottery_operation_audit AS audit
        WHERE campaign_id = 'operator-audit-test')
  ) = 0,
  'operator audit rows never contain the private seed'
);

INSERT INTO public.summer_lottery_entries (
  campaign_id,
  user_id,
  contact_type,
  contact_value,
  eligible
) VALUES (
  'operator-audit-test',
  '77777777-7777-4777-8777-777777777777',
  'email',
  'olc1.test-key.aaaaaaaaaaaaaaaa.d2lubmVyQGV4YW1wbGUudGVzdA.bbbbbbbbbbbbbbbbbbbbbb',
  TRUE
);

SELECT throws_ok(
  $$SELECT public.draw_summer_lottery_as_operator(
    'operator-audit-test',
    'operator-audited-seed',
    1000,
    '6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d',
    '00',
    NULL
  )$$,
  '22023',
  'lottery_operator_actor_required',
  'draw requires a concrete short-session administrator actor'
);

INSERT INTO operator_audit_results (key, value)
SELECT 'draw', public.draw_summer_lottery_as_operator(
  'operator-audit-test',
  'operator-audited-seed',
  1000,
  '6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d',
  '00',
  '88888888-8888-4888-8888-888888888888'
);

SELECT is(
  (SELECT value->>'campaignId' FROM operator_audit_results WHERE key = 'draw'),
  'operator-audit-test',
  'the audited wrapper draws the selected campaign'
);
SELECT is(
  (SELECT COUNT(*) FROM public.summer_lottery_winners
   WHERE campaign_id = 'operator-audit-test'),
  1::BIGINT,
  'the audited draw preserves transactional winner creation'
);
SELECT is(
  (SELECT COUNT(*) FROM public.summer_lottery_operation_audit
   WHERE campaign_id = 'operator-audit-test' AND operation = 'draw'),
  1::BIGINT,
  'draw writes one operator audit row in the same transaction'
);
SELECT throws_ok(
  $$UPDATE public.summer_lottery_operation_audit
    SET operation = 'draw'
    WHERE campaign_id = 'operator-audit-test'$$,
  '55000',
  'summer_lottery_operation_audit_immutable',
  'operator audit rows cannot be updated'
);
SELECT throws_ok(
  $$DELETE FROM public.summer_lottery_operation_audit
    WHERE campaign_id = 'operator-audit-test'$$,
  '55000',
  'summer_lottery_operation_audit_immutable',
  'operator audit rows cannot be deleted'
);
SELECT throws_ok(
  'TRUNCATE public.summer_lottery_operation_audit',
  '55000',
  'summer_lottery_operation_audit_immutable',
  'the operator audit table cannot be truncated'
);

SELECT * FROM finish();
ROLLBACK;
