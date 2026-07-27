BEGIN;

ALTER TABLE public.summer_lottery_campaigns
  ADD COLUMN IF NOT EXISTS contact_retention_until TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS contacts_cleared_at TIMESTAMPTZ;

UPDATE public.summer_lottery_campaigns
SET contact_retention_until = draws_at + INTERVAL '30 days'
WHERE contact_retention_until IS NULL;

ALTER TABLE public.summer_lottery_campaigns
  ALTER COLUMN contact_retention_until SET NOT NULL,
  DROP CONSTRAINT IF EXISTS summer_lottery_campaigns_contact_retention_check;

ALTER TABLE public.summer_lottery_campaigns
  ADD CONSTRAINT summer_lottery_campaigns_contact_retention_check CHECK (
    contact_retention_until >= draws_at
    AND (contacts_cleared_at IS NULL OR contacts_cleared_at >= drawn_at)
  );

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.summer_lottery_entries
    WHERE contact_value IS NOT NULL
      AND NOT (
        char_length(contact_value) BETWEEN 50 AND 2048
        AND contact_value ~ '^olc1\.[A-Za-z0-9_-]{1,32}\.[A-Za-z0-9_-]{16}\.[A-Za-z0-9_-]{3}[A-Za-z0-9_-]*\.[A-Za-z0-9_-]{22}$'
      )
  ) THEN
    RAISE EXCEPTION 'unencrypted_summer_lottery_contacts_require_manual_migration'
      USING ERRCODE = '55000';
  END IF;
END;
$$;

ALTER TABLE public.summer_lottery_entries
  ALTER COLUMN contact_value DROP NOT NULL,
  DROP CONSTRAINT IF EXISTS summer_lottery_entries_contact_value_check,
  DROP CONSTRAINT IF EXISTS summer_lottery_entries_contact_envelope_check;

ALTER TABLE public.summer_lottery_entries
  ADD CONSTRAINT summer_lottery_entries_contact_envelope_check CHECK (
    contact_value IS NULL
    OR (
      char_length(contact_value) BETWEEN 50 AND 2048
      AND contact_value ~ '^olc1\.[A-Za-z0-9_-]{1,32}\.[A-Za-z0-9_-]{16}\.[A-Za-z0-9_-]{3}[A-Za-z0-9_-]*\.[A-Za-z0-9_-]{22}$'
    )
  );

CREATE TABLE IF NOT EXISTS public.summer_lottery_contact_access_audit (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id TEXT NOT NULL,
  entry_id UUID,
  actor_user_id UUID,
  operation TEXT NOT NULL CHECK (
    operation IN ('contact_read', 'contact_manual_purge', 'contact_retention_purge')
  ),
  reason TEXT NOT NULL CHECK (
    char_length(reason) BETWEEN 3 AND 200
    AND reason !~ E'[\r\n]'
  ),
  affected_count INTEGER NOT NULL DEFAULT 1 CHECK (affected_count >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_summer_lottery_contact_audit_campaign
  ON public.summer_lottery_contact_access_audit (campaign_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_summer_lottery_contact_audit_entry
  ON public.summer_lottery_contact_access_audit (entry_id, created_at DESC)
  WHERE entry_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_summer_lottery_contact_retention_due
  ON public.summer_lottery_campaigns (contact_retention_until)
  WHERE contacts_cleared_at IS NULL;

ALTER TABLE public.summer_lottery_contact_access_audit ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.prevent_summer_lottery_contact_audit_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  RAISE EXCEPTION 'summer_lottery_contact_audit_immutable'
    USING ERRCODE = '55000';
END;
$$;

DROP TRIGGER IF EXISTS trg_summer_lottery_contact_audit_no_update_delete
  ON public.summer_lottery_contact_access_audit;
CREATE TRIGGER trg_summer_lottery_contact_audit_no_update_delete
BEFORE UPDATE OR DELETE ON public.summer_lottery_contact_access_audit
FOR EACH ROW
EXECUTE FUNCTION public.prevent_summer_lottery_contact_audit_mutation();

DROP TRIGGER IF EXISTS trg_summer_lottery_contact_audit_no_truncate
  ON public.summer_lottery_contact_access_audit;
CREATE TRIGGER trg_summer_lottery_contact_audit_no_truncate
BEFORE TRUNCATE ON public.summer_lottery_contact_access_audit
FOR EACH STATEMENT
EXECUTE FUNCTION public.prevent_summer_lottery_contact_audit_mutation();

CREATE OR REPLACE FUNCTION public.list_summer_lottery_contact_targets(
  p_campaign_id TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_result JSONB;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;

  IF NULLIF(btrim(COALESCE(p_campaign_id, '')), '') IS NULL THEN
    RAISE EXCEPTION 'campaign_id_required' USING ERRCODE = '22023';
  END IF;

  SELECT jsonb_build_object(
    'campaignId', campaign.id,
    'contactRetentionUntil', campaign.contact_retention_until,
    'contactsClearedAt', campaign.contacts_cleared_at,
    'targets', COALESCE(jsonb_agg(jsonb_build_object(
      'entryId', entry.id,
      'publicId', entry.public_id,
      'entryNumber', entry.entry_number,
      'prizeTier', winner.prize_tier,
      'winnerOrder', winner.winner_order,
      'claimStatus', winner.claim_status,
      'contactType', entry.contact_type,
      'contactAvailable', entry.contact_value IS NOT NULL
    ) ORDER BY winner.prize_tier, winner.winner_order)
      FILTER (WHERE entry.id IS NOT NULL), '[]'::JSONB)
  )
  INTO v_result
  FROM public.summer_lottery_campaigns AS campaign
  LEFT JOIN public.summer_lottery_winners AS winner
    ON winner.campaign_id = campaign.id
  LEFT JOIN public.summer_lottery_entries AS entry
    ON entry.id = winner.entry_id
  WHERE campaign.id = p_campaign_id
  GROUP BY campaign.id;

  IF v_result IS NULL THEN
    RAISE EXCEPTION 'campaign_not_found' USING ERRCODE = 'P0002';
  END IF;

  RETURN v_result;
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
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_entry RECORD;
  v_reason TEXT := NULLIF(btrim(COALESCE(p_reason, '')), '');
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;

  IF p_entry_id IS NULL
     OR p_actor_user_id IS NULL
     OR v_reason IS NULL
     OR char_length(v_reason) NOT BETWEEN 3 AND 200
     OR v_reason ~ E'[\r\n]' THEN
    RAISE EXCEPTION 'invalid_contact_access_request' USING ERRCODE = '22023';
  END IF;

  SELECT
    entry.id,
    entry.campaign_id,
    entry.contact_type,
    entry.contact_value,
    campaign.contact_retention_until,
    winner.claim_status
  INTO v_entry
  FROM public.summer_lottery_entries AS entry
  JOIN public.summer_lottery_campaigns AS campaign
    ON campaign.id = entry.campaign_id
  JOIN public.summer_lottery_winners AS winner
    ON winner.entry_id = entry.id
   AND winner.campaign_id = entry.campaign_id
  WHERE entry.id = p_entry_id
    AND campaign.status = 'drawn'
    AND campaign.drawn_at IS NOT NULL
  FOR SHARE OF entry, campaign, winner;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'contact_entry_not_available' USING ERRCODE = 'P0002';
  END IF;
  IF NOW() >= v_entry.contact_retention_until THEN
    RAISE EXCEPTION 'contact_retention_expired' USING ERRCODE = '55000';
  END IF;
  IF v_entry.contact_value IS NULL THEN
    RAISE EXCEPTION 'contact_already_cleared' USING ERRCODE = '55000';
  END IF;

  INSERT INTO public.summer_lottery_contact_access_audit (
    campaign_id, entry_id, actor_user_id, operation, reason, affected_count
  ) VALUES (
    v_entry.campaign_id, v_entry.id, p_actor_user_id,
    'contact_read', v_reason, 1
  );

  RETURN jsonb_build_object(
    'entryId', v_entry.id,
    'campaignId', v_entry.campaign_id,
    'contactType', v_entry.contact_type,
    'contactValue', v_entry.contact_value,
    'claimStatus', v_entry.claim_status,
    'contactRetentionUntil', v_entry.contact_retention_until
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.inspect_summer_lottery_contact_storage(
  p_campaign_id TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_result JSONB;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'campaignId', p_campaign_id,
    'entryCount', COUNT(*),
    'encryptedCount', COUNT(*) FILTER (
      WHERE contact_value ~ '^olc1\.[A-Za-z0-9_-]{1,32}\.[A-Za-z0-9_-]{16}\.[A-Za-z0-9_-]{3}[A-Za-z0-9_-]*\.[A-Za-z0-9_-]{22}$'
    ),
    'clearedCount', COUNT(*) FILTER (WHERE contact_value IS NULL),
    'invalidCount', COUNT(*) FILTER (
      WHERE contact_value IS NOT NULL
        AND contact_value !~ '^olc1\.[A-Za-z0-9_-]{1,32}\.[A-Za-z0-9_-]{16}\.[A-Za-z0-9_-]{3}[A-Za-z0-9_-]*\.[A-Za-z0-9_-]{22}$'
    )
  )
  INTO v_result
  FROM public.summer_lottery_entries
  WHERE campaign_id = p_campaign_id;

  RETURN v_result;
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
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_entry RECORD;
  v_reason TEXT := NULLIF(btrim(COALESCE(p_reason, '')), '');
  v_cleared BOOLEAN := FALSE;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;

  IF p_entry_id IS NULL
     OR p_actor_user_id IS NULL
     OR v_reason IS NULL
     OR char_length(v_reason) NOT BETWEEN 3 AND 200
     OR v_reason ~ E'[\r\n]' THEN
    RAISE EXCEPTION 'invalid_contact_purge_request' USING ERRCODE = '22023';
  END IF;

  SELECT entry.id, entry.campaign_id, entry.contact_value
  INTO v_entry
  FROM public.summer_lottery_entries AS entry
  JOIN public.summer_lottery_winners AS winner
    ON winner.entry_id = entry.id
   AND winner.campaign_id = entry.campaign_id
  WHERE entry.id = p_entry_id
  FOR UPDATE OF entry;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'contact_entry_not_available' USING ERRCODE = 'P0002';
  END IF;

  IF v_entry.contact_value IS NOT NULL THEN
    UPDATE public.summer_lottery_entries
    SET contact_value = NULL
    WHERE id = v_entry.id;
    v_cleared := TRUE;

    INSERT INTO public.summer_lottery_contact_access_audit (
      campaign_id, entry_id, actor_user_id, operation, reason, affected_count
    ) VALUES (
      v_entry.campaign_id, v_entry.id, p_actor_user_id,
      'contact_manual_purge', v_reason, 1
    );
  END IF;

  RETURN jsonb_build_object(
    'entryId', v_entry.id,
    'campaignId', v_entry.campaign_id,
    'cleared', v_cleared
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.purge_expired_summer_lottery_contacts(
  p_campaign_id TEXT,
  p_actor_user_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_campaign public.summer_lottery_campaigns%ROWTYPE;
  v_cleared_count INTEGER := 0;
  v_cleared_at TIMESTAMPTZ;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_campaign
  FROM public.summer_lottery_campaigns
  WHERE id = p_campaign_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'campaign_not_found' USING ERRCODE = 'P0002';
  END IF;
  IF v_campaign.status NOT IN ('drawn', 'cancelled') THEN
    RAISE EXCEPTION 'contact_campaign_not_ready_for_cleanup' USING ERRCODE = '55000';
  END IF;
  IF NOW() < v_campaign.contact_retention_until THEN
    RAISE EXCEPTION 'contact_retention_not_reached' USING ERRCODE = '55000';
  END IF;

  UPDATE public.summer_lottery_entries
  SET contact_value = NULL
  WHERE campaign_id = p_campaign_id
    AND contact_value IS NOT NULL;
  GET DIAGNOSTICS v_cleared_count = ROW_COUNT;

  IF v_cleared_count > 0 THEN
    INSERT INTO public.summer_lottery_contact_access_audit (
      campaign_id, entry_id, actor_user_id, operation, reason, affected_count
    ) VALUES (
      p_campaign_id, NULL, p_actor_user_id,
      'contact_retention_purge', 'retention_expiry_cleanup', v_cleared_count
    );
  END IF;

  UPDATE public.summer_lottery_campaigns
  SET contacts_cleared_at = COALESCE(contacts_cleared_at, NOW()),
      updated_at = NOW()
  WHERE id = p_campaign_id
  RETURNING contacts_cleared_at INTO v_cleared_at;

  RETURN jsonb_build_object(
    'campaignId', p_campaign_id,
    'clearedCount', v_cleared_count,
    'contactsClearedAt', v_cleared_at
  );
END;
$$;

REVOKE ALL ON TABLE public.summer_lottery_contact_access_audit
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.summer_lottery_contact_access_audit TO service_role;

REVOKE ALL ON TABLE public.summer_lottery_entries FROM service_role;
GRANT SELECT (
  id, public_id, entry_number, campaign_id, user_id,
  notification_confirmed_at, eligible, created_at
) ON TABLE public.summer_lottery_entries TO service_role;
REVOKE ALL ON SEQUENCE public.summer_lottery_entries_entry_number_seq FROM service_role;

REVOKE ALL ON FUNCTION public.prevent_summer_lottery_contact_audit_mutation()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.list_summer_lottery_contact_targets(TEXT)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.read_summer_lottery_contact(UUID, UUID, TEXT)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.inspect_summer_lottery_contact_storage(TEXT)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.purge_summer_lottery_contact(UUID, UUID, TEXT)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.purge_expired_summer_lottery_contacts(TEXT, UUID)
  FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.list_summer_lottery_contact_targets(TEXT)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.read_summer_lottery_contact(UUID, UUID, TEXT)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.inspect_summer_lottery_contact_storage(TEXT)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.purge_summer_lottery_contact(UUID, UUID, TEXT)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.purge_expired_summer_lottery_contacts(TEXT, UUID)
  TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
