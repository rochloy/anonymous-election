-- migration_token_reissue.sql  (Spec 2 — Token Reissue)
-- Run AFTER migration_nomination_submission.sql (which already added tokens.voided_at)
-- and migration_configurable_token_ttl.sql (voting_token_ttl_hours) and the current
-- submit_anonymous_vote definition (migration_opaque_ballot_ids.sql).
--
-- Provides a single shared admin void-and-reissue mechanism for VOTING + NOMINATION
-- tokens, with a DB-enforced single-active-token invariant.
--
-- NOTE: tokens.voided_at already exists (added by migration_nomination_submission.sql).
--       This migration adds the remaining columns + the invariant index + the RPCs.

-- ============================================================================
-- Task 1: schema columns + single-active-token invariant index
-- ============================================================================
ALTER TABLE tokens
  ADD COLUMN IF NOT EXISTS void_reason TEXT NULL,
  ADD COLUMN IF NOT EXISTS reissued_from_token_id UUID NULL REFERENCES tokens(id);

-- DB-enforced single-active-token invariant.
-- Predicate MUST NOT depend on volatile now()/expires_at (not IMMUTABLE).
-- Expired-but-not-voided tokens still "block" until an issuance/reissue tx voids them.
-- Preflight verified 0 duplicate active (member_id, type) groups on live data.
CREATE UNIQUE INDEX IF NOT EXISTS tokens_one_live_per_member_type
  ON tokens (member_id, type)
  WHERE is_used = FALSE AND voided_at IS NULL;

-- ============================================================================
-- Task 2: submit-side voided guard for the VOTING path (parity with submit_nomination)
-- Reproduces the current private.submit_anonymous_vote body verbatim and adds a
-- voided_at rejection so a reissued VOTING token's old link fails gracefully.
-- ============================================================================
CREATE OR REPLACE FUNCTION private.submit_anonymous_vote(p_token_hash character varying, p_candidate_id uuid)
 RETURNS TABLE(success boolean, message text, receipt_code text, ballot_id text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'extensions'
AS $function$
DECLARE
  v_token_id UUID;
  v_member_id UUID;
  v_is_used BOOLEAN;
  v_expires_at TIMESTAMPTZ;
  v_voided_at TIMESTAMPTZ;
  v_phase election_phase;
  v_voting_end TIMESTAMPTZ;
  v_receipt TEXT;
  v_ballot_id TEXT;
  v_payload TEXT;
  v_attempts INT := 0;
  v_insert_ok BOOLEAN := FALSE;
  v_paper_ballot RECORD;
BEGIN
  SELECT current_phase, voting_end INTO v_phase, v_voting_end FROM election_settings WHERE id = 1;

  IF v_phase != 'VOTING' OR (v_voting_end IS NOT NULL AND NOW() > v_voting_end) THEN
    RETURN QUERY SELECT FALSE, 'Voting phase is closed or expired.'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  SELECT id, member_id, is_used, expires_at, voided_at
    INTO v_token_id, v_member_id, v_is_used, v_expires_at, v_voided_at FROM tokens
  WHERE token_hash = p_token_hash AND type = 'VOTING' FOR UPDATE;

  IF v_token_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Invalid or non-existent voting token.'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  IF v_voided_at IS NOT NULL THEN
    RETURN QUERY SELECT FALSE, 'This voting token has been voided and reissued. Please use your most recent link.'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  IF v_expires_at IS NULL OR v_expires_at <= NOW() THEN
    RETURN QUERY SELECT FALSE, 'This voting token has expired.'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  IF v_is_used THEN
    RETURN QUERY SELECT FALSE, 'This token has already been used or reserved for paper voting.'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  SELECT * INTO v_paper_ballot FROM paper_ballots
  WHERE member_id = v_member_id AND status IN ('ISSUED', 'ISSUED_TO_VOTER', 'VOTED')
  FOR SHARE;

  IF FOUND THEN
    RETURN QUERY SELECT FALSE, 'A paper ballot has already been issued for this member.'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  v_payload := 'DIGITAL:' || encode(gen_random_bytes(32), 'hex');
  v_ballot_id := private.hmac_sign(v_payload);

  WHILE v_attempts < 5 AND NOT v_insert_ok LOOP
    v_receipt := 'VC-' || encode(gen_random_bytes(5), 'hex');
    BEGIN
      INSERT INTO ballots (ballot_id, candidate_id, receipt_code, channel, cast_date)
      VALUES (v_ballot_id, p_candidate_id, v_receipt, 'DIGITAL', CURRENT_DATE);
      v_insert_ok := TRUE;
    EXCEPTION WHEN unique_violation THEN
      v_attempts := v_attempts + 1;
    END;
  END LOOP;

  IF NOT v_insert_ok THEN
    RETURN QUERY SELECT FALSE, 'Could not generate unique receipt code after 5 attempts.'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  UPDATE tokens SET is_used = TRUE, used_at = NOW() WHERE id = v_token_id;

  RETURN QUERY SELECT TRUE, 'Vote cast successfully.'::TEXT, v_receipt, v_ballot_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION private.submit_anonymous_vote(character varying, uuid) TO service_role;

-- ============================================================================
-- Task 3: reissue_token RPC — atomic void-and-mint, one active token per (member,type)
-- ============================================================================
CREATE OR REPLACE FUNCTION private.reissue_token(
  p_old_token_id   UUID,
  p_admin_id       UUID,
  p_reason         TEXT,
  p_new_token_hash VARCHAR(64)
) RETURNS TABLE (success BOOLEAN, message TEXT)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_member_id   UUID;
  v_type        token_type;
  v_is_used     BOOLEAN;
  v_voided      TIMESTAMPTZ;
  v_ttl_hours   INT;
  v_new_expires TIMESTAMPTZ;
BEGIN
  SELECT member_id, type, is_used, voided_at
    INTO v_member_id, v_type, v_is_used, v_voided
    FROM tokens WHERE id = p_old_token_id FOR UPDATE;

  IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Token not found'; RETURN; END IF;
  IF v_is_used THEN RETURN QUERY SELECT FALSE, 'Used token cannot be reissued.'; RETURN; END IF;
  IF v_voided IS NOT NULL THEN RETURN QUERY SELECT FALSE, 'Token already voided.'; RETURN; END IF;

  -- Recompute expiry for the token TYPE (do not copy a possibly-stale old value).
  IF v_type = 'VOTING' THEN
    SELECT voting_token_ttl_hours INTO v_ttl_hours FROM election_settings WHERE id = 1;
    v_new_expires := NOW() + (COALESCE(v_ttl_hours, 168) * interval '1 hour');
  ELSE
    v_new_expires := NOW() + interval '24 hours';
  END IF;

  UPDATE tokens SET voided_at = NOW(), void_reason = p_reason WHERE id = p_old_token_id;

  -- New active token. The partial unique index rejects any racing second active
  -- token for the same (member_id, type) with a clean unique_violation.
  INSERT INTO tokens (member_id, token_hash, type, reissued_from_token_id, expires_at)
  VALUES (v_member_id, p_new_token_hash, v_type, p_old_token_id, v_new_expires);

  RETURN QUERY SELECT TRUE, 'Reissued';
END;
$$;

REVOKE EXECUTE ON FUNCTION private.reissue_token(UUID, UUID, TEXT, VARCHAR) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.reissue_token(UUID, UUID, TEXT, VARCHAR) TO service_role;

-- ============================================================================
-- Public PostgREST wrapper (private RPCs are not exposed via PostgREST).
-- Mirrors migration_nomination_public_wrappers.sql. Admin-only: service_role.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.reissue_token(
  p_old_token_id UUID, p_admin_id UUID, p_reason TEXT, p_new_token_hash VARCHAR
) RETURNS TABLE (success BOOLEAN, message TEXT)
LANGUAGE sql SECURITY DEFINER
SET search_path = public, private
AS $$
  SELECT * FROM private.reissue_token(p_old_token_id, p_admin_id, p_reason, p_new_token_hash);
$$;

REVOKE EXECUTE ON FUNCTION public.reissue_token(UUID, UUID, TEXT, VARCHAR) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.reissue_token(UUID, UUID, TEXT, VARCHAR) TO service_role;
