-- Local-only main-site authentication prerequisites for the lottery E2E flow.
-- This file is copied to a temporary migration by scripts/local-e2e.ps1.

CREATE TABLE IF NOT EXISTS public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  username TEXT,
  email TEXT,
  role TEXT NOT NULL DEFAULT 'user' CHECK (role IN ('user', 'admin', 'super_admin')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_seen_at TIMESTAMPTZ
);

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY profiles_local_select ON public.profiles
  FOR SELECT USING (TRUE);
CREATE POLICY profiles_local_insert ON public.profiles
  FOR INSERT WITH CHECK (auth.uid() = id);
CREATE POLICY profiles_local_update ON public.profiles
  FOR UPDATE USING (auth.uid() = id) WITH CHECK (auth.uid() = id);

CREATE OR REPLACE FUNCTION public.handle_local_auth_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  INSERT INTO public.profiles (id, username, email, role)
  VALUES (
    NEW.id,
    COALESCE(NULLIF(NEW.raw_user_meta_data->>'username', ''), SPLIT_PART(NEW.email, '@', 1)),
    NEW.email,
    'user'
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_local_auth_user_created ON auth.users;
CREATE TRIGGER on_local_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_local_auth_user();

CREATE TABLE IF NOT EXISTS public.app_auth_identities (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  provider TEXT NOT NULL,
  provider_subject_hash TEXT NOT NULL,
  display_name TEXT,
  avatar_url TEXT,
  email_hash TEXT,
  email_verified BOOLEAN NOT NULL DEFAULT FALSE,
  raw_profile_hash TEXT,
  linked_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_used_at TIMESTAMPTZ,
  disabled_at TIMESTAMPTZ,
  metadata_redacted_json JSONB NOT NULL DEFAULT '{}'::JSONB,
  UNIQUE (provider, provider_subject_hash)
);

CREATE TABLE IF NOT EXISTS public.app_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  session_token_hash TEXT NOT NULL UNIQUE,
  refresh_token_hash TEXT UNIQUE,
  user_agent_hash TEXT,
  ip_prefix_hash TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_seen_at TIMESTAMPTZ,
  expires_at TIMESTAMPTZ NOT NULL,
  absolute_expires_at TIMESTAMPTZ NOT NULL,
  revoked_at TIMESTAMPTZ,
  revoke_reason TEXT
);

CREATE INDEX IF NOT EXISTS idx_local_app_sessions_active
  ON public.app_sessions (expires_at, absolute_expires_at)
  WHERE revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS public.app_auth_audit_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  event_type TEXT NOT NULL,
  provider TEXT,
  outcome TEXT NOT NULL,
  requester_hash TEXT,
  metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.app_auth_identities ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.app_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.app_auth_audit_events ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.app_auth_identities FROM anon, authenticated;
REVOKE ALL ON public.app_sessions FROM anon, authenticated;
REVOKE ALL ON public.app_auth_audit_events FROM anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.profiles TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.app_auth_identities TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.app_sessions TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.app_auth_audit_events TO service_role;
