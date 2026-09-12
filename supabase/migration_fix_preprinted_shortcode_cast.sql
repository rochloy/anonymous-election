--------------------------------------------------------------------------------
-- FIX: issue_preprinted_paper_ballot — short_code varchar/text return mismatch
--
-- RETURNS TABLE (... short_code TEXT ...) declares the OUT column as TEXT, but
-- paper_ballots.short_code is character varying(14). The success-path
-- RETURN QUERY selected v_ballot.short_code uncast, so plpgsql's strict
-- RETURN QUERY type check raised: "structure of query does not match function
-- result type" (varchar != text in the short_code column), aborting every
-- successful Model B (pre-printed) ballot assignment. Error branches were
-- unaffected because they return NULL::TEXT.
--
-- This latent bug was masked until migration_fix_preprinted_ambiguous_ballot_id
-- removed the ambiguous "ballot_id" error that previously aborted the function
-- before it ever reached the success RETURN QUERY.
--
-- Fix: cast v_ballot.short_code::TEXT in the success RETURN QUERY. Signature is
-- unchanged, so the public wrapper and existing GRANT/REVOKE remain valid
-- (CREATE OR REPLACE preserves privileges). Body is otherwise byte-for-byte
-- identical to migration_fix_preprinted_ambiguous_ballot_id.sql.
--
-- Run AFTER migration_fix_preprinted_ambiguous_ballot_id.sql.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.issue_preprinted_paper_ballot(
  p_ballot_id TEXT,
  p_member_id UUID,
  p_admin_id UUID DEFAULT NULL
)
RETURNS TABLE (success BOOLEAN, message TEXT, ballot_id TEXT, short_code TEXT, qr_svg TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_member RECORD;
  v_ballot RECORD;
  v_payload TEXT;
BEGIN
  v_payload := private.hmac_verify(p_ballot_id);
  IF v_payload IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Invalid ballot ID (HMAC signature verification failed).'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  SELECT id, full_name INTO v_member FROM members WHERE id = p_member_id AND is_active = TRUE;
  IF v_member.id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Member not found or inactive.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM tokens t
    WHERE t.member_id = v_member.id AND t.type = 'VOTING' AND t.is_used = TRUE
  ) THEN
    RETURN QUERY SELECT FALSE, 'Member has already voted digitally.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM paper_ballots
    WHERE member_id = v_member.id AND status IN ('ISSUED', 'ISSUED_TO_VOTER', 'VOTED')
  ) THEN
    RETURN QUERY SELECT FALSE, 'Member already has an active or used paper ballot.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  SELECT * INTO v_ballot FROM paper_ballots WHERE paper_ballots.ballot_id = p_ballot_id FOR UPDATE;
  IF v_ballot.ballot_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Ballot not found in system.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  IF v_ballot.status != 'AVAILABLE' THEN
    RETURN QUERY SELECT FALSE, 'Ballot is not available for assignment (status: ' || v_ballot.status || ').'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  UPDATE paper_ballots
  SET member_id = v_member.id,
      status = 'ISSUED_TO_VOTER',
      issued_to_voter_at = NOW(),
      issued_by = p_admin_id
  WHERE paper_ballots.ballot_id = p_ballot_id;

  UPDATE tokens
  SET is_used = TRUE, used_at = NOW(), channel_sent = 'PAPER'
  WHERE member_id = v_member.id AND type = 'VOTING' AND is_used = FALSE;

  INSERT INTO vote_audit_log (action, member_id, ballot_id, admin_id, details)
  VALUES ('PAPER_ISSUED_OPTION_E', v_member.id, p_ballot_id, p_admin_id, jsonb_build_object('short_code', v_ballot.short_code, 'batch_id', v_ballot.batch_id));

  RETURN QUERY SELECT TRUE, 'Paper ballot ' || v_ballot.short_code || ' assigned to ' || v_member.full_name || '.'::TEXT, p_ballot_id, v_ballot.short_code::TEXT, v_ballot.qr_svg;
END;
$$;
