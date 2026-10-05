-- ============================================================================
-- Wipe completeness hardening (canonical run order item 45)
-- Replaces ONLY private.wipe_election_data(UUID, VARCHAR) body in-place.
-- Public wrapper signature remains unchanged.
-- ============================================================================

BEGIN;

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
  SELECT current_phase
    INTO v_phase
  FROM election_settings
  WHERE id = 1
  FOR UPDATE;

  IF NOT FOUND OR v_phase IS NULL THEN
    RAISE EXCEPTION 'Missing election settings row (id=1).';
  END IF;

  IF v_phase <> 'SETUP' THEN
    RAISE EXCEPTION 'Database wipe is only allowed during SETUP phase.';
  END IF;

  SELECT admin_session_id, confirmed_at, expires_at
    INTO v_token_record
  FROM wipe_confirmation_tokens
  WHERE admin_session_id = p_admin_id
    AND token_hash = p_token_hash
  FOR UPDATE;

  IF NOT FOUND OR v_token_record.confirmed_at IS NULL THEN
    RAISE EXCEPTION 'wipe not confirmed';
  END IF;

  IF v_token_record.expires_at <= clock_timestamp() THEN
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
    wipe_confirmation_tokens, admin_sessions, rate_limit_hits,
    anonymous_paper_blanks, anonymous_digital_credentials,
    digital_credential_reservations, nomination_adjudications,
    participation_audit, ballot_audit_log
    CASCADE;

  DELETE FROM members WHERE id IS NOT NULL;

  UPDATE election_settings SET current_phase = 'SETUP' WHERE id = 1;

  IF EXISTS (SELECT 1 FROM candidates)
    OR EXISTS (SELECT 1 FROM tokens)
    OR EXISTS (SELECT 1 FROM anonymous_nominations)
    OR EXISTS (SELECT 1 FROM ballots)
    OR EXISTS (SELECT 1 FROM paper_ballots)
    OR EXISTS (SELECT 1 FROM paper_ballot_batches)
    OR EXISTS (SELECT 1 FROM vote_audit_log)
    OR EXISTS (SELECT 1 FROM eligibility_adjudications)
    OR EXISTS (SELECT 1 FROM phase_change_tokens)
    OR EXISTS (SELECT 1 FROM wipe_confirmation_tokens)
    OR EXISTS (SELECT 1 FROM admin_sessions)
    OR EXISTS (SELECT 1 FROM rate_limit_hits)
    OR EXISTS (SELECT 1 FROM anonymous_paper_blanks)
    OR EXISTS (SELECT 1 FROM anonymous_digital_credentials)
    OR EXISTS (SELECT 1 FROM digital_credential_reservations)
    OR EXISTS (SELECT 1 FROM nomination_adjudications)
    OR EXISTS (SELECT 1 FROM participation_audit)
    OR EXISTS (SELECT 1 FROM ballot_audit_log)
    OR EXISTS (SELECT 1 FROM members WHERE id IS NOT NULL)
  THEN
    RAISE EXCEPTION 'wipe completeness check failed';
  END IF;

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
