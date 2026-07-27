BEGIN;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.summer_lottery_entries
    WHERE contact_value !~ '^olc1\.[A-Za-z0-9_-]{1,32}\.[A-Za-z0-9_-]{16}\.[A-Za-z0-9_-]{3}[A-Za-z0-9_-]*\.[A-Za-z0-9_-]{22}$'
  ) THEN
    RAISE EXCEPTION 'unencrypted_summer_lottery_contacts_require_manual_migration'
      USING ERRCODE = '55000';
  END IF;
END;
$$;

ALTER TABLE public.summer_lottery_entries
  DROP CONSTRAINT IF EXISTS summer_lottery_entries_contact_value_check,
  DROP CONSTRAINT IF EXISTS summer_lottery_entries_contact_envelope_check;

ALTER TABLE public.summer_lottery_entries
  ADD CONSTRAINT summer_lottery_entries_contact_envelope_check CHECK (
    char_length(contact_value) BETWEEN 50 AND 2048
    AND contact_value ~ '^olc1\.[A-Za-z0-9_-]{1,32}\.[A-Za-z0-9_-]{16}\.[A-Za-z0-9_-]{3}[A-Za-z0-9_-]*\.[A-Za-z0-9_-]{22}$'
  );

CREATE OR REPLACE FUNCTION public.enter_summer_lottery(
  p_campaign_id TEXT,
  p_session_token_hash TEXT,
  p_csrf_token_hash TEXT,
  p_contact_type TEXT,
  p_contact_value TEXT,
  p_notification_confirmed BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_campaign public.summer_lottery_campaigns%ROWTYPE;
  v_session public.summer_lottery_sessions%ROWTYPE;
  v_entry public.summer_lottery_entries%ROWTYPE;
  v_already_entered BOOLEAN := FALSE;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;

  SELECT lottery_session.* INTO v_session
  FROM public.summer_lottery_sessions AS lottery_session
  JOIN public.app_sessions AS main_session
    ON main_session.id = lottery_session.source_main_session_id
   AND main_session.user_id = lottery_session.user_id
  WHERE lottery_session.session_token_hash = p_session_token_hash
    AND lottery_session.csrf_token_hash = p_csrf_token_hash
    AND lottery_session.revoked_at IS NULL
    AND lottery_session.expires_at > NOW()
    AND main_session.revoked_at IS NULL
    AND main_session.expires_at > NOW()
    AND main_session.absolute_expires_at > NOW()
  FOR SHARE OF lottery_session, main_session;

  IF v_session.id IS NULL THEN
    RAISE EXCEPTION 'lottery_session_invalid' USING ERRCODE = '28000';
  END IF;

  IF COALESCE(p_contact_type, '') !~ '^[a-z][a-z0-9_-]{1,31}$'
     OR char_length(COALESCE(p_contact_value, '')) NOT BETWEEN 50 AND 2048
     OR COALESCE(p_contact_value, '') !~ '^olc1\.[A-Za-z0-9_-]{1,32}\.[A-Za-z0-9_-]{16}\.[A-Za-z0-9_-]{3}[A-Za-z0-9_-]*\.[A-Za-z0-9_-]{22}$' THEN
    RAISE EXCEPTION 'invalid_contact_value' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_campaign
  FROM public.summer_lottery_campaigns
  WHERE id = p_campaign_id
  FOR SHARE;

  IF v_campaign.id IS NULL THEN
    RAISE EXCEPTION 'campaign_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF v_campaign.status IN ('closed', 'cancelled', 'drawn')
     OR v_campaign.seed_commitment IS NULL
     OR NOW() < v_campaign.starts_at
     OR NOW() >= v_campaign.closes_at THEN
    RAISE EXCEPTION 'campaign_not_open' USING ERRCODE = '55000';
  END IF;

  INSERT INTO public.summer_lottery_entries (
    campaign_id,
    user_id,
    contact_type,
    contact_value,
    notification_confirmed_at
  )
  VALUES (
    p_campaign_id,
    v_session.user_id,
    p_contact_type,
    p_contact_value,
    CASE WHEN COALESCE(p_notification_confirmed, FALSE) THEN NOW() ELSE NULL END
  )
  ON CONFLICT (campaign_id, user_id) DO NOTHING
  RETURNING * INTO v_entry;

  IF v_entry.id IS NULL THEN
    v_already_entered := TRUE;
    SELECT * INTO v_entry
    FROM public.summer_lottery_entries
    WHERE campaign_id = p_campaign_id AND user_id = v_session.user_id;
  END IF;

  RETURN jsonb_build_object(
    'id', v_entry.id,
    'publicId', v_entry.public_id,
    'entryNumber', v_entry.entry_number,
    'eligible', v_entry.eligible,
    'createdAt', v_entry.created_at,
    'alreadyEntered', v_already_entered
  );
END;
$$;

REVOKE ALL ON FUNCTION public.enter_summer_lottery(TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.enter_summer_lottery(TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN)
  TO service_role;

COMMIT;
