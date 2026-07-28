BEGIN;

CREATE TABLE IF NOT EXISTS public.summer_lottery_operation_audit (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id TEXT NOT NULL,
  actor_user_id UUID NOT NULL,
  operation TEXT NOT NULL CHECK (operation IN ('prepare', 'draw')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_summer_lottery_operation_audit_campaign
  ON public.summer_lottery_operation_audit (campaign_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_summer_lottery_operation_audit_actor
  ON public.summer_lottery_operation_audit (actor_user_id, created_at DESC);

ALTER TABLE public.summer_lottery_operation_audit ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.prevent_summer_lottery_operation_audit_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  RAISE EXCEPTION 'summer_lottery_operation_audit_immutable'
    USING ERRCODE = '55000';
END;
$$;

DROP TRIGGER IF EXISTS trg_summer_lottery_operation_audit_no_update_delete
  ON public.summer_lottery_operation_audit;
CREATE TRIGGER trg_summer_lottery_operation_audit_no_update_delete
  BEFORE UPDATE OR DELETE ON public.summer_lottery_operation_audit
  FOR EACH ROW EXECUTE FUNCTION public.prevent_summer_lottery_operation_audit_mutation();

DROP TRIGGER IF EXISTS trg_summer_lottery_operation_audit_no_truncate
  ON public.summer_lottery_operation_audit;
CREATE TRIGGER trg_summer_lottery_operation_audit_no_truncate
  BEFORE TRUNCATE ON public.summer_lottery_operation_audit
  FOR EACH STATEMENT EXECUTE FUNCTION public.prevent_summer_lottery_operation_audit_mutation();

CREATE OR REPLACE FUNCTION public.prepare_summer_lottery_as_operator(
  p_campaign_id TEXT,
  p_seed_commitment TEXT,
  p_actor_user_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_result JSONB;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;
  IF p_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'lottery_operator_actor_required' USING ERRCODE = '22023';
  END IF;
  PERFORM 1
  FROM public.profiles
  WHERE id = p_actor_user_id AND role = 'super_admin'
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'lottery_operator_role_required' USING ERRCODE = '42501';
  END IF;

  v_result := public.prepare_summer_lottery(p_campaign_id, p_seed_commitment);

  INSERT INTO public.summer_lottery_operation_audit (
    campaign_id,
    actor_user_id,
    operation
  ) VALUES (
    p_campaign_id,
    p_actor_user_id,
    'prepare'
  );

  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.draw_summer_lottery_as_operator(
  p_campaign_id TEXT,
  p_seed TEXT,
  p_beacon_round BIGINT,
  p_beacon_randomness TEXT,
  p_beacon_signature TEXT,
  p_actor_user_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_result JSONB;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;
  IF p_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'lottery_operator_actor_required' USING ERRCODE = '22023';
  END IF;
  PERFORM 1
  FROM public.profiles
  WHERE id = p_actor_user_id AND role = 'super_admin'
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'lottery_operator_role_required' USING ERRCODE = '42501';
  END IF;

  v_result := public.draw_summer_lottery(
    p_campaign_id,
    p_seed,
    p_beacon_round,
    p_beacon_randomness,
    p_beacon_signature
  );

  INSERT INTO public.summer_lottery_operation_audit (
    campaign_id,
    actor_user_id,
    operation
  ) VALUES (
    p_campaign_id,
    p_actor_user_id,
    'draw'
  );

  RETURN v_result;
END;
$$;

REVOKE ALL ON TABLE public.summer_lottery_operation_audit FROM PUBLIC;
REVOKE ALL ON TABLE public.summer_lottery_operation_audit FROM anon;
REVOKE ALL ON TABLE public.summer_lottery_operation_audit FROM authenticated;
REVOKE ALL ON TABLE public.summer_lottery_operation_audit FROM service_role;

REVOKE ALL ON FUNCTION public.prepare_summer_lottery(TEXT, TEXT)
  FROM service_role;
REVOKE ALL ON FUNCTION public.draw_summer_lottery(TEXT, TEXT, BIGINT, TEXT, TEXT)
  FROM service_role;

REVOKE ALL ON FUNCTION public.prepare_summer_lottery_as_operator(TEXT, TEXT, UUID)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION public.prepare_summer_lottery_as_operator(TEXT, TEXT, UUID)
  FROM anon;
REVOKE ALL ON FUNCTION public.prepare_summer_lottery_as_operator(TEXT, TEXT, UUID)
  FROM authenticated;
GRANT EXECUTE ON FUNCTION public.prepare_summer_lottery_as_operator(TEXT, TEXT, UUID)
  TO service_role;

REVOKE ALL ON FUNCTION public.draw_summer_lottery_as_operator(TEXT, TEXT, BIGINT, TEXT, TEXT, UUID)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION public.draw_summer_lottery_as_operator(TEXT, TEXT, BIGINT, TEXT, TEXT, UUID)
  FROM anon;
REVOKE ALL ON FUNCTION public.draw_summer_lottery_as_operator(TEXT, TEXT, BIGINT, TEXT, TEXT, UUID)
  FROM authenticated;
GRANT EXECUTE ON FUNCTION public.draw_summer_lottery_as_operator(TEXT, TEXT, BIGINT, TEXT, TEXT, UUID)
  TO service_role;

DELETE FROM public.summer_lottery_rate_limit_buckets
WHERE action IN ('gateway_prepare', 'gateway_draw');
DELETE FROM public.summer_lottery_rate_limit_config
WHERE action IN ('gateway_prepare', 'gateway_draw');

INSERT INTO public.summer_lottery_rate_limit_config (
  action,
  max_attempts,
  window_seconds
) VALUES
  ('admin_prepare', 5, 60),
  ('admin_draw', 5, 60)
ON CONFLICT (action) DO UPDATE SET
  max_attempts = EXCLUDED.max_attempts,
  window_seconds = EXCLUDED.window_seconds;

COMMENT ON TABLE public.summer_lottery_operation_audit IS
  '主站短期管理员会话触发的抽奖准备与开奖追加式审计；不保存 seed。';
COMMENT ON FUNCTION public.prepare_summer_lottery_as_operator(TEXT, TEXT, UUID) IS
  '准备活动并在同一事务写入管理员操作审计。';
COMMENT ON FUNCTION public.draw_summer_lottery_as_operator(TEXT, TEXT, BIGINT, TEXT, TEXT, UUID) IS
  '执行幂等开奖并在同一事务写入管理员操作审计。';

COMMIT;
