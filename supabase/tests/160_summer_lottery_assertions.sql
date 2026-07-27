BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = public, extensions, pg_temp;
SELECT plan(25);
SELECT set_config('request.jwt.claim.role', 'service_role', FALSE);

DELETE FROM public.summer_lottery_campaigns WHERE id = 'contract-test-lottery';
DELETE FROM public.app_sessions WHERE id = '22222222-2222-4222-8222-222222222222';
DELETE FROM public.profiles WHERE id = '11111111-1111-4111-8111-111111111111';
DELETE FROM auth.users WHERE id = '11111111-1111-4111-8111-111111111111';

INSERT INTO auth.users (id, email)
VALUES ('11111111-1111-4111-8111-111111111111', 'lottery-test@example.test');

INSERT INTO public.profiles (id, username, role)
VALUES ('11111111-1111-4111-8111-111111111111', '测试参与者', 'user')
ON CONFLICT (id) DO UPDATE SET username = EXCLUDED.username, role = EXCLUDED.role;

INSERT INTO public.app_sessions (
  id, user_id, session_token_hash, expires_at, absolute_expires_at
) VALUES (
  '22222222-2222-4222-8222-222222222222',
  '11111111-1111-4111-8111-111111111111',
  repeat('9', 64),
  NOW() + INTERVAL '1 day',
  NOW() + INTERVAL '7 days'
);

INSERT INTO public.summer_lottery_campaigns (
  id, title, starts_at, closes_at, draws_at, status, prize_plan,
  public_randomness_chain, public_randomness_round
) VALUES (
  'contract-test-lottery',
  'Contract Test Lottery',
  NOW() - INTERVAL '1 day',
  NOW() + INTERVAL '1 day',
  NOW() + INTERVAL '1 day',
  'scheduled',
  '{"first":1,"second":0}'::JSONB,
  '52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971',
  31618612
);

INSERT INTO public.summer_lottery_sso_tickets (
  ticket_hash, state_hash, audience, user_id, main_session_id, expires_at
) VALUES (
  repeat('a', 64), repeat('b', 64), 'open-lottery',
  '11111111-1111-4111-8111-111111111111',
  '22222222-2222-4222-8222-222222222222',
  NOW() + INTERVAL '1 minute'
);

CREATE TEMP TABLE lottery_test_results (
  key TEXT PRIMARY KEY,
  value JSONB NOT NULL
);

SELECT is(
  public.exchange_summer_lottery_sso_ticket(
    repeat('a', 64), repeat('c', 64), 'open-lottery',
    repeat('d', 64), repeat('e', 64), NOW() + INTERVAL '1 hour'
  ),
  NULL::JSONB,
  'a mismatched SSO state does not consume the ticket'
);

INSERT INTO lottery_test_results (key, value)
SELECT 'exchange', public.exchange_summer_lottery_sso_ticket(
  repeat('a', 64), repeat('b', 64), 'open-lottery',
  repeat('d', 64), repeat('e', 64), NOW() + INTERVAL '1 hour'
);

SELECT is(
  (SELECT value->>'userId' FROM lottery_test_results WHERE key = 'exchange'),
  '11111111-1111-4111-8111-111111111111',
  'a valid SSO ticket binds the expected user'
);

SELECT is(
  public.exchange_summer_lottery_sso_ticket(
    repeat('a', 64), repeat('b', 64), 'open-lottery',
    repeat('f', 64), repeat('1', 64), NOW() + INTERVAL '1 hour'
  ),
  NULL::JSONB,
  'a consumed SSO ticket cannot be replayed'
);

SELECT lives_ok(
  $$SELECT public.prepare_summer_lottery(
    'contract-test-lottery',
    encode(digest('local-test-seed', 'sha256'), 'hex')
  )$$,
  'the campaign commitment can be prepared before entry'
);

INSERT INTO lottery_test_results (key, value)
SELECT 'first_entry', public.enter_summer_lottery(
  'contract-test-lottery', repeat('d', 64), repeat('e', 64),
  'qq', 'olc1.test-key.aaaaaaaaaaaaaaaa.MTIzNDU2Nzg5.bbbbbbbbbbbbbbbbbbbbbb', TRUE
);

INSERT INTO lottery_test_results (key, value)
SELECT 'second_entry', public.enter_summer_lottery(
  'contract-test-lottery', repeat('d', 64), repeat('e', 64),
  'qq', 'olc1.test-key.aaaaaaaaaaaaaaaa.MTIzNDU2Nzg5.bbbbbbbbbbbbbbbbbbbbbb', TRUE
);

SELECT is(
  (SELECT (value->>'alreadyEntered')::BOOLEAN FROM lottery_test_results WHERE key = 'first_entry'),
  FALSE,
  'the first entry is newly created'
);

SELECT is(
  (SELECT (value->>'alreadyEntered')::BOOLEAN FROM lottery_test_results WHERE key = 'second_entry'),
  TRUE,
  'a duplicate entry is reported as idempotent'
);

SELECT is(
  (SELECT value->>'publicId' FROM lottery_test_results WHERE key = 'first_entry'),
  (SELECT value->>'publicId' FROM lottery_test_results WHERE key = 'second_entry'),
  'an idempotent retry returns the same public entry id'
);

SELECT throws_ok(
  $$SELECT public.enter_summer_lottery(
    'contract-test-lottery', repeat('d', 64), repeat('e', 64),
    'invalid type', 'contact', TRUE
  )$$,
  '22023',
  'invalid_contact_value',
  'invalid contact metadata is rejected'
);

SELECT throws_ok(
  $$SELECT public.enter_summer_lottery(
    'contract-test-lottery', repeat('d', 64), repeat('e', 64),
    'qq', '123456789', TRUE
  )$$,
  '22023',
  'invalid_contact_value',
  'plaintext contact values are rejected by the RPC'
);

UPDATE public.app_sessions
SET revoked_at = NOW()
WHERE id = '22222222-2222-4222-8222-222222222222';

SELECT throws_ok(
  $$SELECT public.enter_summer_lottery(
    'contract-test-lottery', repeat('d', 64), repeat('e', 64),
    'text', 'olc1.test-key.aaaaaaaaaaaaaaaa.Y29udGFjdA.bbbbbbbbbbbbbbbbbbbbbb', FALSE
  )$$,
  '28000',
  'lottery_session_invalid',
  'a revoked source session invalidates the lottery session'
);

UPDATE public.app_sessions
SET revoked_at = NULL
WHERE id = '22222222-2222-4222-8222-222222222222';

UPDATE public.summer_lottery_campaigns
SET status = 'closed'
WHERE id = 'contract-test-lottery';

SELECT throws_ok(
  $$SELECT public.enter_summer_lottery(
    'contract-test-lottery', repeat('d', 64), repeat('e', 64),
    'text', 'olc1.test-key.aaaaaaaaaaaaaaaa.Y29udGFjdA.bbbbbbbbbbbbbbbbbbbbbb', FALSE
  )$$,
  '55000',
  'campaign_not_open',
  'a closed campaign rejects entry'
);

UPDATE public.summer_lottery_campaigns
SET status = 'open',
    closes_at = NOW() - INTERVAL '2 seconds',
    draws_at = NOW() - INTERVAL '1 second'
WHERE id = 'contract-test-lottery';

SELECT lives_ok(
  $$INSERT INTO lottery_test_results (key, value)
    SELECT 'draw', public.draw_summer_lottery(
      'contract-test-lottery',
      'local-test-seed',
      31618612,
      encode(digest(decode('00', 'hex'), 'sha256'), 'hex'),
      '00'
    )$$,
  'the prepared campaign can be drawn once its draw time arrives'
);

SELECT matches(
  (SELECT value->>'candidateManifestHash' FROM lottery_test_results WHERE key = 'draw'),
  '^[0-9a-f]{64}$',
  'the draw publishes a candidate manifest hash'
);

SELECT is(
  (SELECT jsonb_array_length(value->'winners') FROM lottery_test_results WHERE key = 'draw'),
  1,
  'the configured winner count is persisted'
);

SELECT lives_ok(
  $$INSERT INTO lottery_test_results (key, value)
    SELECT 'draw_retry', public.draw_summer_lottery(
      'contract-test-lottery',
      'local-test-seed',
      31618612,
      encode(digest(decode('00', 'hex'), 'sha256'), 'hex'),
      '00'
    )$$,
  'the same draw can be safely retried'
);

SELECT is(
  (SELECT value->>'candidateManifestHash' FROM lottery_test_results WHERE key = 'draw_retry'),
  (SELECT value->>'candidateManifestHash' FROM lottery_test_results WHERE key = 'draw'),
  'a draw retry returns the same manifest'
);

SELECT throws_ok(
  $$SELECT public.draw_summer_lottery(
    'contract-test-lottery',
    'wrong-seed',
    31618612,
    encode(digest(decode('00', 'hex'), 'sha256'), 'hex'),
    '00'
  )$$,
  '55000',
  'campaign_already_drawn',
  'a retry with a different seed is rejected'
);

SELECT is(
  (SELECT COUNT(*) FROM public.summer_lottery_entries WHERE campaign_id = 'contract-test-lottery'),
  1::BIGINT,
  'the campaign contains one entry after a duplicate request'
);

SELECT ok(
  EXISTS (
    SELECT 1
    FROM public.summer_lottery_entries
    WHERE campaign_id = 'contract-test-lottery'
      AND contact_type = 'qq'
      AND contact_value = 'olc1.test-key.aaaaaaaaaaaaaaaa.MTIzNDU2Nzg5.bbbbbbbbbbbbbbbbbbbbbb'
      AND notification_confirmed_at IS NOT NULL
  ),
  'only the encrypted contact envelope is persisted outside the public result'
);

SELECT ok(
  POSITION('123456789' IN (SELECT value::TEXT FROM lottery_test_results WHERE key = 'first_entry')) = 0,
  'the entry RPC response does not contain the private contact value'
);

SELECT is(
  (SELECT COUNT(*) FROM public.summer_lottery_sso_tickets
   WHERE main_session_id = '22222222-2222-4222-8222-222222222222'
     AND consumed_at IS NULL),
  0::BIGINT,
  'no pending SSO ticket remains after consumption'
);

SELECT ok(
  NOT has_table_privilege('anon', 'public.summer_lottery_entries', 'SELECT'),
  'the anonymous role cannot read private entries'
);

SELECT ok(
  NOT has_table_privilege('authenticated', 'public.summer_lottery_entries', 'SELECT'),
  'the authenticated browser role cannot read private entries'
);

SELECT matches(
  (SELECT value->>'publicId' FROM lottery_test_results WHERE key = 'first_entry'),
  '^[0-9a-f-]{36}$',
  'the public entry id has UUID form'
);

SELECT is(
  (SELECT COUNT(*) FROM public.summer_lottery_winners WHERE campaign_id = 'contract-test-lottery'),
  1::BIGINT,
  'the winner row is stored exactly once'
);

SELECT * FROM finish();
ROLLBACK;
