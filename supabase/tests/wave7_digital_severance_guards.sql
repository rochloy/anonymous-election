-- ============================================================================
-- wave7_digital_severance_guards.sql
-- v0.13.0 Wave 7 (P3) — digital severance guard harness (self-rolling-back)
-- ============================================================================

DO $harness$
DECLARE
  -- shared fixtures
  v_cand1 UUID;
  v_cand2 UUID;
  v_base_member UUID;
  v_base_token UUID;

  -- scratch
  v_ok BOOLEAN;
  v_msg TEXT;
  v_cred TEXT;
  v_ttl INT;
  v_receipt TEXT;
  v_ballot TEXT;
  v_cnt INT;
  v_exists BOOLEAN;
  v_txt TEXT;
  v_bool BOOLEAN;
  v_err BOOLEAN;
  v_col_count INT;
  v_redeem_sig TEXT;
  v_cast_sig TEXT;
  v_release_sig TEXT;

  -- per-guard fixture scratch
  v_mid UUID;
  v_tid UUID;
  v_tid2 UUID;
  v_tok TEXT;
  v_sc TEXT;

  -- counters
  v_pass INT := 0;
  v_fail INT := 0;
BEGIN
  ------------------------------------------------------------------------------
  -- FIXTURES / BASELINE
  ------------------------------------------------------------------------------
  -- The whole harness runs in one transaction that ALWAYS aborts (ROLLBACK_OK /
  -- W7_GUARD_FAIL), so disabling the phase-transition guard here is safe: it is
  -- reverted on rollback and never touches committed production state. Needed
  -- because fixtures force current_phase='VOTING' and the live DB may currently
  -- be in COMPLETED (from which a direct ->VOTING jump is rejected).
  ALTER TABLE election_settings DISABLE TRIGGER trigger_validate_phase_transition;

  SELECT id INTO v_cand1 FROM candidates WHERE is_active = TRUE ORDER BY id LIMIT 1;
  SELECT id INTO v_cand2 FROM candidates WHERE is_active = TRUE AND id <> v_cand1 ORDER BY id LIMIT 1;
  IF v_cand1 IS NULL OR v_cand2 IS NULL THEN
    RAISE EXCEPTION 'W7_GUARD_FAIL: fixtures — need >=2 active candidates';
  END IF;

  -- Ensure election gate is open by default for most probes.
  UPDATE election_settings
     SET current_phase = 'VOTING',
         voting_end = now() + interval '1 day',
         digital_write_mode = 'LEGACY',
         digital_credential_ttl_minutes = 15
   WHERE id = 1;

  INSERT INTO members(member_code, full_name, voting_eligible, is_active)
  VALUES ('W7T-BASE', 'W7 Base Member', TRUE, TRUE)
  RETURNING id INTO v_base_member;
  INSERT INTO tokens(member_id, token_hash, type, expires_at)
  VALUES (v_base_member, 'w7t-base-hash', 'VOTING', now() + interval '2 day')
  RETURNING id INTO v_base_token;

  ------------------------------------------------------------------------------
  -- A. Double-vote / entitlement integrity (digital)
  ------------------------------------------------------------------------------

  -- 1
  INSERT INTO members(member_code, full_name, voting_eligible, is_active)
  VALUES ('W7T-A1-M', 'W7 A1', TRUE, TRUE) RETURNING id INTO v_mid;
  v_tok := 'w7t-a1-hash';
  INSERT INTO tokens(member_id, token_hash, type, expires_at)
  VALUES (v_mid, v_tok, 'VOTING', now() + interval '1 day') RETURNING id INTO v_tid;

  SELECT o_success, o_message, o_credential, o_ttl_seconds
    INTO v_ok, v_msg, v_cred, v_ttl
    FROM private.redeem_voting_token(v_tok);
  SELECT o_success, o_message, o_receipt_code, o_ballot_id
    INTO v_ok, v_msg, v_receipt, v_ballot
    FROM private.cast_anonymous_digital_vote(v_cred, v_cand1);

  SELECT is_used INTO v_bool FROM tokens WHERE id = v_tid;
  SELECT EXISTS(SELECT 1 FROM anonymous_digital_credentials WHERE credential_hash = encode(digest(v_cred, 'sha256'),'hex') AND status = 'CAST') INTO v_exists;
  SELECT EXISTS(SELECT 1 FROM digital_credential_reservations WHERE token_id = v_tid) INTO v_err;
  IF v_ok IS TRUE AND v_bool IS TRUE AND v_exists IS TRUE AND v_err IS FALSE THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 1 A1 redeem+cast consumes token, CAST credential, deletes reservation';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 1 A1';
  END IF;

  -- 2
  SELECT o_success, o_message, o_receipt_code, o_ballot_id
    INTO v_ok, v_msg, v_receipt, v_ballot
    FROM private.cast_anonymous_digital_vote(v_cred, v_cand2);
  IF v_ok IS FALSE THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 2 A2 second cast with same credential refused';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 2 A2';
  END IF;

  -- 3
  INSERT INTO members(member_code, full_name, voting_eligible, is_active)
  VALUES ('W7T-A3-M', 'W7 A3', TRUE, TRUE) RETURNING id INTO v_mid;
  v_tok := 'w7t-a3-hash';
  INSERT INTO tokens(member_id, token_hash, type, expires_at)
  VALUES (v_mid, v_tok, 'VOTING', now() + interval '1 day');
  SELECT o_success, o_message, o_credential, o_ttl_seconds INTO v_ok, v_msg, v_cred, v_ttl FROM private.redeem_voting_token(v_tok);
  SELECT o_success, o_message, o_credential, o_ttl_seconds INTO v_ok, v_msg, v_cred, v_ttl FROM private.redeem_voting_token(v_tok);
  IF v_ok IS FALSE THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 3 A3 second redeem refused while active reservation';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 3 A3';
  END IF;

  -- 4
  INSERT INTO members(member_code, full_name, voting_eligible, is_active)
  VALUES ('W7T-A4-M', 'W7 A4', TRUE, TRUE) RETURNING id INTO v_mid;
  v_tok := 'w7t-a4-hash';
  INSERT INTO tokens(member_id, token_hash, type, expires_at)
  VALUES (v_mid, v_tok, 'VOTING', now() + interval '1 day');
  SELECT o_success, o_message, o_credential, o_ttl_seconds INTO v_ok, v_msg, v_cred, v_ttl FROM private.redeem_voting_token(v_tok);
  SELECT o_success, o_message INTO v_ok, v_msg FROM private.release_digital_voting_reservation(v_tok);
  SELECT o_success, o_message, o_credential, o_ttl_seconds INTO v_ok, v_msg, v_cred, v_ttl FROM private.redeem_voting_token(v_tok);
  IF v_ok IS TRUE THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 4 A4 redeem->release->redeem recoverability works';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 4 A4';
  END IF;

  -- 5
  INSERT INTO members(member_code, full_name, voting_eligible, is_active)
  VALUES ('W7T-A5-M', 'W7 A5', TRUE, TRUE) RETURNING id INTO v_mid;
  v_tok := 'w7t-a5-hash';
  INSERT INTO tokens(member_id, token_hash, type, expires_at)
  VALUES (v_mid, v_tok, 'VOTING', now() + interval '1 day') RETURNING id INTO v_tid;
  SELECT o_success, o_message, o_credential, o_ttl_seconds INTO v_ok, v_msg, v_cred, v_ttl FROM private.redeem_voting_token(v_tok);
  UPDATE digital_credential_reservations
     SET expires_at = now() - interval '1 minute'
   WHERE token_id = v_tid;
  SELECT o_success, o_message, o_receipt_code, o_ballot_id INTO v_ok, v_msg, v_receipt, v_ballot FROM private.cast_anonymous_digital_vote(v_cred, v_cand1);
  IF v_ok IS FALSE THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 5 A5 cast with expired reservation refused';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 5 A5';
  END IF;

  -- 6
  SELECT o_success, o_message, o_receipt_code, o_ballot_id INTO v_ok, v_msg, v_receipt, v_ballot
    FROM private.cast_anonymous_digital_vote('DVC-garbage-invalid', v_cand1);
  IF v_ok IS FALSE THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 6 A6 cast with garbage credential refused';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 6 A6';
  END IF;

  -- 7
  INSERT INTO members(member_code, full_name, voting_eligible, is_active)
  VALUES ('W7T-A7-M', 'W7 A7', TRUE, TRUE) RETURNING id INTO v_mid;
  v_tok := 'w7t-a7-hash';
  INSERT INTO tokens(member_id, token_hash, type, is_used, used_at, expires_at)
  VALUES (v_mid, v_tok, 'VOTING', TRUE, now(), now() + interval '1 day');
  SELECT o_success, o_message, o_credential, o_ttl_seconds INTO v_ok, v_msg, v_cred, v_ttl FROM private.redeem_voting_token(v_tok);
  IF v_ok IS FALSE THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 7 A7 redeem used token refused';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 7 A7';
  END IF;

  -- 8
  INSERT INTO members(member_code, full_name, voting_eligible, is_active)
  VALUES ('W7T-A8-M', 'W7 A8', TRUE, TRUE) RETURNING id INTO v_mid;
  v_tok := 'w7t-a8-hash';
  INSERT INTO tokens(member_id, token_hash, type, voided_at, void_reason, expires_at)
  VALUES (v_mid, v_tok, 'VOTING', now(), 'voided', now() + interval '1 day');
  SELECT o_success, o_message, o_credential, o_ttl_seconds INTO v_ok, v_msg, v_cred, v_ttl FROM private.redeem_voting_token(v_tok);
  IF v_ok IS FALSE THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 8 A8 redeem voided token refused';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 8 A8';
  END IF;

  -- 9
  INSERT INTO members(member_code, full_name, voting_eligible, is_active)
  VALUES ('W7T-A9-M', 'W7 A9', TRUE, TRUE) RETURNING id INTO v_mid;
  v_tok := 'w7t-a9-hash';
  INSERT INTO tokens(member_id, token_hash, type, expires_at)
  VALUES (v_mid, v_tok, 'VOTING', now() - interval '1 minute');
  SELECT o_success, o_message, o_credential, o_ttl_seconds INTO v_ok, v_msg, v_cred, v_ttl FROM private.redeem_voting_token(v_tok);
  IF v_ok IS FALSE THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 9 A9 redeem expired token refused';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 9 A9';
  END IF;

  -- 10
  UPDATE election_settings SET digital_write_mode = 'TWO_PHASE' WHERE id = 1;
  INSERT INTO members(member_code, full_name, voting_eligible, is_active)
  VALUES ('W7T-A10-M', 'W7 A10', TRUE, TRUE) RETURNING id INTO v_mid;
  v_tok := 'w7t-a10-hash';
  INSERT INTO tokens(member_id, token_hash, type, expires_at)
  VALUES (v_mid, v_tok, 'VOTING', now() + interval '1 day');
  SELECT success, message, receipt_code, ballot_id INTO v_ok, v_msg, v_receipt, v_ballot
    FROM private.submit_anonymous_vote(v_tok, v_cand1);
  IF v_ok IS FALSE THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 10 A10 legacy submit fail-closed in TWO_PHASE';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 10 A10';
  END IF;

  -- 11
  UPDATE election_settings SET digital_write_mode = 'LEGACY' WHERE id = 1;
  INSERT INTO members(member_code, full_name, voting_eligible, is_active)
  VALUES ('W7T-A11-M', 'W7 A11', TRUE, TRUE) RETURNING id INTO v_mid;
  v_tok := 'w7t-a11-hash';
  INSERT INTO tokens(member_id, token_hash, type, expires_at)
  VALUES (v_mid, v_tok, 'VOTING', now() + interval '1 day');
  SELECT success, message, receipt_code, ballot_id INTO v_ok, v_msg, v_receipt, v_ballot
    FROM private.submit_anonymous_vote(v_tok, v_cand1);
  IF v_ok IS TRUE THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 11 A11 legacy submit works in LEGACY mode';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 11 A11';
  END IF;

  -- 12
  SELECT o_success, o_message, o_credential, o_ttl_seconds INTO v_ok, v_msg, v_cred, v_ttl
    FROM private.redeem_voting_token('w7t-a1-hash');
  IF v_ok IS FALSE THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 12 A12 redeem after cast refused';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 12 A12';
  END IF;

  ------------------------------------------------------------------------------
  -- B. Cross-channel exclusivity
  ------------------------------------------------------------------------------

  -- 13
  INSERT INTO members(member_code, full_name, voting_eligible, is_active)
  VALUES ('W7T-B13-M', 'W7 B13', TRUE, TRUE) RETURNING id INTO v_mid;
  v_tok := 'w7t-b13-hash';
  v_sc := 'W7B13SC';
  INSERT INTO tokens(member_id, token_hash, type, expires_at) VALUES (v_mid, v_tok, 'VOTING', now() + interval '1 day');
  INSERT INTO paper_ballots(short_code, status) VALUES (v_sc, 'AVAILABLE');
  SELECT o_success, o_message, o_credential, o_ttl_seconds INTO v_ok, v_msg, v_cred, v_ttl FROM private.redeem_voting_token(v_tok);
  SELECT success, message
    INTO v_ok, v_msg
    FROM private.check_in_paper_voter(v_sc, v_mid, NULL);
  IF v_ok IS FALSE THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 13 B13 paper check-in refused with active digital reservation';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 13 B13';
  END IF;

  -- 14
  INSERT INTO members(member_code, full_name, voting_eligible, is_active)
  VALUES ('W7T-B14-M', 'W7 B14', TRUE, TRUE) RETURNING id INTO v_mid;
  v_tok := 'w7t-b14-hash';
  v_sc := 'W7B14SC';
  INSERT INTO tokens(member_id, token_hash, type, expires_at) VALUES (v_mid, v_tok, 'VOTING', now() + interval '1 day');
  INSERT INTO paper_ballots(short_code, status) VALUES (v_sc, 'AVAILABLE');
  SELECT success, message
    INTO v_ok, v_msg
    FROM private.check_in_paper_voter(v_sc, v_mid, NULL);
  SELECT o_success, o_message, o_credential, o_ttl_seconds INTO v_ok, v_msg, v_cred, v_ttl FROM private.redeem_voting_token(v_tok);
  IF v_ok IS FALSE THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 14 B14 redeem refused after paper check-in';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 14 B14';
  END IF;

  -- 15
  INSERT INTO members(member_code, full_name, voting_eligible, is_active)
  VALUES ('W7T-B15-M', 'W7 B15', TRUE, TRUE) RETURNING id INTO v_mid;
  v_tok := 'w7t-b15-hash';
  INSERT INTO tokens(member_id, token_hash, type, expires_at) VALUES (v_mid, v_tok, 'VOTING', now() + interval '1 day');
  INSERT INTO paper_ballots(short_code, status, member_id) VALUES ('W7B15SC', 'ISSUED', v_mid);
  SELECT o_success, o_message, o_credential, o_ttl_seconds INTO v_ok, v_msg, v_cred, v_ttl FROM private.redeem_voting_token(v_tok);
  IF v_ok IS FALSE THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 15 B15 redeem refused when paper_ballots status blocks';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 15 B15';
  END IF;

  -- 16
  INSERT INTO members(member_code, full_name, voting_eligible, is_active)
  VALUES ('W7T-B16-M', 'W7 B16', TRUE, TRUE) RETURNING id INTO v_mid;
  v_tok := 'w7t-b16-hash';
  v_sc := 'W7B16SC';
  INSERT INTO tokens(member_id, token_hash, type, expires_at) VALUES (v_mid, v_tok, 'VOTING', now() + interval '1 day');
  INSERT INTO paper_ballots(short_code, status) VALUES (v_sc, 'AVAILABLE');
  SELECT o_success, o_message, o_credential, o_ttl_seconds INTO v_ok, v_msg, v_cred, v_ttl FROM private.redeem_voting_token(v_tok);
  SELECT o_success, o_message, o_receipt_code, o_ballot_id INTO v_ok, v_msg, v_receipt, v_ballot FROM private.cast_anonymous_digital_vote(v_cred, v_cand1);
  SELECT success, message
    INTO v_ok, v_msg
    FROM private.check_in_paper_voter(v_sc, v_mid, NULL);
  IF v_ok IS FALSE THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 16 B16 paper check-in refused after digital cast';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 16 B16';
  END IF;

  -- 17
  INSERT INTO members(member_code, full_name, voting_eligible, is_active)
  VALUES ('W7T-B17-M', 'W7 B17', TRUE, TRUE) RETURNING id INTO v_mid;
  v_tok := 'w7t-b17-hash';
  INSERT INTO tokens(member_id, token_hash, type, expires_at) VALUES (v_mid, v_tok, 'VOTING', now() + interval '1 day') RETURNING id INTO v_tid;
  SELECT o_success, o_message, o_credential, o_ttl_seconds INTO v_ok, v_msg, v_cred, v_ttl FROM private.redeem_voting_token(v_tok);
  SELECT success, message INTO v_ok, v_msg FROM private.reissue_token(v_tid, NULL, 'w7 test', 'w7t-b17-newhash');
  IF v_ok IS FALSE THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 17 B17 reissue refused while active digital reservation';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 17 B17';
  END IF;

  -- 18
  INSERT INTO members(member_code, full_name, voting_eligible, is_active)
  VALUES ('W7T-B18-M', 'W7 B18', TRUE, TRUE) RETURNING id INTO v_mid;
  v_tok := 'w7t-b18-hash';
  INSERT INTO tokens(member_id, token_hash, type, expires_at) VALUES (v_mid, v_tok, 'VOTING', now() + interval '1 day') RETURNING id INTO v_tid;
  SELECT o_success, o_message, o_credential, o_ttl_seconds INTO v_ok, v_msg, v_cred, v_ttl FROM private.redeem_voting_token(v_tok);
  SELECT o_success, o_message INTO v_ok, v_msg FROM private.release_digital_voting_reservation(v_tok);
  SELECT success, message INTO v_ok, v_msg FROM private.reissue_token(v_tid, NULL, 'w7 test', 'w7t-b18-newhash');
  IF v_ok IS TRUE THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 18 B18 reissue succeeds after reservation release';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 18 B18';
  END IF;

  -- 19
  INSERT INTO members(member_code, full_name, voting_eligible, is_active)
  VALUES ('W7T-B19-M', 'W7 B19', TRUE, TRUE) RETURNING id INTO v_mid;
  v_tok := 'w7t-b19-hash';
  v_sc := 'W7B19SC';
  INSERT INTO tokens(member_id, token_hash, type, expires_at) VALUES (v_mid, v_tok, 'VOTING', now() + interval '1 day');
  INSERT INTO paper_ballots(short_code, status) VALUES (v_sc, 'AVAILABLE');
  SELECT o_success, o_message, o_credential, o_ttl_seconds INTO v_ok, v_msg, v_cred, v_ttl FROM private.redeem_voting_token(v_tok);
  SELECT success, message INTO v_ok, v_msg FROM private.spoil_paper_check_in(v_sc, 'w7 test', NULL);
  IF v_ok IS FALSE THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 19 B19 spoil_paper_check_in refused for non-PAPER reservation';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 19 B19';
  END IF;

  -- 20
  INSERT INTO members(member_code, full_name, voting_eligible, is_active)
  VALUES ('W7T-B20-M', 'W7 B20', TRUE, TRUE) RETURNING id INTO v_mid;
  v_tok := 'w7t-b20-hash';
  v_sc := 'W7B20SC';
  INSERT INTO tokens(member_id, token_hash, type, expires_at) VALUES (v_mid, v_tok, 'VOTING', now() + interval '1 day');
  INSERT INTO paper_ballots(short_code, status) VALUES (v_sc, 'AVAILABLE');
  SELECT success, message
    INTO v_ok, v_msg
    FROM private.check_in_paper_voter(v_sc, v_mid, NULL);
  UPDATE paper_ballots SET status = 'SPOILED' WHERE short_code = v_sc;
  SELECT success, message INTO v_ok, v_msg FROM private.spoil_paper_check_in(v_sc, 'w7 test', NULL);
  IF v_ok IS FALSE THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 20 B20 spoil_paper_check_in refused unless ISSUED_TO_VOTER';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 20 B20';
  END IF;

  ------------------------------------------------------------------------------
  -- C. Unlinkability / no-shared-handle (no-co-occurrence invariant)
  ------------------------------------------------------------------------------

  -- 21
  SELECT count(*) INTO v_col_count
    FROM information_schema.columns
   WHERE table_schema = 'public'
     AND table_name = 'anonymous_digital_credentials'
     AND column_name IN ('member_id', 'token_id');
  IF v_col_count = 0 THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 21 C21 anonymous_digital_credentials has no member_id/token_id columns';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 21 C21';
  END IF;

  -- 22
  INSERT INTO members(member_code, full_name, voting_eligible, is_active)
  VALUES ('W7T-C22-M', 'W7 C22', TRUE, TRUE) RETURNING id INTO v_mid;
  v_tok := 'w7t-c22-hash';
  INSERT INTO tokens(member_id, token_hash, type, expires_at) VALUES (v_mid, v_tok, 'VOTING', now() + interval '1 day');
  SELECT o_success, o_message, o_credential, o_ttl_seconds INTO v_ok, v_msg, v_cred, v_ttl FROM private.redeem_voting_token(v_tok);
  SELECT o_success, o_message, o_receipt_code, o_ballot_id INTO v_ok, v_msg, v_receipt, v_ballot FROM private.cast_anonymous_digital_vote(v_cred, v_cand1);
  SELECT count(*) INTO v_col_count
    FROM information_schema.columns
   WHERE table_schema='public' AND table_name='ballots' AND column_name IN ('member_id','token_id','credential','credential_hash');
  SELECT EXISTS(
    SELECT 1 FROM ballots
    WHERE ballot_id = v_ballot
      AND candidate_id = v_cand1
      AND receipt_code IS NOT NULL
      AND channel = 'DIGITAL'
      AND cast_date IS NOT NULL
  ) INTO v_exists;
  IF v_col_count = 0 AND v_exists IS TRUE THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 22 C22 ballots row exists with anon fields; no member/token/credential columns';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 22 C22';
  END IF;

  -- 23
  v_err := FALSE;
  BEGIN
    INSERT INTO participation_audit(action, member_id, channel, details)
    VALUES ('W7T', v_base_member, 'DIGITAL', '{"credential":"x"}'::jsonb);
  EXCEPTION WHEN check_violation OR others THEN
    v_err := TRUE;
  END;
  IF v_err THEN v_pass := v_pass + 1; RAISE NOTICE 'PASS 23 C23 participation_audit rejects details.credential';
  ELSE v_fail := v_fail + 1; RAISE NOTICE 'FAIL 23 C23'; END IF;

  -- 24
  v_err := FALSE;
  BEGIN
    INSERT INTO participation_audit(action, member_id, channel, details)
    VALUES ('W7T', v_base_member, 'DIGITAL', '{"credential_hash":"x"}'::jsonb);
  EXCEPTION WHEN check_violation OR others THEN
    v_err := TRUE;
  END;
  IF v_err THEN v_pass := v_pass + 1; RAISE NOTICE 'PASS 24 C24 participation_audit rejects details.credential_hash';
  ELSE v_fail := v_fail + 1; RAISE NOTICE 'FAIL 24 C24'; END IF;

  -- 25
  v_err := FALSE;
  BEGIN
    INSERT INTO participation_audit(action, member_id, channel, details)
    VALUES ('W7T', v_base_member, 'DIGITAL', '{"reservation_id":"x"}'::jsonb);
  EXCEPTION WHEN check_violation OR others THEN
    v_err := TRUE;
  END;
  IF v_err THEN v_pass := v_pass + 1; RAISE NOTICE 'PASS 25 C25 participation_audit rejects details.reservation_id';
  ELSE v_fail := v_fail + 1; RAISE NOTICE 'FAIL 25 C25'; END IF;

  -- 26
  v_err := FALSE;
  BEGIN
    INSERT INTO ballot_audit_log(action, channel, details)
    VALUES ('W7T', 'DIGITAL', '{"credential_hash":"x"}'::jsonb);
  EXCEPTION WHEN check_violation OR others THEN
    v_err := TRUE;
  END;
  IF v_err THEN v_pass := v_pass + 1; RAISE NOTICE 'PASS 26 C26 ballot_audit_log rejects details.credential_hash';
  ELSE v_fail := v_fail + 1; RAISE NOTICE 'FAIL 26 C26'; END IF;

  -- 27
  v_err := FALSE;
  BEGIN
    INSERT INTO ballot_audit_log(action, channel, details)
    VALUES ('W7T', 'DIGITAL', '{"reservation_id":"x"}'::jsonb);
  EXCEPTION WHEN check_violation OR others THEN
    v_err := TRUE;
  END;
  IF v_err THEN v_pass := v_pass + 1; RAISE NOTICE 'PASS 27 C27 ballot_audit_log rejects details.reservation_id';
  ELSE v_fail := v_fail + 1; RAISE NOTICE 'FAIL 27 C27'; END IF;

  -- 28
  v_err := FALSE;
  BEGIN
    INSERT INTO vote_audit_log(action, member_id, details)
    VALUES ('W7T', v_base_member, '{"credential_hash":"x"}'::jsonb);
  EXCEPTION WHEN check_violation OR others THEN
    v_err := TRUE;
  END;
  IF v_err THEN v_pass := v_pass + 1; RAISE NOTICE 'PASS 28 C28 vote_audit_log rejects member+credential_hash co-occurrence';
  ELSE v_fail := v_fail + 1; RAISE NOTICE 'FAIL 28 C28'; END IF;

  -- 29
  v_err := FALSE;
  BEGIN
    INSERT INTO vote_audit_log(action, member_id, details)
    VALUES ('W7T', v_base_member, '{"reservation_id":"x"}'::jsonb);
  EXCEPTION WHEN check_violation OR others THEN
    v_err := TRUE;
  END;
  IF v_err THEN v_pass := v_pass + 1; RAISE NOTICE 'PASS 29 C29 vote_audit_log rejects member+reservation_id co-occurrence';
  ELSE v_fail := v_fail + 1; RAISE NOTICE 'FAIL 29 C29'; END IF;

  -- 30
  SELECT c.relrowsecurity INTO v_bool
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname='public' AND c.relname='digital_credential_reservations';
  IF v_bool IS TRUE THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 30 C30 digital_credential_reservations has RLS enabled';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 30 C30';
  END IF;

  -- 31
  v_err := FALSE;
  BEGIN
    INSERT INTO participation_audit(action, member_id, channel, details)
    VALUES ('W7T', v_base_member, 'DIGITAL', '{"note":"x"}'::jsonb);
  EXCEPTION WHEN others THEN
    v_err := TRUE;
  END;
  IF v_err IS FALSE THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 31 C31 control insert into participation_audit succeeds';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 31 C31';
  END IF;

  -- Positive controls for probes 26-29: benign inserts into these two audit
  -- tables MUST succeed, else the bad-key rejections above are false-passes.
  v_err:=FALSE; BEGIN INSERT INTO ballot_audit_log(action,channel,details) VALUES ('W7T','DIGITAL','{"note":"ok"}'::jsonb); EXCEPTION WHEN others THEN v_err:=TRUE; END;
  IF v_err IS TRUE THEN RAISE EXCEPTION 'CONTROL_FAIL: benign ballot_audit_log insert rejected — probes 26/27 may false-pass'; END IF;
  v_err:=FALSE; BEGIN INSERT INTO vote_audit_log(action,member_id,details) VALUES ('W7T',v_base_member,'{"note":"ok"}'::jsonb); EXCEPTION WHEN others THEN v_err:=TRUE; END;
  IF v_err IS TRUE THEN RAISE EXCEPTION 'CONTROL_FAIL: benign vote_audit_log insert rejected — probes 28/29 may false-pass'; END IF;

  -- 32
  INSERT INTO members(member_code, full_name, voting_eligible, is_active)
  VALUES ('W7T-C32-M', 'W7 C32', TRUE, TRUE) RETURNING id INTO v_mid;
  v_tok := 'w7t-c32-hash';
  INSERT INTO tokens(member_id, token_hash, type, expires_at) VALUES (v_mid, v_tok, 'VOTING', now() + interval '1 day');
  SELECT o_success, o_message, o_credential, o_ttl_seconds INTO v_ok, v_msg, v_cred, v_ttl FROM private.redeem_voting_token(v_tok);
  v_redeem_sig := pg_get_function_result('private.redeem_voting_token(character varying)'::regprocedure);
  IF v_ok IS TRUE AND v_cred IS NOT NULL AND v_cred LIKE 'DVC-%'
     AND v_redeem_sig ILIKE '%o_success%'
     AND v_redeem_sig ILIKE '%o_message%'
     AND v_redeem_sig ILIKE '%o_credential%'
     AND v_redeem_sig ILIKE '%o_ttl_seconds%'
     AND v_redeem_sig NOT ILIKE '%token%'
     AND v_redeem_sig NOT ILIKE '%member%'
  THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 32 C32 redeem return has o_* cols and DVC-* credential only';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 32 C32';
  END IF;

  -- 33
  SELECT o_success, o_message, o_receipt_code, o_ballot_id INTO v_ok, v_msg, v_receipt, v_ballot
    FROM private.cast_anonymous_digital_vote(v_cred, v_cand1);
  v_cast_sig := pg_get_function_result('private.cast_anonymous_digital_vote(text,uuid)'::regprocedure);
  IF v_ok IS TRUE AND v_receipt IS NOT NULL AND v_ballot IS NOT NULL
     AND v_cast_sig ILIKE '%o_success%'
     AND v_cast_sig ILIKE '%o_message%'
     AND v_cast_sig ILIKE '%o_receipt_code%'
     AND v_cast_sig ILIKE '%o_ballot_id%'
     AND v_cast_sig NOT ILIKE '%credential%'
     AND v_cast_sig NOT ILIKE '%token%'
     AND v_cast_sig NOT ILIKE '%member%'
  THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 33 C33 cast return has o_* cols with receipt+ballot only';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 33 C33';
  END IF;

  ------------------------------------------------------------------------------
  -- D. TTL sweep
  ------------------------------------------------------------------------------

  -- 34
  INSERT INTO members(member_code, full_name, voting_eligible, is_active)
  VALUES ('W7T-D34-M', 'W7 D34', TRUE, TRUE) RETURNING id INTO v_mid;
  v_tok := 'w7t-d34-hash';
  INSERT INTO tokens(member_id, token_hash, type, reserved_at, reserved_channel, expires_at)
  VALUES (v_mid, v_tok, 'VOTING', now(), 'DIGITAL', now() + interval '1 day') RETURNING id INTO v_tid;
  INSERT INTO anonymous_digital_credentials(credential_hash, status)
  VALUES (encode(digest('DVC-W7D34','sha256'),'hex'), 'RESERVED');
  INSERT INTO digital_credential_reservations(credential_hash, token_id, expires_at)
  VALUES (encode(digest('DVC-W7D34','sha256'),'hex'), v_tid, now() - interval '1 minute');
  SELECT private.sweep_expired_digital_reservations() INTO v_cnt;
  SELECT reserved_channel IS NULL INTO v_bool FROM tokens WHERE id = v_tid;
  SELECT EXISTS(SELECT 1 FROM digital_credential_reservations WHERE token_id = v_tid) INTO v_exists;
  IF v_cnt >= 1 AND v_bool IS TRUE AND v_exists IS FALSE THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 34 D34 sweep frees expired digital reservation';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 34 D34';
  END IF;

  -- 35
  INSERT INTO members(member_code, full_name, voting_eligible, is_active)
  VALUES ('W7T-D35-M', 'W7 D35', TRUE, TRUE) RETURNING id INTO v_mid;
  v_tok := 'w7t-d35-hash';
  INSERT INTO tokens(member_id, token_hash, type, is_used, used_at, reserved_at, reserved_channel, expires_at)
  VALUES (v_mid, v_tok, 'VOTING', TRUE, now(), now(), 'DIGITAL', now() + interval '1 day') RETURNING id INTO v_tid;
  INSERT INTO anonymous_digital_credentials(credential_hash, status)
  VALUES (encode(digest('DVC-W7D35','sha256'),'hex'), 'RESERVED');
  INSERT INTO digital_credential_reservations(credential_hash, token_id, expires_at)
  VALUES (encode(digest('DVC-W7D35','sha256'),'hex'), v_tid, now() - interval '1 minute');
  SELECT private.sweep_expired_digital_reservations() INTO v_cnt;
  SELECT (is_used = TRUE AND reserved_channel = 'DIGITAL') INTO v_bool FROM tokens WHERE id = v_tid;
  IF v_bool IS TRUE THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 35 D35 sweep does not free used token';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 35 D35';
  END IF;

  -- 36
  INSERT INTO members(member_code, full_name, voting_eligible, is_active)
  VALUES ('W7T-D36-M', 'W7 D36', TRUE, TRUE) RETURNING id INTO v_mid;
  v_tok := 'w7t-d36-hash';
  INSERT INTO tokens(member_id, token_hash, type, reserved_at, reserved_channel, is_used, expires_at)
  VALUES (v_mid, v_tok, 'VOTING', now(), 'PAPER', FALSE, now() + interval '1 day') RETURNING id INTO v_tid;
  INSERT INTO anonymous_digital_credentials(credential_hash, status)
  VALUES (encode(digest('DVC-W7D36','sha256'),'hex'), 'RESERVED');
  INSERT INTO digital_credential_reservations(credential_hash, token_id, expires_at)
  VALUES (encode(digest('DVC-W7D36','sha256'),'hex'), v_tid, now() - interval '1 minute');
  SELECT private.sweep_expired_digital_reservations() INTO v_cnt;
  SELECT (reserved_channel = 'PAPER') INTO v_bool FROM tokens WHERE id = v_tid;
  IF v_bool IS TRUE THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 36 D36 sweep leaves PAPER-reserved token untouched';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 36 D36';
  END IF;

  -- 37
  INSERT INTO members(member_code, full_name, voting_eligible, is_active)
  VALUES ('W7T-D37-M', 'W7 D37', TRUE, TRUE) RETURNING id INTO v_mid;
  v_tok := 'w7t-d37-hash';
  INSERT INTO tokens(member_id, token_hash, type, reserved_at, reserved_channel, expires_at)
  VALUES (v_mid, v_tok, 'VOTING', now(), 'DIGITAL', now() + interval '1 day') RETURNING id INTO v_tid;
  INSERT INTO anonymous_digital_credentials(credential_hash, status)
  VALUES (encode(digest('DVC-W7D37','sha256'),'hex'), 'RESERVED');
  INSERT INTO digital_credential_reservations(credential_hash, token_id, expires_at)
  VALUES (encode(digest('DVC-W7D37','sha256'),'hex'), v_tid, now() - interval '1 minute');
  SELECT o_success, o_message, o_credential, o_ttl_seconds INTO v_ok, v_msg, v_cred, v_ttl
    FROM private.redeem_voting_token(v_tok);
  IF v_ok IS TRUE THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 37 D37 redeem internally sweeps expired reservation';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 37 D37';
  END IF;

  ------------------------------------------------------------------------------
  -- E. OUT-column shadowing / 42702 regression
  ------------------------------------------------------------------------------

  -- 38
  INSERT INTO members(member_code, full_name, voting_eligible, is_active)
  VALUES ('W7T-E38-M', 'W7 E38', TRUE, TRUE) RETURNING id INTO v_mid;
  v_tok := 'w7t-e38-hash';
  INSERT INTO tokens(member_id, token_hash, type, expires_at)
  VALUES (v_mid, v_tok, 'VOTING', now() + interval '1 day');
  v_err := FALSE;
  BEGIN
    SELECT o_success, o_message, o_credential, o_ttl_seconds INTO v_ok, v_msg, v_cred, v_ttl
      FROM private.redeem_voting_token(v_tok);
  EXCEPTION WHEN others THEN
    v_err := (SQLSTATE = '42702');
  END;
  IF v_err IS FALSE THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 38 E38 redeem executes without 42702';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 38 E38';
  END IF;

  -- 39
  v_err := FALSE;
  BEGIN
    SELECT o_success, o_message, o_receipt_code, o_ballot_id INTO v_ok, v_msg, v_receipt, v_ballot
      FROM private.cast_anonymous_digital_vote(v_cred, v_cand1);
  EXCEPTION WHEN others THEN
    v_err := (SQLSTATE = '42702');
  END;
  IF v_err IS FALSE THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 39 E39 cast executes without 42702';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 39 E39';
  END IF;

  -- 40
  v_err := FALSE;
  BEGIN
    SELECT o_success, o_message INTO v_ok, v_msg FROM private.release_digital_voting_reservation(v_tok);
  EXCEPTION WHEN others THEN
    v_err := (SQLSTATE = '42702');
  END;
  IF v_err IS FALSE THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 40 E40 release executes without 42702';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 40 E40';
  END IF;

  -- 41
  INSERT INTO members(member_code, full_name, voting_eligible, is_active)
  VALUES ('W7T-E41-M', 'W7 E41', TRUE, TRUE) RETURNING id INTO v_mid;
  v_tok := 'w7t-e41-hash';
  INSERT INTO tokens(member_id, token_hash, type, expires_at)
  VALUES (v_mid, v_tok, 'VOTING', now() + interval '1 day');
  v_err := FALSE;
  BEGIN
    SELECT o_success, o_message, o_credential, o_ttl_seconds INTO v_ok, v_msg, v_cred, v_ttl FROM public.redeem_voting_token(v_tok);
    SELECT o_success, o_message, o_receipt_code, o_ballot_id INTO v_ok, v_msg, v_receipt, v_ballot FROM public.cast_anonymous_digital_vote(v_cred, v_cand1);
    SELECT o_success, o_message INTO v_ok, v_msg FROM public.release_digital_voting_reservation(v_tok);
  EXCEPTION WHEN others THEN
    v_err := TRUE;
  END;
  IF v_err IS FALSE THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 41 E41 all three public wrappers execute and return rows';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 41 E41';
  END IF;

  ------------------------------------------------------------------------------
  -- F. Grants / RLS
  ------------------------------------------------------------------------------

  -- 42
  SELECT c.relrowsecurity INTO v_bool
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE n.nspname='public' AND c.relname='anonymous_digital_credentials';
  IF v_bool IS TRUE THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 42 F42 anonymous_digital_credentials has RLS enabled';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 42 F42';
  END IF;

  -- 43
  SELECT c.relrowsecurity INTO v_bool
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE n.nspname='public' AND c.relname='digital_credential_reservations';
  IF v_bool IS TRUE THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 43 F43 digital_credential_reservations has RLS enabled';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 43 F43';
  END IF;

  -- 44
  IF has_table_privilege('service_role','public.anonymous_digital_credentials','INSERT')
     AND has_table_privilege('service_role','public.digital_credential_reservations','INSERT')
  THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 44 F44 service_role has INSERT privileges on both new tables';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 44 F44';
  END IF;

  -- 45
  IF NOT has_function_privilege('anon','private.redeem_voting_token(character varying)','EXECUTE')
     AND NOT has_function_privilege('authenticated','private.redeem_voting_token(character varying)','EXECUTE')
     AND NOT has_function_privilege('anon','private.cast_anonymous_digital_vote(text,uuid)','EXECUTE')
     AND NOT has_function_privilege('authenticated','private.cast_anonymous_digital_vote(text,uuid)','EXECUTE')
     AND NOT has_function_privilege('anon','private.release_digital_voting_reservation(character varying)','EXECUTE')
     AND NOT has_function_privilege('authenticated','private.release_digital_voting_reservation(character varying)','EXECUTE')
  THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 45 F45 anon/authenticated lack EXECUTE on private digital RPCs';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 45 F45';
  END IF;

  -- 46
  IF NOT has_function_privilege('anon','public.redeem_voting_token(character varying)','EXECUTE')
     AND NOT has_function_privilege('authenticated','public.redeem_voting_token(character varying)','EXECUTE')
     AND NOT has_function_privilege('anon','public.cast_anonymous_digital_vote(text,uuid)','EXECUTE')
     AND NOT has_function_privilege('authenticated','public.cast_anonymous_digital_vote(text,uuid)','EXECUTE')
     AND NOT has_function_privilege('anon','public.release_digital_voting_reservation(character varying)','EXECUTE')
     AND NOT has_function_privilege('authenticated','public.release_digital_voting_reservation(character varying)','EXECUTE')
  THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 46 F46 anon/authenticated lack EXECUTE on public wrappers';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 46 F46';
  END IF;

  ------------------------------------------------------------------------------
  -- G. Status / phase / constraint gates
  ------------------------------------------------------------------------------

  -- 47
  INSERT INTO members(member_code, full_name, voting_eligible, is_active)
  VALUES ('W7T-G47-M', 'W7 G47', TRUE, TRUE) RETURNING id INTO v_mid;
  v_tok := 'w7t-g47-hash';
  INSERT INTO tokens(member_id, token_hash, type, expires_at)
  VALUES (v_mid, v_tok, 'VOTING', now() + interval '1 day');
  UPDATE election_settings SET current_phase = 'COMPLETED' WHERE id = 1;
  SELECT o_success, o_message, o_credential, o_ttl_seconds INTO v_ok, v_msg, v_cred, v_ttl FROM private.redeem_voting_token(v_tok);
  UPDATE election_settings SET current_phase = 'VOTING' WHERE id = 1;
  IF v_ok IS FALSE THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 47 G47 redeem refused outside VOTING phase';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 47 G47';
  END IF;

  -- 48
  INSERT INTO members(member_code, full_name, voting_eligible, is_active)
  VALUES ('W7T-G48-M', 'W7 G48', TRUE, TRUE) RETURNING id INTO v_mid;
  v_tok := 'w7t-g48-hash';
  INSERT INTO tokens(member_id, token_hash, type, expires_at)
  VALUES (v_mid, v_tok, 'VOTING', now() + interval '1 day');
  SELECT o_success, o_message, o_credential, o_ttl_seconds INTO v_ok, v_msg, v_cred, v_ttl FROM private.redeem_voting_token(v_tok);
  UPDATE election_settings SET current_phase = 'COMPLETED' WHERE id = 1;
  SELECT o_success, o_message, o_receipt_code, o_ballot_id INTO v_ok, v_msg, v_receipt, v_ballot FROM private.cast_anonymous_digital_vote(v_cred, v_cand1);
  UPDATE election_settings SET current_phase = 'VOTING' WHERE id = 1;
  IF v_ok IS FALSE THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 48 G48 cast refused outside VOTING phase';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 48 G48';
  END IF;

  -- 49
  INSERT INTO members(member_code, full_name, voting_eligible, is_active)
  VALUES ('W7T-G49-M', 'W7 G49', TRUE, TRUE) RETURNING id INTO v_mid;
  v_tok := 'w7t-g49-hash';
  INSERT INTO tokens(member_id, token_hash, type, expires_at)
  VALUES (v_mid, v_tok, 'VOTING', now() + interval '1 day');
  UPDATE election_settings SET voting_end = now() - interval '1 minute' WHERE id = 1;
  SELECT o_success, o_message, o_credential, o_ttl_seconds INTO v_ok, v_msg, v_cred, v_ttl FROM private.redeem_voting_token(v_tok);
  UPDATE election_settings SET voting_end = now() + interval '1 day' WHERE id = 1;
  IF v_ok IS FALSE THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 49 G49 redeem refused when voting_end is in past';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 49 G49';
  END IF;

  -- 50
  v_err := FALSE;
  BEGIN
    INSERT INTO anonymous_digital_credentials(credential_hash, status)
    VALUES (encode(digest('DVC-W7G50-BAD','sha256'),'hex'), 'BOGUS');
  EXCEPTION WHEN check_violation OR others THEN
    v_err := TRUE;
  END;
  IF v_err THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 50 G50 anonymous_digital_credentials rejects bogus status';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 50 G50';
  END IF;
  v_err := FALSE;
  BEGIN
    INSERT INTO anonymous_digital_credentials(credential_hash, status)
    VALUES (encode(digest('DVC-W7G50-OK','sha256'),'hex'), 'RESERVED');
  EXCEPTION WHEN others THEN
    v_err := TRUE;
  END;
  IF v_err THEN
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 50 G50 control RESERVED insert';
  END IF;

  -- 51
  v_err := FALSE;
  BEGIN
    UPDATE election_settings SET digital_write_mode = 'BOGUS' WHERE id = 1;
  EXCEPTION WHEN check_violation OR others THEN
    v_err := TRUE;
  END;
  IF v_err THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 51 G51 election_settings rejects bogus digital_write_mode';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 51 G51';
  END IF;
  v_err := FALSE;
  BEGIN
    UPDATE election_settings SET digital_write_mode = 'TWO_PHASE' WHERE id = 1;
  EXCEPTION WHEN others THEN
    v_err := TRUE;
  END;
  UPDATE election_settings SET digital_write_mode = 'LEGACY' WHERE id = 1;
  IF v_err THEN
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 51 G51 control TWO_PHASE update';
  END IF;

  -- 52
  v_err := FALSE;
  BEGIN
    UPDATE election_settings SET digital_credential_ttl_minutes = 0 WHERE id = 1;
  EXCEPTION WHEN check_violation OR others THEN
    v_err := TRUE;
  END;
  IF v_err IS FALSE THEN
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 52 G52 ttl=0 was accepted';
  END IF;
  v_err := FALSE;
  BEGIN
    UPDATE election_settings SET digital_credential_ttl_minutes = 1441 WHERE id = 1;
  EXCEPTION WHEN check_violation OR others THEN
    v_err := TRUE;
  END;
  IF v_err IS FALSE THEN
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 52 G52 ttl=1441 was accepted';
  END IF;
  v_err := FALSE;
  BEGIN
    UPDATE election_settings SET digital_credential_ttl_minutes = 15 WHERE id = 1;
  EXCEPTION WHEN others THEN
    v_err := TRUE;
  END;
  IF v_err IS FALSE THEN
    v_pass := v_pass + 1; RAISE NOTICE 'PASS 52 G52 ttl bounds enforce (0/1441 reject, 15 accept)';
  ELSE
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 52 G52';
  END IF;

  ------------------------------------------------------------------------------
  -- FINAL TALLY + ROLLBACK SENTINEL
  ------------------------------------------------------------------------------
  RAISE NOTICE 'Wave7 guard totals: PASS=% FAIL=% TOTAL=%', v_pass, v_fail, (v_pass + v_fail);

  IF v_fail > 0 OR (v_pass + v_fail) <> 52 OR v_pass <> 52 THEN
    RAISE EXCEPTION 'W7_GUARD_FAIL: pass=% fail=% total=% (expected pass=52 fail=0 total=52)', v_pass, v_fail, (v_pass + v_fail);
  END IF;

  RAISE EXCEPTION 'ROLLBACK_OK';
END;
$harness$;
