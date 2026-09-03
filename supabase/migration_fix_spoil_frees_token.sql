-- MIGRATION: Spoiling a handout-reserved paper ballot frees the voting token
--
-- Problem:
-- Option E reserves a member's digital token during handout
--   (tokens.is_used = TRUE, channel_sent = 'PAPER').
-- If that ballot is spoiled before vote recording, member should be able to receive
-- another paper ballot. The reservation must be released.
--
-- Fix:
-- In private.spoil_paper_ballot(), when status = 'ISSUED_TO_VOTER' and member_id is present,
-- set tokens.is_used back to FALSE (and used_at to NULL) for the member's VOTING token that
-- was marked via PAPER reservation.

CREATE OR REPLACE FUNCTION private.spoil_paper_ballot(
  p_ballot_id TEXT,
  p_reason TEXT,
  p_admin_id UUID DEFAULT NULL
)
RETURNS TABLE (success BOOLEAN, message TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_paper RECORD;
  v_payload TEXT;
BEGIN
  v_payload := private.hmac_verify(p_ballot_id);
  IF v_payload IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Invalid ballot ID (HMAC verification failed).'::TEXT;
    RETURN;
  END IF;

  SELECT * INTO v_paper FROM paper_ballots WHERE ballot_id = p_ballot_id FOR UPDATE;
  IF v_paper.ballot_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Ballot not found.'::TEXT;
    RETURN;
  END IF;

  IF v_paper.status NOT IN ('ISSUED', 'ISSUED_TO_VOTER', 'AVAILABLE') THEN
    RETURN QUERY SELECT FALSE, 'Ballot cannot be spoiled from status: ' || v_paper.status || '.'::TEXT;
    RETURN;
  END IF;

  -- If this ballot had reserved the member token at handout, release that reservation.
  IF v_paper.status = 'ISSUED_TO_VOTER' AND v_paper.member_id IS NOT NULL THEN
    UPDATE tokens
    SET is_used = FALSE,
        used_at = NULL,
        channel_sent = 'PAPER'
    WHERE member_id = v_paper.member_id
      AND type = 'VOTING'
      AND is_used = TRUE
      AND channel_sent = 'PAPER';
  END IF;

  UPDATE paper_ballots
  SET status = 'SPOILED', invalid_reason = p_reason, spoiled_at = NOW(), spoiled_by = p_admin_id
  WHERE ballot_id = p_ballot_id;

  INSERT INTO vote_audit_log (action, member_id, ballot_id, admin_id, details)
  VALUES ('PAPER_SPOILED', v_paper.member_id, p_ballot_id, p_admin_id, jsonb_build_object('reason', p_reason));

  RETURN QUERY SELECT TRUE, 'Ballot marked as spoiled: ' || p_reason || '.'::TEXT;
END;
$$;

-- Preserve grants (CREATE OR REPLACE keeps existing ACL; re-assert to be safe)
REVOKE EXECUTE ON FUNCTION private.spoil_paper_ballot(TEXT, TEXT, UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.spoil_paper_ballot(TEXT, TEXT, UUID) TO service_role;
