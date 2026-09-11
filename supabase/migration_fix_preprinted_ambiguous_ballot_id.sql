--------------------------------------------------------------------------------
-- FIX: issue_preprinted_paper_ballot — ambiguous "ballot_id" column reference
--
-- RETURNS TABLE (... ballot_id TEXT ...) declares an OUT column named ballot_id.
-- Two statements referenced `ballot_id` unqualified in a WHERE clause, colliding
-- with that OUT name. Under the default plpgsql.variable_conflict = error this
-- raises: column reference "ballot_id" is ambiguous, aborting every Model B
-- (pre-printed) ballot assignment.
--
-- Fix: qualify both references as paper_ballots.ballot_id. Signature is unchanged,
-- so the public wrapper and existing GRANT/REVOKE remain valid (CREATE OR REPLACE
-- preserves privileges). Body is otherwise byte-for-byte identical to
-- migration_option_e_paper_ballots_part2.sql.
--
-- Run AFTER migration_option_e_paper_ballots_part2.sql.
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
  -- Verify HMAC signature
  v_payload := private.hmac_verify(p_ballot_id);
  IF v_payload IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Invalid ballot ID (HMAC signature verification failed).'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Verify member exists and is active
  SELECT id, full_name INTO v_member FROM members WHERE id = p_member_id AND is_active = TRUE;
  IF v_member.id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Member not found or inactive.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Check if member has already voted digitally
  IF EXISTS (
    SELECT 1 FROM tokens t
    WHERE t.member_id = v_member.id AND t.type = 'VOTING' AND t.is_used = TRUE
  ) THEN
    RETURN QUERY SELECT FALSE, 'Member has already voted digitally.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Check if member already has an active or voted paper ballot
  IF EXISTS (
    SELECT 1 FROM paper_ballots
    WHERE member_id = v_member.id AND status IN ('ISSUED', 'ISSUED_TO_VOTER', 'VOTED')
  ) THEN
    RETURN QUERY SELECT FALSE, 'Member already has an active or used paper ballot.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Lock and verify ballot is AVAILABLE
  SELECT * INTO v_ballot FROM paper_ballots WHERE paper_ballots.ballot_id = p_ballot_id FOR UPDATE;
  IF v_ballot.ballot_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Ballot not found in system.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  IF v_ballot.status != 'AVAILABLE' THEN
    RETURN QUERY SELECT FALSE, 'Ballot is not available for assignment (status: ' || v_ballot.status || ').'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Assign ballot to member and update status
  UPDATE paper_ballots
  SET member_id = v_member.id,
      status = 'ISSUED_TO_VOTER',
      issued_to_voter_at = NOW(),
      issued_by = p_admin_id
  WHERE paper_ballots.ballot_id = p_ballot_id;

  -- Reserve the member's voting entitlement at handout to prevent a later digital vote.
  UPDATE tokens
  SET is_used = TRUE, used_at = NOW(), channel_sent = 'PAPER'
  WHERE member_id = v_member.id AND type = 'VOTING' AND is_used = FALSE;

  -- Audit log
  INSERT INTO vote_audit_log (action, member_id, ballot_id, admin_id, details)
  VALUES ('PAPER_ISSUED_OPTION_E', v_member.id, p_ballot_id, p_admin_id, jsonb_build_object('short_code', v_ballot.short_code, 'batch_id', v_ballot.batch_id));

  RETURN QUERY SELECT TRUE, 'Paper ballot ' || v_ballot.short_code || ' assigned to ' || v_member.full_name || '.'::TEXT, p_ballot_id, v_ballot.short_code, v_ballot.qr_svg;
END;
$$;
