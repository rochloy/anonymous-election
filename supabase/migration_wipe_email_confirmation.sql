-- ============================================================================
-- Wipe email confirmation hardening (canonical run order item 43)
-- Purpose: require email-possession confirmation for in-app Danger Zone wipe.
-- Replaces token-less wipe RPC signature with session+token-hash signature and
-- enforces confirmed, unexpired wipe_confirmation_tokens before any destructive
-- write. Run AFTER items 38, 40, 41, 42.
--
-- Rollback note: do NOT roll back by restoring token-less signatures. Repair
-- forward. SQL Editor reseed remains the fallback for full rebuilds.
-- ============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.wipe_confirmation_tokens (
  admin_session_id UUID PRIMARY KEY REFERENCES public.admin_sessions(id) ON DELETE CASCADE,
  token_hash VARCHAR(64) NOT NULL UNIQUE,
  expires_at TIMESTAMPTZ NOT NULL,
  confirmed_at TIMESTAMPTZ NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.wipe_confirmation_tokens ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.wipe_confirmation_tokens FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.wipe_confirmation_tokens TO service_role;

DROP FUNCTION IF EXISTS public.wipe_election_data(UUID);
DROP FUNCTION IF EXISTS private.wipe_election_data(UUID);

CREATE OR REPLACE FUNCTION private.wipe_election_data(
  p_admin_id UUID,
  p_token_hash VARCHAR
)
RETURNS TABLE (success BOOLEAN, message TEXT)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, private, governance, extensions
AS $$
DECLARE
  v_phase election_phase;
  v_token_record RECORD;
BEGIN
  SELECT current_phase INTO v_phase
  FROM election_settings
  WHERE id = 1
  FOR UPDATE;

  IF v_phase <> 'SETUP' THEN
    RAISE EXCEPTION 'Database wipe is only allowed during SETUP phase.';
  END IF;

  SELECT admin_session_id, confirmed_at, expires_at
  INTO v_token_record
  FROM wipe_confirmation_tokens
  WHERE admin_session_id = p_admin_id
    AND token_hash = p_token_hash;

  IF NOT FOUND OR v_token_record.confirmed_at IS NULL THEN
    RAISE EXCEPTION 'wipe not confirmed';
  END IF;

  IF v_token_record.expires_at <= now() THEN
    RAISE EXCEPTION 'wipe confirmation expired';
  END IF;

  PERFORM private.append_governance_event(
    'WIPE_STARTED', p_admin_id, 'admin', NULL, NULL,
    'Election data wipe for new-election setup', 'Legitimate interest',
    NULL, NULL, NULL,
    jsonb_build_object('scope', 'all election-scoped tables + members')
  );

  TRUNCATE candidates, tokens, anonymous_nominations, ballots, paper_ballots,
    paper_ballot_batches, vote_audit_log, eligibility_adjudications, phase_change_tokens,
    wipe_confirmation_tokens, admin_sessions, rate_limit_hits CASCADE;
  DELETE FROM members WHERE id IS NOT NULL;

  UPDATE election_settings SET current_phase = 'SETUP' WHERE id = 1;

  PERFORM private.append_governance_event(
    'WIPE_COMPLETED', p_admin_id, 'admin', NULL, NULL,
    'Election data wipe for new-election setup', 'Legitimate interest',
    NULL, NULL, NULL,
    jsonb_build_object('scope', 'all election-scoped tables + members', 'result', 'clean SETUP state')
  );

  RETURN QUERY SELECT TRUE, 'Election data wiped. Database is ready for a new election (SETUP phase). All admin sessions were revoked.'::TEXT;
END;
$$;

CREATE OR REPLACE FUNCTION public.wipe_election_data(
  p_admin_id UUID,
  p_token_hash VARCHAR
)
RETURNS TABLE (success BOOLEAN, message TEXT)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, private
AS $$
  SELECT * FROM private.wipe_election_data(p_admin_id, p_token_hash);
$$;

REVOKE EXECUTE ON FUNCTION private.wipe_election_data(UUID, VARCHAR) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.wipe_election_data(UUID, VARCHAR) TO service_role;

REVOKE EXECUTE ON FUNCTION public.wipe_election_data(UUID, VARCHAR) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.wipe_election_data(UUID, VARCHAR) TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
