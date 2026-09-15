-- MIGRATION: Wave 3 paper-ballot token reservation integrity
-- Purpose: lock/reserve VOTING token in issue_paper_ballot and safely release only PAPER reservations in spoil_paper_ballot.

CREATE OR REPLACE FUNCTION private.issue_paper_ballot(
  p_member_id UUID
)
RETURNS TABLE (success BOOLEAN, message TEXT, ballot_id TEXT, short_code TEXT, qr_svg TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_member RECORD;
  v_payload TEXT;
  v_ballot_id TEXT;
  v_short_code TEXT;
  v_qr_svg TEXT;
  v_attempts INT := 0;
  v_insert_ok BOOLEAN := FALSE;
  v_token RECORD;
  v_token_count INT := 0;
BEGIN
  -- Verify member exists and is active
  SELECT id, full_name INTO v_member FROM members WHERE id = p_member_id AND is_active = TRUE;
  IF v_member.id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Member not found or inactive.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Lock non-voided VOTING token rows for this member and enforce 0/1 cardinality
  FOR v_token IN
    SELECT id, is_used, channel_sent
    FROM tokens
    WHERE member_id = v_member.id
      AND type = 'VOTING'
      AND voided_at IS NULL
    ORDER BY created_at DESC, id
    FOR UPDATE
  LOOP
    v_token_count := v_token_count + 1;
    IF v_token_count > 1 THEN
      RETURN QUERY SELECT FALSE, 'Integrity error: multiple active voting tokens found for member.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
      RETURN;
    END IF;
  END LOOP;

  -- Token-state guard
  IF v_token_count = 1 THEN
    IF v_token.is_used = TRUE AND v_token.channel_sent = 'PAPER' THEN
      RETURN QUERY SELECT FALSE, 'Member already has a paper ballot or token reservation.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
      RETURN;
    END IF;

    IF v_token.is_used = TRUE AND v_token.channel_sent <> 'PAPER' THEN
      RETURN QUERY SELECT FALSE, 'Member has already voted digitally.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
      RETURN;
    END IF;
  END IF;

  -- Check if member already has an active or voted paper ballot
  IF EXISTS (
    SELECT 1 FROM paper_ballots
    WHERE member_id = v_member.id AND status IN ('ISSUED', 'ISSUED_TO_VOTER', 'VOTED')
  ) THEN
    RETURN QUERY SELECT FALSE, 'Member already has an active or used paper ballot.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Opaque payload: pure random, no member/batch identifiers, no timestamp.
  v_payload := 'PAPER:' || encode(gen_random_bytes(32), 'hex');
  v_ballot_id := private.hmac_sign(v_payload);

  WHILE v_attempts < 5 AND NOT v_insert_ok LOOP
    v_short_code := private.generate_short_code();
    v_qr_svg := private.generate_qr_svg(v_ballot_id);
    BEGIN
      INSERT INTO paper_ballots (ballot_id, member_id, status, short_code, qr_svg)
      VALUES (v_ballot_id, v_member.id, 'ISSUED', v_short_code, v_qr_svg);
      v_insert_ok := TRUE;
    EXCEPTION WHEN unique_violation THEN
      v_attempts := v_attempts + 1;
    END;
  END LOOP;

  IF NOT v_insert_ok THEN
    RETURN QUERY SELECT FALSE, 'Could not generate unique short code after 5 attempts.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Reserve token at handout (no-op when member has no active VOTING token row)
  IF v_token_count = 1 THEN
    UPDATE tokens
    SET is_used = TRUE,
        used_at = NOW(),
        channel_sent = 'PAPER'
    WHERE id = v_token.id
      AND is_used = FALSE;
  END IF;

  -- Audit log
  INSERT INTO vote_audit_log (action, member_id, ballot_id, details)
  VALUES ('PAPER_ISSUED', v_member.id, v_ballot_id, jsonb_build_object('short_code', v_short_code));

  RETURN QUERY SELECT TRUE, 'Paper ballot issued for ' || v_member.full_name || '.'::TEXT, v_ballot_id, v_short_code, v_qr_svg;
END;
$$;

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

  -- Release reservation only for PAPER-reserved VOTING tokens tied to this ballot holder.
  -- Critical guard: never touch digital/email token usage state.
  IF v_paper.status IN ('ISSUED', 'ISSUED_TO_VOTER') AND v_paper.member_id IS NOT NULL THEN
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

  -- Audit log
  INSERT INTO vote_audit_log (action, member_id, ballot_id, admin_id, details)
  VALUES ('PAPER_SPOILED', v_paper.member_id, p_ballot_id, p_admin_id, jsonb_build_object('reason', p_reason));

  RETURN QUERY SELECT TRUE, 'Ballot marked as spoiled: ' || p_reason || '.'::TEXT;
END;
$$;

-- Preserve grants (CREATE OR REPLACE keeps existing ACL; re-assert to be safe)
REVOKE EXECUTE ON FUNCTION private.issue_paper_ballot(UUID)            FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.issue_paper_ballot(UUID)            TO service_role;
REVOKE EXECUTE ON FUNCTION private.spoil_paper_ballot(TEXT, TEXT, UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.spoil_paper_ballot(TEXT, TEXT, UUID) TO service_role;
