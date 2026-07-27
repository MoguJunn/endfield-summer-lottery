BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS public.summer_lottery_campaigns (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  starts_at TIMESTAMPTZ NOT NULL,
  closes_at TIMESTAMPTZ NOT NULL,
  draws_at TIMESTAMPTZ NOT NULL,
  status TEXT NOT NULL DEFAULT 'scheduled'
    CHECK (status IN ('scheduled', 'open', 'closed', 'drawn', 'cancelled')),
  prize_plan JSONB NOT NULL DEFAULT '{"first":2,"second":2}'::JSONB,
  seed_commitment TEXT,
  seed_reveal TEXT,
  public_randomness_chain TEXT NOT NULL,
  public_randomness_round BIGINT NOT NULL CHECK (public_randomness_round > 0),
  public_randomness TEXT,
  public_randomness_signature TEXT,
  candidate_manifest_hash TEXT,
  drawn_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (starts_at < closes_at),
  CHECK (closes_at <= draws_at),
  CHECK ((prize_plan->>'first')::INTEGER >= 0),
  CHECK ((prize_plan->>'second')::INTEGER >= 0)
);

CREATE TABLE IF NOT EXISTS public.summer_lottery_entries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id UUID NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  entry_number BIGINT GENERATED ALWAYS AS IDENTITY,
  campaign_id TEXT NOT NULL REFERENCES public.summer_lottery_campaigns(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  contact_type TEXT NOT NULL CHECK (contact_type ~ '^[a-z][a-z0-9_-]{1,31}$'),
  contact_value TEXT NOT NULL CONSTRAINT summer_lottery_entries_contact_envelope_check CHECK (
    char_length(contact_value) BETWEEN 50 AND 2048
    AND contact_value ~ '^olc1\.[A-Za-z0-9_-]{1,32}\.[A-Za-z0-9_-]{16}\.[A-Za-z0-9_-]{3}[A-Za-z0-9_-]*\.[A-Za-z0-9_-]{22}$'
  ),
  notification_confirmed_at TIMESTAMPTZ,
  eligible BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (campaign_id, user_id),
  UNIQUE (campaign_id, entry_number)
);

CREATE TABLE IF NOT EXISTS public.summer_lottery_winners (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id TEXT NOT NULL REFERENCES public.summer_lottery_campaigns(id) ON DELETE CASCADE,
  entry_id UUID NOT NULL REFERENCES public.summer_lottery_entries(id) ON DELETE RESTRICT,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  prize_tier TEXT NOT NULL CHECK (prize_tier IN ('first', 'second')),
  winner_order INTEGER NOT NULL CHECK (winner_order > 0),
  claim_status TEXT NOT NULL DEFAULT 'pending'
    CHECK (claim_status IN ('pending', 'contacted', 'claimed', 'expired')),
  selected_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (campaign_id, user_id),
  UNIQUE (campaign_id, prize_tier, winner_order)
);

CREATE TABLE IF NOT EXISTS public.summer_lottery_sso_tickets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_hash TEXT NOT NULL UNIQUE,
  state_hash TEXT NOT NULL,
  audience TEXT NOT NULL,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  main_session_id UUID NOT NULL REFERENCES public.app_sessions(id) ON DELETE CASCADE,
  expires_at TIMESTAMPTZ NOT NULL,
  consumed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_summer_lottery_sso_ticket_expiry
  ON public.summer_lottery_sso_tickets (expires_at)
  WHERE consumed_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_summer_lottery_sso_one_pending_per_main_session
  ON public.summer_lottery_sso_tickets (main_session_id)
  WHERE consumed_at IS NULL;

CREATE TABLE IF NOT EXISTS public.summer_lottery_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  source_main_session_id UUID NOT NULL REFERENCES public.app_sessions(id) ON DELETE CASCADE,
  session_token_hash TEXT NOT NULL UNIQUE,
  csrf_token_hash TEXT NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  revoked_at TIMESTAMPTZ,
  revoke_reason TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_summer_lottery_sessions_user_active
  ON public.summer_lottery_sessions (user_id, expires_at DESC)
  WHERE revoked_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_summer_lottery_one_active_per_main_session
  ON public.summer_lottery_sessions (source_main_session_id)
  WHERE revoked_at IS NULL;

ALTER TABLE public.summer_lottery_campaigns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.summer_lottery_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.summer_lottery_winners ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.summer_lottery_sso_tickets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.summer_lottery_sessions ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.summer_lottery_campaigns FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.summer_lottery_entries FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.summer_lottery_winners FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.summer_lottery_sso_tickets FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.summer_lottery_sessions FROM PUBLIC, anon, authenticated;

GRANT ALL ON TABLE public.summer_lottery_campaigns TO service_role;
GRANT ALL ON TABLE public.summer_lottery_entries TO service_role;
GRANT ALL ON TABLE public.summer_lottery_winners TO service_role;
GRANT ALL ON TABLE public.summer_lottery_sso_tickets TO service_role;
GRANT ALL ON TABLE public.summer_lottery_sessions TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.summer_lottery_entries_entry_number_seq TO service_role;

CREATE OR REPLACE FUNCTION public.exchange_summer_lottery_sso_ticket(
  p_ticket_hash TEXT,
  p_state_hash TEXT,
  p_audience TEXT,
  p_session_token_hash TEXT,
  p_csrf_token_hash TEXT,
  p_expires_at TIMESTAMPTZ
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_ticket public.summer_lottery_sso_tickets%ROWTYPE;
  v_main_session public.app_sessions%ROWTYPE;
  v_session public.summer_lottery_sessions%ROWTYPE;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;

  UPDATE public.summer_lottery_sso_tickets AS ticket
  SET consumed_at = NOW()
  WHERE ticket.ticket_hash = p_ticket_hash
    AND ticket.state_hash = p_state_hash
    AND ticket.audience = p_audience
    AND ticket.consumed_at IS NULL
    AND ticket.expires_at > NOW()
  RETURNING ticket.* INTO v_ticket;

  IF v_ticket.id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_main_session
  FROM public.app_sessions
  WHERE id = v_ticket.main_session_id
    AND user_id = v_ticket.user_id
    AND revoked_at IS NULL
    AND expires_at > NOW()
    AND absolute_expires_at > NOW()
  FOR SHARE;

  IF v_main_session.id IS NULL THEN
    RAISE EXCEPTION 'source_main_session_invalid' USING ERRCODE = '28000';
  END IF;

  IF p_session_token_hash !~ '^[0-9a-f]{64}$'
     OR p_csrf_token_hash !~ '^[0-9a-f]{64}$'
     OR p_expires_at <= NOW()
     OR p_expires_at > NOW() + INTERVAL '30 days' THEN
    RAISE EXCEPTION 'invalid_lottery_session_material' USING ERRCODE = '22023';
  END IF;

  UPDATE public.summer_lottery_sessions
  SET revoked_at = NOW(), revoke_reason = 'replaced_by_new_sso_session'
  WHERE source_main_session_id = v_ticket.main_session_id
    AND revoked_at IS NULL;

  INSERT INTO public.summer_lottery_sessions (
    user_id,
    source_main_session_id,
    session_token_hash,
    csrf_token_hash,
    expires_at
  ) VALUES (
    v_ticket.user_id,
    v_ticket.main_session_id,
    p_session_token_hash,
    p_csrf_token_hash,
    LEAST(p_expires_at, v_main_session.absolute_expires_at)
  )
  RETURNING * INTO v_session;

  RETURN jsonb_build_object(
    'userId', v_ticket.user_id,
    'mainSessionId', v_ticket.main_session_id,
    'lotterySessionId', v_session.id,
    'expiresAt', v_session.expires_at,
    'audience', v_ticket.audience,
    'ticketExpiresAt', v_ticket.expires_at
  );
END;
$$;

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

CREATE OR REPLACE FUNCTION public.prepare_summer_lottery(
  p_campaign_id TEXT,
  p_seed_commitment TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_campaign public.summer_lottery_campaigns%ROWTYPE;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;

  IF p_seed_commitment !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'invalid_seed_commitment' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_campaign
  FROM public.summer_lottery_campaigns
  WHERE id = p_campaign_id
  FOR UPDATE;

  IF v_campaign.id IS NULL THEN
    RAISE EXCEPTION 'campaign_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.summer_lottery_entries WHERE campaign_id = p_campaign_id
  ) THEN
    RAISE EXCEPTION 'campaign_already_has_entries' USING ERRCODE = '55000';
  END IF;

  IF v_campaign.seed_commitment IS NOT NULL
     AND v_campaign.seed_commitment <> p_seed_commitment THEN
    RAISE EXCEPTION 'seed_commitment_already_fixed' USING ERRCODE = '55000';
  END IF;

  UPDATE public.summer_lottery_campaigns
  SET seed_commitment = p_seed_commitment,
      status = CASE WHEN NOW() >= starts_at THEN 'open' ELSE 'scheduled' END,
      updated_at = NOW()
  WHERE id = p_campaign_id
  RETURNING * INTO v_campaign;

  RETURN jsonb_build_object(
    'campaignId', v_campaign.id,
    'seedCommitment', v_campaign.seed_commitment,
    'status', v_campaign.status
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.draw_summer_lottery(
  p_campaign_id TEXT,
  p_seed TEXT,
  p_beacon_round BIGINT,
  p_beacon_randomness TEXT,
  p_beacon_signature TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_campaign public.summer_lottery_campaigns%ROWTYPE;
  v_first_count INTEGER;
  v_second_count INTEGER;
  v_entry_count INTEGER;
  v_candidate_manifest_hash TEXT;
  v_result JSONB;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_campaign
  FROM public.summer_lottery_campaigns
  WHERE id = p_campaign_id
  FOR UPDATE;

  IF v_campaign.id IS NULL THEN
    RAISE EXCEPTION 'campaign_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF v_campaign.drawn_at IS NOT NULL OR EXISTS (
    SELECT 1 FROM public.summer_lottery_winners WHERE campaign_id = p_campaign_id
  ) THEN
    IF v_campaign.seed_reveal = p_seed
       AND v_campaign.public_randomness_round = p_beacon_round
       AND v_campaign.public_randomness = p_beacon_randomness THEN
      SELECT jsonb_build_object(
        'campaignId', p_campaign_id,
        'entryCount', (
          SELECT COUNT(*) FROM public.summer_lottery_entries
          WHERE campaign_id = p_campaign_id AND eligible = TRUE
        ),
        'drawnAt', v_campaign.drawn_at,
        'seedCommitment', v_campaign.seed_commitment,
        'seedReveal', v_campaign.seed_reveal,
        'publicRandomnessChain', v_campaign.public_randomness_chain,
        'publicRandomnessRound', v_campaign.public_randomness_round,
        'publicRandomness', v_campaign.public_randomness,
        'publicRandomnessSignature', v_campaign.public_randomness_signature,
        'candidateManifestHash', v_campaign.candidate_manifest_hash,
        'winners', COALESCE(jsonb_agg(jsonb_build_object(
          'userId', winner.user_id,
          'entryId', winner.entry_id,
          'prizeTier', winner.prize_tier,
          'winnerOrder', winner.winner_order
        ) ORDER BY winner.prize_tier, winner.winner_order), '[]'::JSONB)
      ) INTO v_result
      FROM public.summer_lottery_winners AS winner
      WHERE winner.campaign_id = p_campaign_id;
      RETURN v_result;
    END IF;
    RAISE EXCEPTION 'campaign_already_drawn' USING ERRCODE = '55000';
  END IF;

  IF NOW() < v_campaign.draws_at THEN
    RAISE EXCEPTION 'draw_not_open' USING ERRCODE = '55000';
  END IF;

  IF v_campaign.seed_commitment IS NULL
     OR encode(digest(p_seed, 'sha256'), 'hex') <> v_campaign.seed_commitment THEN
    RAISE EXCEPTION 'seed_commitment_mismatch' USING ERRCODE = '22023';
  END IF;

  IF p_beacon_round <> v_campaign.public_randomness_round
     OR p_beacon_randomness !~ '^[0-9a-f]{64}$'
     OR p_beacon_signature !~ '^[0-9a-f]+$'
     OR length(p_beacon_signature) % 2 <> 0 THEN
    RAISE EXCEPTION 'public_randomness_invalid' USING ERRCODE = '22023';
  END IF;

  IF encode(digest(decode(p_beacon_signature, 'hex'), 'sha256'), 'hex') <> p_beacon_randomness THEN
    RAISE EXCEPTION 'public_randomness_invalid' USING ERRCODE = '22023';
  END IF;

  v_first_count := GREATEST(0, COALESCE((v_campaign.prize_plan->>'first')::INTEGER, 2));
  v_second_count := GREATEST(0, COALESCE((v_campaign.prize_plan->>'second')::INTEGER, 2));

  SELECT COUNT(*)::INTEGER INTO v_entry_count
  FROM public.summer_lottery_entries
  WHERE campaign_id = p_campaign_id AND eligible = TRUE;

  IF v_entry_count = 0 THEN
    RAISE EXCEPTION 'campaign_has_no_entries' USING ERRCODE = '55000';
  END IF;

  SELECT encode(digest(string_agg(public_id::TEXT, E'\n' ORDER BY public_id::TEXT), 'sha256'), 'hex')
  INTO v_candidate_manifest_hash
  FROM public.summer_lottery_entries
  WHERE campaign_id = p_campaign_id AND eligible = TRUE;

  WITH ranked AS MATERIALIZED (
    SELECT
      entry.id,
      entry.user_id,
      ROW_NUMBER() OVER (
        ORDER BY digest(
          p_seed || ':' || p_beacon_randomness || ':' || entry.public_id::TEXT,
          'sha256'
        ), entry.public_id
      ) AS rank_number
    FROM public.summer_lottery_entries AS entry
    WHERE entry.campaign_id = p_campaign_id AND entry.eligible = TRUE
  )
  INSERT INTO public.summer_lottery_winners (
    campaign_id,
    entry_id,
    user_id,
    prize_tier,
    winner_order
  )
  SELECT
    p_campaign_id,
    ranked.id,
    ranked.user_id,
    CASE WHEN ranked.rank_number <= v_first_count THEN 'first' ELSE 'second' END,
    CASE
      WHEN ranked.rank_number <= v_first_count THEN ranked.rank_number::INTEGER
      ELSE (ranked.rank_number - v_first_count)::INTEGER
    END
  FROM ranked
  WHERE ranked.rank_number <= v_first_count + v_second_count;

  UPDATE public.summer_lottery_campaigns
  SET status = 'drawn',
      seed_reveal = p_seed,
      public_randomness = p_beacon_randomness,
      public_randomness_signature = p_beacon_signature,
      candidate_manifest_hash = v_candidate_manifest_hash,
      drawn_at = NOW(),
      updated_at = NOW()
  WHERE id = p_campaign_id
  RETURNING * INTO v_campaign;

  SELECT jsonb_build_object(
    'campaignId', p_campaign_id,
    'entryCount', v_entry_count,
    'drawnAt', v_campaign.drawn_at,
    'seedCommitment', v_campaign.seed_commitment,
    'seedReveal', v_campaign.seed_reveal,
    'publicRandomnessChain', v_campaign.public_randomness_chain,
    'publicRandomnessRound', v_campaign.public_randomness_round,
    'publicRandomness', v_campaign.public_randomness,
    'publicRandomnessSignature', v_campaign.public_randomness_signature,
    'candidateManifestHash', v_campaign.candidate_manifest_hash,
    'winners', COALESCE(jsonb_agg(jsonb_build_object(
      'userId', winner.user_id,
      'entryId', winner.entry_id,
      'prizeTier', winner.prize_tier,
      'winnerOrder', winner.winner_order
    ) ORDER BY winner.prize_tier, winner.winner_order), '[]'::JSONB)
  ) INTO v_result
  FROM public.summer_lottery_winners AS winner
  WHERE winner.campaign_id = p_campaign_id;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.exchange_summer_lottery_sso_ticket(TEXT, TEXT, TEXT, TEXT, TEXT, TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.enter_summer_lottery(TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.prepare_summer_lottery(TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.draw_summer_lottery(TEXT, TEXT, BIGINT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exchange_summer_lottery_sso_ticket(TEXT, TEXT, TEXT, TEXT, TEXT, TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION public.enter_summer_lottery(TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN) TO service_role;
GRANT EXECUTE ON FUNCTION public.prepare_summer_lottery(TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.draw_summer_lottery(TEXT, TEXT, BIGINT, TEXT, TEXT) TO service_role;

INSERT INTO public.summer_lottery_campaigns (
  id,
  title,
  starts_at,
  closes_at,
  draws_at,
  status,
  prize_plan,
  public_randomness_chain,
  public_randomness_round
)
VALUES (
  'community-lottery',
  'Community Lottery Example',
  TIMESTAMPTZ '2020-01-01 00:00:00+00',
  TIMESTAMPTZ '2099-12-31 23:00:00+00',
  TIMESTAMPTZ '2099-12-31 23:00:00+00',
  'scheduled',
  '{"first":2,"second":2}'::JSONB,
  '52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971',
  31618612
)
ON CONFLICT (id) DO NOTHING;

NOTIFY pgrst, 'reload schema';

COMMIT;
