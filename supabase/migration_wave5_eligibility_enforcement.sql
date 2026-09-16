-- Wave 5 migration 32: voter-eligibility ENFORCEMENT (both channels) + token trigger + roster PII purge.
-- CRITICAL: this migration is the FINAL WRITER for private.submit_anonymous_vote,
-- private.issue_paper_ballot, and private.issue_preprinted_paper_ballot. Re-running any earlier
-- writer for these RPCs after this file re-opens the eligibility gap. (See TECHNICAL_GUIDE canonical run order.)
-- Bodies below are the current deployed definitions with a single Wave 5 eligibility block spliced in;
-- all existing phase/expiry/token/paper guards, locks, signatures, and grants are preserved verbatim.

-- =========================================================================
-- 1. submit_anonymous_vote — defense-in-depth eligibility gate at vote cast.
-- =========================================================================
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
  v_voting_eligible BOOLEAN;  -- Wave 5
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

  -- Wave 5: voter eligibility gate (defense-in-depth at vote cast). v_member_id is set.
  SELECT voting_eligible INTO v_voting_eligible FROM members WHERE id = v_member_id AND is_active = TRUE FOR SHARE;
  IF NOT FOUND OR v_voting_eligible IS NOT TRUE THEN
    RETURN QUERY SELECT FALSE, 'Member is not eligible to vote.'::TEXT, NULL::TEXT, NULL::TEXT;
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

-- =========================================================================
-- 2. issue_paper_ballot — eligibility gate at paper issuance.
-- =========================================================================
CREATE OR REPLACE FUNCTION private.issue_paper_ballot(p_member_id uuid)
 RETURNS TABLE(success boolean, message text, ballot_id text, short_code text, qr_svg text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'extensions'
AS $function$
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
  -- Verify member exists and is active (Wave 5: also fetch voting_eligible)
  SELECT id, full_name, voting_eligible INTO v_member FROM members WHERE id = p_member_id AND is_active = TRUE;
  IF v_member.id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Member not found or inactive.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Wave 5: voter eligibility gate (paper issuance channel).
  IF v_member.voting_eligible IS NOT TRUE THEN
    RETURN QUERY SELECT FALSE, 'Member is not eligible to vote.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
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
$function$;

-- =========================================================================
-- 3. issue_preprinted_paper_ballot — eligibility gate at pre-printed assignment.
-- =========================================================================
CREATE OR REPLACE FUNCTION private.issue_preprinted_paper_ballot(p_ballot_id text, p_member_id uuid, p_admin_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(success boolean, message text, ballot_id text, short_code text, qr_svg text)
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

  SELECT current_phase, voting_end INTO v_phase, v_voting_end FROM election_settings WHERE id = 1;
  IF v_phase IS DISTINCT FROM 'VOTING'::election_phase THEN
    RETURN QUERY SELECT FALSE, 'Paper ballots can only be assigned during the VOTING phase.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;
  IF v_voting_end IS NOT NULL AND NOW() > v_voting_end THEN
    RETURN QUERY SELECT FALSE, 'Voting has ended; paper ballots can no longer be assigned.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Verify member exists and is active (Wave 5: also fetch voting_eligible)
  SELECT id, full_name, voting_eligible INTO v_member FROM members WHERE id = p_member_id AND is_active = TRUE;
  IF v_member.id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Member not found or inactive.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Wave 5: voter eligibility gate (pre-printed paper assignment channel).
  IF v_member.voting_eligible IS NOT TRUE THEN
    RETURN QUERY SELECT FALSE, 'Member is not eligible to vote.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
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

-- =========================================================================
-- 4. VOTING-token insert backstop trigger (protects direct service-role inserts;
--    lets us retire the standalone dispatch script).
-- =========================================================================
CREATE OR REPLACE FUNCTION private.enforce_token_eligibility() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, private AS $$
DECLARE v_ok BOOLEAN;
BEGIN
  IF NEW.type = 'VOTING' THEN
    SELECT (is_active AND voting_eligible) INTO v_ok FROM members WHERE id = NEW.member_id;
    IF v_ok IS NOT TRUE THEN
      RAISE EXCEPTION 'Cannot issue VOTING token: member % is not eligible', NEW.member_id
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_token_eligibility ON tokens;
CREATE TRIGGER trg_token_eligibility BEFORE INSERT ON tokens
  FOR EACH ROW EXECUTE FUNCTION private.enforce_token_eligibility();

-- =========================================================================
-- 5. purge_roster_pii — two-stage, phase-gated, idempotent, audited roster PII minimization.
-- =========================================================================
CREATE OR REPLACE FUNCTION private.purge_roster_pii(
  p_admin_id UUID, p_stage TEXT, p_confirm TEXT
) RETURNS TABLE(success BOOLEAN, stage TEXT, members_touched INT, message TEXT)
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, private, governance, extensions AS $$
DECLARE
  v_phase TEXT;
  v_voting_end TIMESTAMPTZ;
  v_count INT := 0;
BEGIN
  IF p_confirm <> 'PURGE' THEN
    RETURN QUERY SELECT FALSE, p_stage, 0, 'Confirmation token mismatch'; RETURN;
  END IF;
  SELECT current_phase, voting_end INTO v_phase, v_voting_end FROM election_settings WHERE id = 1;

  IF p_stage = 'CONTACT' THEN
    IF v_phase NOT IN ('VOTING_CLOSED','COMPLETED') THEN
      RETURN QUERY SELECT FALSE, p_stage, 0, 'Stage CONTACT requires VOTING_CLOSED/COMPLETED'; RETURN;
    END IF;
    UPDATE members m SET
      email = NULL, phone = NULL,
      has_voted = (EXISTS (SELECT 1 FROM tokens t WHERE t.member_id = m.id AND t.type='VOTING' AND t.is_used = TRUE)
                OR EXISTS (SELECT 1 FROM paper_ballots p WHERE p.member_id = m.id AND p.status = 'VOTED'))
    WHERE email IS NOT NULL OR phone IS NOT NULL;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    PERFORM private.append_governance_event('CONTACT_PII_PURGED', p_admin_id, NULL, NULL, NULL,
      'roster PII minimization', 'storage limitation', ARRAY['contact'], ARRAY['members'], 'purged at voting close',
      jsonb_build_object('members_touched', v_count, 'phase', v_phase));
    RETURN QUERY SELECT TRUE, p_stage, v_count, 'Contact PII purged'; RETURN;

  ELSIF p_stage = 'IDENTITY' THEN
    IF v_voting_end IS NULL OR now() < v_voting_end + INTERVAL '30 days' THEN
      RETURN QUERY SELECT FALSE, p_stage, 0, 'Stage IDENTITY requires 30-day dispute window elapsed'; RETURN;
    END IF;
    UPDATE members SET
      full_name = 'Redacted member ' || substring(id::text from 1 for 8),
      member_code = 'PURGED-' || substring(id::text from 1 for 12),
      email = NULL, phone = NULL, is_age_eligible = NULL,
      voting_eligible = FALSE, eligibility_reason = 'PURGED', eligibility_source = 'PURGE'
    WHERE full_name NOT LIKE 'Redacted member %';
    GET DIAGNOSTICS v_count = ROW_COUNT;
    PERFORM private.append_governance_event('IDENTITY_PII_ANONYMIZED', p_admin_id, NULL, NULL, NULL,
      'roster identity anonymization', 'storage limitation', ARRAY['identity'], ARRAY['members'], 'anonymized after dispute window',
      jsonb_build_object('members_touched', v_count));
    RETURN QUERY SELECT TRUE, p_stage, v_count, 'Identity anonymized'; RETURN;
  END IF;
  RETURN QUERY SELECT FALSE, p_stage, 0, 'Unknown stage (use CONTACT or IDENTITY)';
END;
$$;

CREATE OR REPLACE FUNCTION public.purge_roster_pii(p_admin_id UUID, p_stage TEXT, p_confirm TEXT)
  RETURNS TABLE(success BOOLEAN, stage TEXT, members_touched INT, message TEXT)
  LANGUAGE sql SECURITY DEFINER SET search_path = public, private AS $$
  SELECT * FROM private.purge_roster_pii($1,$2,$3);
$$;
REVOKE ALL ON FUNCTION public.purge_roster_pii(UUID,TEXT,TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.purge_roster_pii(UUID,TEXT,TEXT) TO service_role;
