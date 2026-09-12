-- Migration: phase-gate + audit-attribution fix for pre-printed paper ballot assignment
-- v0.5.0
--
-- Two fixes (both found in the 0.5.0 mobile-assign security review):
--   1. BLOCKER: issue_preprinted_paper_ballot did NOT enforce election phase.
--      Unlike the digital vote RPC (requires current_phase='VOTING'), paper
--      assignment could happen in any phase. Add a VOTING-phase gate.
--   2. BLOCKER: the RPC wrote p_admin_id into paper_ballots.issued_by, but
--      issued_by is FK'd to members(id) (NOT admin_sessions). Passing an
--      admin_sessions.id there throws a FK violation and breaks assignment.
--      Admin attribution is preserved via vote_audit_log.admin_id (correctly
--      FK'd to admin_sessions). So: stop writing issued_by; keep audit-log.
--
-- Run AFTER migration_fix_preprinted_shortcode_cast.sql (the prior latest def).

CREATE OR REPLACE FUNCTION private.issue_preprinted_paper_ballot(
  p_ballot_id TEXT,
  p_member_id UUID,
  p_admin_id UUID DEFAULT NULL
)
RETURNS TABLE(success BOOLEAN, message TEXT, ballot_id TEXT, short_code TEXT, qr_svg TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'private', 'extensions'
AS $function$
DECLARE
  v_member RECORD;
  v_ballot RECORD;
  v_payload TEXT;
  v_phase election_phase;
  v_voting_end TIMESTAMPTZ;
BEGIN
  v_payload := private.hmac_verify(p_ballot_id);
  IF v_payload IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Invalid ballot ID (HMAC signature verification failed).'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Fix 1: enforce VOTING phase (mirrors the digital vote RPC).
  SELECT current_phase, voting_end INTO v_phase, v_voting_end FROM election_settings WHERE id = 1;
  IF v_phase IS DISTINCT FROM 'VOTING'::election_phase THEN
    RETURN QUERY SELECT FALSE, 'Paper ballots can only be assigned during the VOTING phase.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;
  IF v_voting_end IS NOT NULL AND NOW() > v_voting_end THEN
    RETURN QUERY SELECT FALSE, 'Voting has ended; paper ballots can no longer be assigned.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
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

  -- Fix 2: do NOT write p_admin_id into issued_by (members FK). Admin attribution
  -- lives in vote_audit_log.admin_id below (admin_sessions FK).
  UPDATE paper_ballots
  SET member_id = v_member.id,
      status = 'ISSUED_TO_VOTER',
      issued_to_voter_at = NOW()
  WHERE paper_ballots.ballot_id = p_ballot_id;

  UPDATE tokens
  SET is_used = TRUE, used_at = NOW(), channel_sent = 'PAPER'
  WHERE member_id = v_member.id AND type = 'VOTING' AND is_used = FALSE;

  INSERT INTO vote_audit_log (action, member_id, ballot_id, admin_id, details)
  VALUES ('PAPER_ISSUED_OPTION_E', v_member.id, p_ballot_id, p_admin_id, jsonb_build_object('short_code', v_ballot.short_code, 'batch_id', v_ballot.batch_id));

  RETURN QUERY SELECT TRUE, 'Paper ballot ' || v_ballot.short_code || ' assigned to ' || v_member.full_name || '.'::TEXT, p_ballot_id, v_ballot.short_code::TEXT, v_ballot.qr_svg;
END;
$function$;
