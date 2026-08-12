-- MIGRATION: Fix paper ballot RPCs - add token update + audit logging
-- Run this in Supabase SQL Editor after migration_paper_ballots.sql
--
-- Issues fixed:
-- 1. submit_paper_vote: now marks member's token as used (prevents double-voting)
-- 2. All three RPCs: now insert into vote_audit_log for audit trail

-- 1. Fix issue_paper_ballot: add audit log insert
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
BEGIN
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
    WHERE member_id = v_member.id AND status IN ('ISSUED', 'VOTED')
  ) THEN
    RETURN QUERY SELECT FALSE, 'Member already has an active paper ballot.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  v_payload := 'PAPER:' || v_member.id || ':' || extract(epoch FROM NOW())::bigint || ':' || encode(gen_random_bytes(8), 'hex');
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

  -- Audit log: PAPER_ISSUED
  INSERT INTO vote_audit_log (action, member_id, ballot_id, details)
  VALUES ('PAPER_ISSUED', v_member.id, v_ballot_id, jsonb_build_object('short_code', v_short_code));

  RETURN QUERY SELECT TRUE, 'Paper ballot issued for ' || v_member.full_name || '.'::TEXT, v_ballot_id, v_short_code, v_qr_svg;
END;
$$;

-- 2. Fix submit_paper_vote: add token update + audit log insert
CREATE OR REPLACE FUNCTION private.submit_paper_vote(
  p_ballot_id TEXT,
  p_candidate_id UUID
)
RETURNS TABLE (success BOOLEAN, message TEXT, receipt_code TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_paper RECORD;
  v_payload TEXT;
  v_receipt TEXT;
  v_attempts INT := 0;
  v_insert_ok BOOLEAN := FALSE;
  v_digital_token RECORD;
BEGIN
  v_payload := private.hmac_verify(p_ballot_id);
  IF v_payload IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Invalid ballot ID (HMAC verification failed).'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  IF NOT v_payload LIKE 'PAPER:%' THEN
    RETURN QUERY SELECT FALSE, 'Invalid ballot ID format.'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  SELECT * INTO v_paper FROM paper_ballots WHERE ballot_id = p_ballot_id FOR UPDATE;
  IF v_paper.ballot_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Ballot not found.'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  IF v_paper.status != 'ISSUED' THEN
    RETURN QUERY SELECT FALSE, 'Ballot already used or invalid (status: ' || v_paper.status || ').'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Check if member already voted digitally (token already used)
  SELECT t.id INTO v_digital_token FROM tokens t
  WHERE t.member_id = v_paper.member_id AND t.type = 'VOTING' AND t.is_used = TRUE
  FOR UPDATE;

  IF FOUND THEN
    -- Paper wins; tally deduplicates (but we still record the paper vote)
    NULL;
  END IF;

  WHILE v_attempts < 5 AND NOT v_insert_ok LOOP
    v_receipt := 'PB-' || encode(gen_random_bytes(5), 'hex');
    BEGIN
      INSERT INTO ballots (ballot_id, candidate_id, receipt_code, channel, cast_date)
      VALUES (p_ballot_id, p_candidate_id, v_receipt, 'PAPER', CURRENT_DATE);
      v_insert_ok := TRUE;
    EXCEPTION WHEN unique_violation THEN
      v_attempts := v_attempts + 1;
    END;
  END LOOP;

  IF NOT v_insert_ok THEN
    RETURN QUERY SELECT FALSE, 'Could not generate unique receipt code.'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  UPDATE paper_ballots
  SET status = 'VOTED', voted_at = NOW(), candidate_id = p_candidate_id
  WHERE ballot_id = p_ballot_id;

  -- Mark member's digital token as used (prevents double-voting)
  UPDATE tokens
  SET is_used = TRUE, used_at = NOW(), channel_sent = 'PAPER'
  WHERE member_id = v_paper.member_id AND type = 'VOTING' AND is_used = FALSE;

  -- Audit log: PAPER_VOTED
  INSERT INTO vote_audit_log (action, member_id, ballot_id, candidate_id, details)
  VALUES ('PAPER_VOTED', v_paper.member_id, p_ballot_id, p_candidate_id, jsonb_build_object('receipt_code', v_receipt));

  RETURN QUERY SELECT TRUE, 'Paper vote recorded.'::TEXT, v_receipt;
END;
$$;

-- 3. Fix submit_paper_invalid: add audit log insert
CREATE OR REPLACE FUNCTION private.submit_paper_invalid(
  p_ballot_id TEXT,
  p_reason TEXT
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

  IF v_paper.status != 'ISSUED' THEN
    RETURN QUERY SELECT FALSE, 'Ballot already processed (status: ' || v_paper.status || ').'::TEXT;
    RETURN;
  END IF;

  UPDATE paper_ballots
  SET status = 'SPOILED', invalid_reason = p_reason
  WHERE ballot_id = p_ballot_id;

  -- Audit log: PAPER_SPOILED
  INSERT INTO vote_audit_log (action, member_id, ballot_id, details)
  VALUES ('PAPER_SPOILED', v_paper.member_id, p_ballot_id, jsonb_build_object('reason', p_reason));

  RETURN QUERY SELECT TRUE, 'Ballot marked as invalid: ' || p_reason || '.'::TEXT;
END;
$$;