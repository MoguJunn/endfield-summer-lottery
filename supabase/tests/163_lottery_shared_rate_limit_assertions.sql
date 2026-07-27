BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = public, extensions, pg_temp;
SELECT plan(18);
SELECT set_config('request.jwt.claim.role', 'service_role', FALSE);

DELETE FROM public.summer_lottery_rate_limit_buckets
WHERE identifier_hash IN (repeat('a', 64), repeat('b', 64));

SELECT ok(
  has_function_privilege(
    'service_role',
    'public.consume_summer_lottery_rate_limit(text,text)',
    'EXECUTE'
  ),
  'service_role can consume the shared lottery rate limit'
);
SELECT ok(
  NOT has_function_privilege(
    'anon',
    'public.consume_summer_lottery_rate_limit(text,text)',
    'EXECUTE'
  ),
  'anonymous callers cannot consume the shared lottery rate limit directly'
);
SELECT ok(
  NOT has_function_privilege(
    'authenticated',
    'public.consume_summer_lottery_rate_limit(text,text)',
    'EXECUTE'
  ),
  'authenticated browser callers cannot consume the rate limit directly'
);
SELECT ok(
  NOT has_table_privilege(
    'service_role',
    'public.summer_lottery_rate_limit_config',
    'SELECT'
  ),
  'service_role cannot read rate-limit configuration directly'
);
SELECT ok(
  NOT has_table_privilege(
    'service_role',
    'public.summer_lottery_rate_limit_buckets',
    'SELECT'
  ),
  'service_role cannot enumerate identifier hashes directly'
);
SELECT is(
  (SELECT max_attempts FROM public.summer_lottery_rate_limit_config
   WHERE action = 'gateway_enter'),
  10,
  'entry attempts have a fixed database-owned budget'
);
SELECT is(
  (SELECT window_seconds FROM public.summer_lottery_rate_limit_config
   WHERE action = 'gateway_enter'),
  600,
  'entry attempts share a ten-minute window across instances'
);

CREATE TEMP TABLE shared_rate_limit_results (
  sequence_number INTEGER PRIMARY KEY,
  result JSONB NOT NULL
);

INSERT INTO shared_rate_limit_results (sequence_number, result)
VALUES (
  1,
  public.consume_summer_lottery_rate_limit(
    repeat('a', 64),
    'gateway_enter'
  )
);

SELECT is(
  (SELECT (result->>'allowed')::BOOLEAN FROM shared_rate_limit_results
   WHERE sequence_number = 1),
  TRUE,
  'the first entry attempt is allowed'
);
SELECT is(
  (SELECT (result->>'remaining')::INTEGER FROM shared_rate_limit_results
   WHERE sequence_number = 1),
  9,
  'the first attempt consumes exactly one shared budget unit'
);

INSERT INTO shared_rate_limit_results (sequence_number, result)
SELECT attempt,
       public.consume_summer_lottery_rate_limit(
         repeat('a', 64),
         'gateway_enter'
       )
FROM generate_series(2, 10) AS attempt;

SELECT ok(
  (SELECT bool_and((result->>'allowed')::BOOLEAN)
   FROM shared_rate_limit_results
   WHERE sequence_number BETWEEN 2 AND 10),
  'all attempts through the configured maximum are allowed atomically'
);

INSERT INTO shared_rate_limit_results (sequence_number, result)
VALUES (
  11,
  public.consume_summer_lottery_rate_limit(
    repeat('a', 64),
    'gateway_enter'
  )
);

SELECT is(
  (SELECT (result->>'allowed')::BOOLEAN FROM shared_rate_limit_results
   WHERE sequence_number = 11),
  FALSE,
  'the first over-budget attempt is blocked'
);
SELECT is(
  (SELECT (result->>'remaining')::INTEGER FROM shared_rate_limit_results
   WHERE sequence_number = 11),
  0,
  'a blocked attempt never reports negative remaining capacity'
);
SELECT ok(
  (SELECT (result->>'retryAfter')::INTEGER BETWEEN 1 AND 600
   FROM shared_rate_limit_results
   WHERE sequence_number = 11),
  'a blocked attempt returns a bounded Retry-After value'
);
SELECT is(
  (SELECT request_count
   FROM public.summer_lottery_rate_limit_buckets
   WHERE identifier_hash = repeat('a', 64)
     AND action = 'gateway_enter'),
  11,
  'all instances converge on one fixed-window counter row'
);
SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM public.summer_lottery_rate_limit_buckets
    WHERE identifier_hash !~ '^[0-9a-f]{64}$'
  ),
  'the shared store contains only server-side identifier hashes'
);
SELECT is(
  (public.consume_summer_lottery_rate_limit(
    repeat('b', 64),
    'gateway_enter'
  )->>'allowed')::BOOLEAN,
  TRUE,
  'a different anonymous identifier receives an independent budget'
);
SELECT throws_ok(
  $$SELECT public.consume_summer_lottery_rate_limit(
    '203.0.113.10',
    'gateway_enter'
  )$$,
  '22023',
  'invalid_lottery_rate_limit_request',
  'raw IP addresses are rejected by the database boundary'
);
SELECT throws_ok(
  $$SELECT public.consume_summer_lottery_rate_limit(
    repeat('c', 64),
    'unconfigured_action'
  )$$,
  '22023',
  'lottery_rate_limit_action_not_configured',
  'callers cannot invent a budget outside database configuration'
);

SELECT * FROM finish();
ROLLBACK;
