BEGIN;

CREATE TABLE public.summer_lottery_operator_grants (
  campaign_id TEXT NOT NULL REFERENCES public.summer_lottery_campaigns(id)
    ON UPDATE CASCADE ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.profiles(id)
    ON DELETE CASCADE,
  capability TEXT NOT NULL CHECK (
    capability IN ('contact_read', 'contact_purge')
  ),
  granted_by UUID NOT NULL,
  granted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (campaign_id, user_id, capability)
);

CREATE INDEX idx_summer_lottery_operator_grants_user
  ON public.summer_lottery_operator_grants (user_id, campaign_id);

CREATE TABLE public.summer_lottery_operator_grant_audit (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id TEXT NOT NULL,
  target_user_id UUID NOT NULL,
  actor_user_id UUID NOT NULL,
  capability TEXT NOT NULL CHECK (
    capability IN ('contact_read', 'contact_purge')
  ),
  operation TEXT NOT NULL CHECK (operation IN ('grant', 'revoke')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_summer_lottery_operator_grant_audit_campaign
  ON public.summer_lottery_operator_grant_audit (campaign_id, created_at DESC);
CREATE INDEX idx_summer_lottery_operator_grant_audit_target
  ON public.summer_lottery_operator_grant_audit (target_user_id, created_at DESC);

ALTER TABLE public.summer_lottery_operator_grants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.summer_lottery_operator_grant_audit ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.prevent_summer_lottery_operator_grant_audit_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  RAISE EXCEPTION 'summer_lottery_operator_grant_audit_immutable'
    USING ERRCODE = '55000';
END;
$$;

CREATE TRIGGER trg_summer_lottery_operator_grant_audit_no_update_delete
BEFORE UPDATE OR DELETE ON public.summer_lottery_operator_grant_audit
FOR EACH ROW
EXECUTE FUNCTION public.prevent_summer_lottery_operator_grant_audit_mutation();

CREATE TRIGGER trg_summer_lottery_operator_grant_audit_no_truncate
BEFORE TRUNCATE ON public.summer_lottery_operator_grant_audit
FOR EACH STATEMENT
EXECUTE FUNCTION public.prevent_summer_lottery_operator_grant_audit_mutation();

CREATE OR REPLACE FUNCTION public.has_summer_lottery_operator_capability(
  p_campaign_id TEXT,
  p_user_id UUID,
  p_capability TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;
  IF NULLIF(btrim(COALESCE(p_campaign_id, '')), '') IS NULL
     OR p_user_id IS NULL
     OR p_capability NOT IN ('contact_read', 'contact_purge') THEN
    RAISE EXCEPTION 'invalid_lottery_operator_capability_request'
      USING ERRCODE = '22023';
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM public.summer_lottery_operator_grants AS operator_grant
    JOIN public.profiles AS profile
      ON profile.id = operator_grant.user_id
    WHERE operator_grant.campaign_id = p_campaign_id
      AND operator_grant.user_id = p_user_id
      AND operator_grant.capability = p_capability
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.require_summer_lottery_operator_capability(
  p_campaign_id TEXT,
  p_user_id UUID,
  p_capability TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;
  IF NULLIF(btrim(COALESCE(p_campaign_id, '')), '') IS NULL
     OR p_user_id IS NULL
     OR p_capability NOT IN ('contact_read', 'contact_purge') THEN
    RAISE EXCEPTION 'invalid_lottery_operator_capability_request'
      USING ERRCODE = '22023';
  END IF;

  PERFORM 1
  FROM public.summer_lottery_operator_grants AS operator_grant
  JOIN public.profiles AS profile
    ON profile.id = operator_grant.user_id
  WHERE operator_grant.campaign_id = p_campaign_id
    AND operator_grant.user_id = p_user_id
    AND operator_grant.capability = p_capability
  FOR SHARE OF operator_grant, profile;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'lottery_operator_capability_required'
      USING ERRCODE = '42501';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.set_summer_lottery_operator_capability(
  p_campaign_id TEXT,
  p_target_user_id UUID,
  p_capability TEXT,
  p_enabled BOOLEAN,
  p_actor_user_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_changed BOOLEAN := FALSE;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;
  IF NULLIF(btrim(COALESCE(p_campaign_id, '')), '') IS NULL
     OR p_target_user_id IS NULL
     OR p_actor_user_id IS NULL
     OR p_enabled IS NULL
     OR p_capability NOT IN ('contact_read', 'contact_purge') THEN
    RAISE EXCEPTION 'invalid_lottery_operator_grant_request'
      USING ERRCODE = '22023';
  END IF;

  PERFORM 1
  FROM public.profiles
  WHERE id = p_actor_user_id AND role = 'super_admin'
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'lottery_operator_grant_admin_required'
      USING ERRCODE = '42501';
  END IF;

  PERFORM 1
  FROM public.profiles
  WHERE id = p_target_user_id
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'lottery_operator_target_not_found'
      USING ERRCODE = 'P0002';
  END IF;

  PERFORM 1
  FROM public.summer_lottery_campaigns
  WHERE id = p_campaign_id
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'campaign_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF p_enabled THEN
    INSERT INTO public.summer_lottery_operator_grants (
      campaign_id,
      user_id,
      capability,
      granted_by
    ) VALUES (
      p_campaign_id,
      p_target_user_id,
      p_capability,
      p_actor_user_id
    )
    ON CONFLICT (campaign_id, user_id, capability) DO NOTHING;
    v_changed := FOUND;
  ELSE
    DELETE FROM public.summer_lottery_operator_grants
    WHERE campaign_id = p_campaign_id
      AND user_id = p_target_user_id
      AND capability = p_capability;
    v_changed := FOUND;
  END IF;

  IF v_changed THEN
    INSERT INTO public.summer_lottery_operator_grant_audit (
      campaign_id,
      target_user_id,
      actor_user_id,
      capability,
      operation
    ) VALUES (
      p_campaign_id,
      p_target_user_id,
      p_actor_user_id,
      p_capability,
      CASE WHEN p_enabled THEN 'grant' ELSE 'revoke' END
    );
  END IF;

  RETURN jsonb_build_object(
    'campaignId', p_campaign_id,
    'targetUserId', p_target_user_id,
    'capability', p_capability,
    'enabled', p_enabled,
    'changed', v_changed
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.list_summer_lottery_operator_grants(
  p_campaign_id TEXT,
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
  IF NULLIF(btrim(COALESCE(p_campaign_id, '')), '') IS NULL
     OR p_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'invalid_lottery_operator_grant_request'
      USING ERRCODE = '22023';
  END IF;

  PERFORM 1
  FROM public.profiles
  WHERE id = p_actor_user_id AND role = 'super_admin'
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'lottery_operator_grant_admin_required'
      USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.summer_lottery_campaigns
    WHERE id = p_campaign_id
  ) THEN
    RAISE EXCEPTION 'campaign_not_found' USING ERRCODE = 'P0002';
  END IF;

  SELECT jsonb_build_object(
    'campaignId', p_campaign_id,
    'grants', COALESCE(jsonb_agg(jsonb_build_object(
      'userId', operator_grant.user_id,
      'username', profile.username,
      'capability', operator_grant.capability,
      'grantedBy', operator_grant.granted_by,
      'grantedAt', operator_grant.granted_at
    ) ORDER BY profile.username, operator_grant.user_id, operator_grant.capability), '[]'::JSONB)
  )
  INTO v_result
  FROM public.summer_lottery_operator_grants AS operator_grant
  JOIN public.profiles AS profile
    ON profile.id = operator_grant.user_id
  WHERE operator_grant.campaign_id = p_campaign_id;

  RETURN v_result;
END;
$$;

ALTER FUNCTION public.list_summer_lottery_contact_targets(TEXT)
  RENAME TO list_summer_lottery_contact_targets_internal;
ALTER FUNCTION public.read_summer_lottery_contact(UUID, UUID, TEXT)
  RENAME TO read_summer_lottery_contact_internal;
ALTER FUNCTION public.purge_summer_lottery_contact(UUID, UUID, TEXT)
  RENAME TO purge_summer_lottery_contact_internal;

CREATE OR REPLACE FUNCTION public.list_summer_lottery_contact_targets(
  p_campaign_id TEXT,
  p_actor_user_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;

  PERFORM public.require_summer_lottery_operator_capability(
    p_campaign_id,
    p_actor_user_id,
    'contact_read'
  );

  RETURN public.list_summer_lottery_contact_targets_internal(p_campaign_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.read_summer_lottery_contact(
  p_entry_id UUID,
  p_actor_user_id UUID,
  p_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_campaign_id TEXT;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;
  IF p_entry_id IS NULL OR p_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'invalid_contact_access_request' USING ERRCODE = '22023';
  END IF;

  SELECT campaign_id
  INTO v_campaign_id
  FROM public.summer_lottery_entries
  WHERE id = p_entry_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'contact_entry_not_available' USING ERRCODE = 'P0002';
  END IF;

  PERFORM public.require_summer_lottery_operator_capability(
    v_campaign_id,
    p_actor_user_id,
    'contact_read'
  );

  RETURN public.read_summer_lottery_contact_internal(
    p_entry_id,
    p_actor_user_id,
    p_reason
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.purge_summer_lottery_contact(
  p_entry_id UUID,
  p_actor_user_id UUID,
  p_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_campaign_id TEXT;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;
  IF p_entry_id IS NULL OR p_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'invalid_contact_purge_request' USING ERRCODE = '22023';
  END IF;

  SELECT campaign_id
  INTO v_campaign_id
  FROM public.summer_lottery_entries
  WHERE id = p_entry_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'contact_entry_not_available' USING ERRCODE = 'P0002';
  END IF;

  PERFORM public.require_summer_lottery_operator_capability(
    v_campaign_id,
    p_actor_user_id,
    'contact_purge'
  );

  RETURN public.purge_summer_lottery_contact_internal(
    p_entry_id,
    p_actor_user_id,
    p_reason
  );
END;
$$;

REVOKE ALL ON TABLE public.summer_lottery_operator_grants
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON TABLE public.summer_lottery_operator_grant_audit
  FROM PUBLIC, anon, authenticated, service_role;

REVOKE ALL ON FUNCTION public.has_summer_lottery_operator_capability(TEXT, UUID, TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.has_summer_lottery_operator_capability(TEXT, UUID, TEXT)
  TO service_role;

REVOKE ALL ON FUNCTION public.require_summer_lottery_operator_capability(TEXT, UUID, TEXT)
  FROM PUBLIC, anon, authenticated, service_role;

REVOKE ALL ON FUNCTION public.set_summer_lottery_operator_capability(TEXT, UUID, TEXT, BOOLEAN, UUID)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_summer_lottery_operator_capability(TEXT, UUID, TEXT, BOOLEAN, UUID)
  TO service_role;

REVOKE ALL ON FUNCTION public.list_summer_lottery_operator_grants(TEXT, UUID)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.list_summer_lottery_operator_grants(TEXT, UUID)
  TO service_role;

REVOKE ALL ON FUNCTION public.list_summer_lottery_contact_targets_internal(TEXT)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.read_summer_lottery_contact_internal(UUID, UUID, TEXT)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.purge_summer_lottery_contact_internal(UUID, UUID, TEXT)
  FROM PUBLIC, anon, authenticated, service_role;

REVOKE ALL ON FUNCTION public.list_summer_lottery_contact_targets(TEXT, UUID)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.list_summer_lottery_contact_targets(TEXT, UUID)
  TO service_role;

REVOKE ALL ON FUNCTION public.read_summer_lottery_contact(UUID, UUID, TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.read_summer_lottery_contact(UUID, UUID, TEXT)
  TO service_role;

REVOKE ALL ON FUNCTION public.purge_summer_lottery_contact(UUID, UUID, TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.purge_summer_lottery_contact(UUID, UUID, TEXT)
  TO service_role;

COMMENT ON TABLE public.summer_lottery_operator_grants IS
  '按活动授予的兑奖最小权限；不从 profiles.role 自动继承。';
COMMENT ON TABLE public.summer_lottery_operator_grant_audit IS
  '兑奖权限授予与撤销的追加式审计。';
COMMENT ON FUNCTION public.set_summer_lottery_operator_capability(TEXT, UUID, TEXT, BOOLEAN, UUID) IS
  '由当前超级管理员 actor 原子授予或撤销兑奖最小权限并写入审计。';

COMMIT;
