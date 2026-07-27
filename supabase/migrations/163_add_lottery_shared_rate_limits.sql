BEGIN;

CREATE TABLE IF NOT EXISTS public.summer_lottery_rate_limit_config (
  action TEXT PRIMARY KEY CHECK (action ~ '^[a-z][a-z0-9_]{2,63}$'),
  max_attempts INTEGER NOT NULL CHECK (max_attempts BETWEEN 1 AND 10000),
  window_seconds INTEGER NOT NULL CHECK (window_seconds BETWEEN 1 AND 86400)
);

INSERT INTO public.summer_lottery_rate_limit_config (
  action,
  max_attempts,
  window_seconds
) VALUES
  ('gateway_snapshot', 240, 60),
  ('gateway_exchange', 30, 60),
  ('gateway_enter', 10, 600),
  ('gateway_logout', 20, 60),
  ('gateway_prepare', 5, 60),
  ('gateway_draw', 5, 60),
  ('gateway_health', 60, 60),
  ('sso_start', 20, 60)
ON CONFLICT (action) DO UPDATE SET
  max_attempts = EXCLUDED.max_attempts,
  window_seconds = EXCLUDED.window_seconds;

CREATE TABLE IF NOT EXISTS public.summer_lottery_rate_limit_buckets (
  identifier_hash TEXT NOT NULL CHECK (identifier_hash ~ '^[0-9a-f]{64}$'),
  action TEXT NOT NULL REFERENCES public.summer_lottery_rate_limit_config(action)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  window_started_at TIMESTAMPTZ NOT NULL,
  request_count INTEGER NOT NULL CHECK (request_count >= 1),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (identifier_hash, action, window_started_at)
);

CREATE INDEX IF NOT EXISTS idx_summer_lottery_rate_limit_expiry
  ON public.summer_lottery_rate_limit_buckets (window_started_at);

ALTER TABLE public.summer_lottery_rate_limit_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.summer_lottery_rate_limit_buckets ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.consume_summer_lottery_rate_limit(
  p_identifier_hash TEXT,
  p_action TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_config public.summer_lottery_rate_limit_config%ROWTYPE;
  v_now TIMESTAMPTZ := clock_timestamp();
  v_window_started_at TIMESTAMPTZ;
  v_window_ends_at TIMESTAMPTZ;
  v_request_count INTEGER;
  v_retry_after INTEGER;
BEGIN
  IF p_identifier_hash IS NULL
     OR p_identifier_hash !~ '^[0-9a-f]{64}$'
     OR p_action IS NULL
     OR p_action !~ '^[a-z][a-z0-9_]{2,63}$' THEN
    RAISE EXCEPTION 'invalid_lottery_rate_limit_request'
      USING ERRCODE = '22023';
  END IF;

  SELECT *
  INTO v_config
  FROM public.summer_lottery_rate_limit_config
  WHERE action = p_action;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'lottery_rate_limit_action_not_configured'
      USING ERRCODE = '22023';
  END IF;

  v_window_started_at := date_bin(
    make_interval(secs => v_config.window_seconds),
    v_now,
    TIMESTAMPTZ '2000-01-01 00:00:00+00'
  );
  v_window_ends_at := v_window_started_at
    + make_interval(secs => v_config.window_seconds);

  INSERT INTO public.summer_lottery_rate_limit_buckets (
    identifier_hash,
    action,
    window_started_at,
    request_count,
    updated_at
  ) VALUES (
    p_identifier_hash,
    p_action,
    v_window_started_at,
    1,
    v_now
  )
  ON CONFLICT (identifier_hash, action, window_started_at)
  DO UPDATE SET
    request_count = public.summer_lottery_rate_limit_buckets.request_count + 1,
    updated_at = EXCLUDED.updated_at
  RETURNING request_count INTO v_request_count;

  -- 每个窗口只保留短期匿名摘要；抽样清理避免每次请求扫描全表。
  IF random() < 0.01 THEN
    DELETE FROM public.summer_lottery_rate_limit_buckets
    WHERE window_started_at < v_now - INTERVAL '48 hours';
  END IF;

  v_retry_after := GREATEST(
    1,
    CEIL(EXTRACT(EPOCH FROM (v_window_ends_at - v_now)))::INTEGER
  );

  RETURN jsonb_build_object(
    'allowed', v_request_count <= v_config.max_attempts,
    'remaining', GREATEST(0, v_config.max_attempts - v_request_count),
    'retryAfter', CASE
      WHEN v_request_count <= v_config.max_attempts THEN 0
      ELSE v_retry_after
    END,
    'limit', v_config.max_attempts,
    'windowSeconds', v_config.window_seconds
  );
END;
$$;

REVOKE ALL ON TABLE public.summer_lottery_rate_limit_config FROM PUBLIC;
REVOKE ALL ON TABLE public.summer_lottery_rate_limit_config FROM anon;
REVOKE ALL ON TABLE public.summer_lottery_rate_limit_config FROM authenticated;
REVOKE ALL ON TABLE public.summer_lottery_rate_limit_config FROM service_role;
REVOKE ALL ON TABLE public.summer_lottery_rate_limit_buckets FROM PUBLIC;
REVOKE ALL ON TABLE public.summer_lottery_rate_limit_buckets FROM anon;
REVOKE ALL ON TABLE public.summer_lottery_rate_limit_buckets FROM authenticated;
REVOKE ALL ON TABLE public.summer_lottery_rate_limit_buckets FROM service_role;

REVOKE ALL ON FUNCTION public.consume_summer_lottery_rate_limit(TEXT, TEXT)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION public.consume_summer_lottery_rate_limit(TEXT, TEXT)
  FROM anon;
REVOKE ALL ON FUNCTION public.consume_summer_lottery_rate_limit(TEXT, TEXT)
  FROM authenticated;
GRANT EXECUTE ON FUNCTION public.consume_summer_lottery_rate_limit(TEXT, TEXT)
  TO service_role;

COMMENT ON TABLE public.summer_lottery_rate_limit_buckets IS
  '抽奖敏感入口的多实例共享固定窗口计数，仅保存服务端 HMAC 摘要，最长约 48 小时。';
COMMENT ON FUNCTION public.consume_summer_lottery_rate_limit(TEXT, TEXT) IS
  '原子消耗一个抽奖入口限流预算；只允许 service_role 调用。';

COMMIT;
