-- Enforce voting-token expiry at the DB layer (correctness review #5, DB parity)
--
-- Context: tokens.expires_at (added by migration_token_expiry.sql; voting = 7
-- days, nomination = 24h) was stored but never enforced. The route layer now
-- rejects expired tokens in app/api/auth/verify-token/route.ts and
-- app/api/vote/route.ts, but private.submit_anonymous_vote (the SECURITY
-- DEFINER RPC that records the ballot and marks the token used) did NOT check
-- expires_at. This migration adds that check inside the transactional token
-- lock so expiry is enforced regardless of caller.
--
-- IMPORTANT: this is a faithful CREATE OR REPLACE of the *Option E* version of
-- the function (migration_option_e_paper_ballots_part2.sql lines 364-439), NOT
-- the original schema.sql version. Only the expiry-related lines are added
-- (marked -- CHANGED); the Option E paper-ballot status list
-- ('ISSUED','ISSUED_TO_VOTER','VOTED') and used-token message are preserved.
--
-- Run order: run AFTER migration_token_expiry.sql (adds expires_at) AND AFTER
-- migration_option_e_paper_ballots_part2.sql (defines the Option E function);
-- run after any later migration that redefines private.submit_anonymous_vote.
-- Idempotent.
--
-- NOTE: existing VOTING tokens with expires_at IS NULL become invalid under
-- this policy. If pre-expiry tokens exist in production, backfill expires_at
-- before running this migration.

CREATE OR REPLACE FUNCTION private.submit_anonymous_vote(
  p_token_hash VARCHAR(64),
  p_candidate_id UUID
)
RETURNS TABLE (success BOOLEAN, message TEXT, receipt_code TEXT, ballot_id TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_token_id UUID;
  v_member_id UUID;
  v_is_used BOOLEAN;
  v_expires_at TIMESTAMPTZ;               -- CHANGED: capture token expiry
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

  SELECT id, member_id, is_used, expires_at                       -- CHANGED: select expires_at
    INTO v_token_id, v_member_id, v_is_used, v_expires_at FROM tokens
  WHERE token_hash = p_token_hash AND type = 'VOTING' FOR UPDATE;

  IF v_token_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Invalid or non-existent voting token.'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  IF v_expires_at IS NULL OR v_expires_at <= NOW() THEN           -- CHANGED: enforce expiry
    RETURN QUERY SELECT FALSE, 'This voting token has expired.'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  IF v_is_used THEN
    RETURN QUERY SELECT FALSE, 'This token has already been used or reserved for paper voting.'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Check if member already has an active or voted paper ballot.
  SELECT * INTO v_paper_ballot FROM paper_ballots
  WHERE member_id = v_member_id AND status IN ('ISSUED', 'ISSUED_TO_VOTER', 'VOTED')
  FOR SHARE;

  IF FOUND THEN
    RETURN QUERY SELECT FALSE, 'A paper ballot has already been issued for this member.'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  v_payload := v_member_id || ':' || p_candidate_id || ':' || extract(epoch FROM NOW())::bigint || ':' || encode(gen_random_bytes(8), 'hex');
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
$$;

-- Preserve grants (CREATE OR REPLACE keeps existing ACL, but re-assert to be safe)
REVOKE EXECUTE ON FUNCTION private.submit_anonymous_vote(VARCHAR, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.submit_anonymous_vote(VARCHAR, UUID) TO service_role;
