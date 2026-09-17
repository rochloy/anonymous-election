-- ============================================================================
-- wave6_paper_severance_guards.sql
-- v0.13.0 Wave 6 (P2) — behavioural + structural guard harness.
--
-- Purpose:
--   Prove the paper-plane structural severance (migration_wave6_paper_severance.sql,
--   canonical run-order item 34) actually enforces the no-co-occurrence invariant
--   and the split identity/anonymous workflow — by exercising KNOWN-BAD input
--   (guards that must reject) as well as happy paths (guards that must succeed).
--
-- Design (per AGENTS.md guard rule + plan P2 handoff, Option B):
--   * ONE self-rolling-back transaction. All synthetic fixtures + all side effects
--     are undone by the terminal `RAISE EXCEPTION 'ROLLBACK_OK ...'`.
--   * NOT pgTAP (avoids installing an extension + durable test objects on prod).
--   * Fail-fast: the FIRST failing guard RAISEs 'W6_GUARD_FAIL: <name> — <detail>'
--     with the pass-log so far. If every guard passes, the terminal sentinel
--     'ROLLBACK_OK: all 23 Wave6 paper-severance guards passed' is raised instead.
--   * Run via Supabase MCP `execute_sql` (orchestrator-owned). SUCCESS SIGNAL =
--     the surfaced error text begins with 'ROLLBACK_OK'. Any other error = failure
--     (the message names the guard that failed and lists the guards that passed).
--
-- Covers the 23 P2 targets from
--   docs/plans/2026-09-17-v0.13.0-wave6-paper-severance.md:150.
--
-- Idempotent: leaves NO durable rows (whole DO block rolls back).
-- ============================================================================

DO $harness$
DECLARE
  -- fixtures
  v_cand1 UUID;
  v_cand2 UUID;
  v_m1 UUID; v_t1 UUID;
  v_m2 UUID;
  v_m3 UUID;
  v_m4 UUID; v_t4 UUID;
  v_sc1 TEXT := 'W6T-SLIP-1';
  v_sc2 TEXT := 'W6T-SLIP-2';
  v_sc3 TEXT := 'W6T-SLIP-3';
  v_sc4 TEXT := 'W6T-SLIP-4';

  -- pool
  v_ids TEXT[];
  v_b1 TEXT;
  v_b2 TEXT;
  v_nonpool TEXT;

  -- rpc scratch
  v_ok BOOLEAN; v_msg TEXT; v_receipt TEXT; v_cnt INT;
  v_payload TEXT;
  v_txt TEXT; v_def TEXT; v_int INT; v_bool BOOLEAN;
  v_used_before INT; v_used_after INT;
  v_released BOOLEAN;

  -- progress log (surfaced in the terminal RAISE so the single error string is
  -- a full pass/fail report)
  v_log TEXT := '';
BEGIN
  ------------------------------------------------------------------------------
  -- FIXTURES (synthetic; rolled back)
  ------------------------------------------------------------------------------
  SELECT id INTO v_cand1 FROM candidates WHERE is_active = TRUE ORDER BY id LIMIT 1;
  SELECT id INTO v_cand2 FROM candidates WHERE is_active = TRUE AND id <> v_cand1 ORDER BY id LIMIT 1;
  IF v_cand1 IS NULL OR v_cand2 IS NULL THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: fixtures — need >=2 active candidates (found cand1=%, cand2=%)', v_cand1, v_cand2;
  END IF;

  -- M1: happy-path check-in (1 live VOTING token)
  INSERT INTO members(member_code, full_name) VALUES ('W6T-M1', 'W6 Test M1') RETURNING id INTO v_m1;
  INSERT INTO tokens(member_id, token_hash, type) VALUES (v_m1, 'w6t-hash-1', 'VOTING') RETURNING id INTO v_t1;
  INSERT INTO paper_ballots(short_code, status) VALUES (v_sc1, 'AVAILABLE');

  -- M2: zero active tokens
  INSERT INTO members(member_code, full_name) VALUES ('W6T-M2', 'W6 Test M2') RETURNING id INTO v_m2;
  INSERT INTO paper_ballots(short_code, status) VALUES (v_sc2, 'AVAILABLE');

  -- M3: multiple active tokens (both voided_at NULL). One is_used=TRUE (NOT in the
  -- partial unique index tokens_one_live_per_member_type) + one is_used=FALSE (in
  -- the index). The check-in loop counts BOTH (WHERE voided_at IS NULL), tripping
  -- the "multiple active voting tokens" integrity branch without a unique violation.
  INSERT INTO members(member_code, full_name) VALUES ('W6T-M3', 'W6 Test M3') RETURNING id INTO v_m3;
  INSERT INTO tokens(member_id, token_hash, type, is_used, channel_sent) VALUES (v_m3, 'w6t-hash-3a', 'VOTING', TRUE, 'PAPER');
  INSERT INTO tokens(member_id, token_hash, type) VALUES (v_m3, 'w6t-hash-3b', 'VOTING');
  INSERT INTO paper_ballots(short_code, status) VALUES (v_sc3, 'AVAILABLE');

  -- M4: check-in then spoil (token release path)
  INSERT INTO members(member_code, full_name) VALUES ('W6T-M4', 'W6 Test M4') RETURNING id INTO v_m4;
  INSERT INTO tokens(member_id, token_hash, type) VALUES (v_m4, 'w6t-hash-4', 'VOTING') RETURNING id INTO v_t4;
  INSERT INTO paper_ballots(short_code, status) VALUES (v_sc4, 'AVAILABLE');

  ------------------------------------------------------------------------------
  -- 1. paper_layout_default_separate_slip
  ------------------------------------------------------------------------------
  SELECT column_default INTO v_txt FROM information_schema.columns
   WHERE table_schema='public' AND table_name='election_settings' AND column_name='paper_ballot_layout';
  IF v_txt IS NULL OR v_txt NOT ILIKE '%SEPARATE_SLIP%' THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: 1.paper_layout_default_separate_slip — default=% %', v_txt, v_log;
  END IF;
  v_log := v_log || E'\n  PASS 1 paper_layout_default_separate_slip';

  ------------------------------------------------------------------------------
  -- 2. paper_layout_rejects_invalid_value
  -- The CHECK constraint is tested in isolation from the immutability trigger via
  -- a TEMP clone (LIKE ... INCLUDING CONSTRAINTS copies CHECKs, NOT triggers).
  ------------------------------------------------------------------------------
  CREATE TEMP TABLE w6t_es_probe (LIKE election_settings INCLUDING CONSTRAINTS) ON COMMIT DROP;
  INSERT INTO w6t_es_probe SELECT * FROM election_settings WHERE id = 1;
  BEGIN
    UPDATE w6t_es_probe SET paper_ballot_layout = 'BOGUS_LAYOUT';
    RAISE EXCEPTION 'W6_GUARD_FAIL: 2.paper_layout_rejects_invalid_value — CHECK accepted BOGUS_LAYOUT %', v_log;
  EXCEPTION WHEN check_violation THEN
    NULL; -- expected
  END;
  -- and a known-good value must be accepted by the CHECK
  UPDATE w6t_es_probe SET paper_ballot_layout = 'SINGLE_SHEET';
  v_log := v_log || E'\n  PASS 2 paper_layout_rejects_invalid_value';

  ------------------------------------------------------------------------------
  -- 3. paper_layout_immutable_once_voting  (phase=COMPLETED ∈ immutable set)
  ------------------------------------------------------------------------------
  BEGIN
    UPDATE election_settings
       SET paper_ballot_layout = CASE WHEN paper_ballot_layout='SEPARATE_SLIP' THEN 'SINGLE_SHEET' ELSE 'SEPARATE_SLIP' END
     WHERE id = 1;
    RAISE EXCEPTION 'W6_GUARD_FAIL: 3.paper_layout_immutable_once_voting — layout mutated at COMPLETED %', v_log;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'W6_GUARD_FAIL%' THEN RAISE; END IF;
    IF SQLERRM NOT ILIKE '%immutable%' THEN
      RAISE EXCEPTION 'W6_GUARD_FAIL: 3.paper_layout_immutable_once_voting — wrong error: % %', SQLERRM, v_log;
    END IF;
  END;
  v_log := v_log || E'\n  PASS 3 paper_layout_immutable_once_voting';

  ------------------------------------------------------------------------------
  -- 4. anonymous_paper_blanks_has_no_identity_columns
  ------------------------------------------------------------------------------
  SELECT count(*) INTO v_int FROM information_schema.columns
   WHERE table_schema='public' AND table_name='anonymous_paper_blanks'
     AND column_name IN ('member_id','short_code','token_id');
  IF v_int <> 0 THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: 4.anonymous_paper_blanks_has_no_identity_columns — found % identity col(s) %', v_int, v_log;
  END IF;
  v_log := v_log || E'\n  PASS 4 anonymous_paper_blanks_has_no_identity_columns';

  ------------------------------------------------------------------------------
  -- 5. paper_ballots_has_no_ballot_id_or_candidate_id
  ------------------------------------------------------------------------------
  SELECT count(*) INTO v_int FROM information_schema.columns
   WHERE table_schema='public' AND table_name='paper_ballots'
     AND column_name IN ('ballot_id','candidate_id');
  IF v_int <> 0 THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: 5.paper_ballots_has_no_ballot_id_or_candidate_id — found % vote col(s) %', v_int, v_log;
  END IF;
  v_log := v_log || E'\n  PASS 5 paper_ballots_has_no_ballot_id_or_candidate_id';

  ------------------------------------------------------------------------------
  -- 6. participation_audit_rejects_ballot_handles  (known-bad input)
  ------------------------------------------------------------------------------
  BEGIN
    INSERT INTO participation_audit(action, member_id, channel, details)
    VALUES ('W6T', v_m1, 'PAPER', '{"ballot_id":"x"}'::jsonb);
    RAISE EXCEPTION 'W6_GUARD_FAIL: 6.participation_audit_rejects_ballot_handles — accepted ballot_id %', v_log;
  EXCEPTION WHEN check_violation THEN NULL; -- expected
  END;
  v_log := v_log || E'\n  PASS 6 participation_audit_rejects_ballot_handles';

  ------------------------------------------------------------------------------
  -- 7. ballot_audit_rejects_identity_handles  (known-bad input)
  ------------------------------------------------------------------------------
  BEGIN
    INSERT INTO ballot_audit_log(action, channel, details)
    VALUES ('W6T', 'PAPER', '{"member_id":"x"}'::jsonb);
    RAISE EXCEPTION 'W6_GUARD_FAIL: 7.ballot_audit_rejects_identity_handles — accepted member_id %', v_log;
  EXCEPTION WHEN check_violation THEN NULL; -- expected
  END;
  v_log := v_log || E'\n  PASS 7 ballot_audit_rejects_identity_handles';

  ------------------------------------------------------------------------------
  -- 8. vote_audit_log_rejects_member_ballot_colocation  (known-bad input, trigger)
  ------------------------------------------------------------------------------
  BEGIN
    INSERT INTO vote_audit_log(action, member_id, ballot_id)
    VALUES ('W6T', v_m1, 'colocated-x');
    RAISE EXCEPTION 'W6_GUARD_FAIL: 8.vote_audit_log_rejects_member_ballot_colocation — accepted co-location %', v_log;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'W6_GUARD_FAIL%' THEN RAISE; END IF;
    IF SQLERRM NOT ILIKE '%co-locate%' THEN
      RAISE EXCEPTION 'W6_GUARD_FAIL: 8.vote_audit_log_rejects_member_ballot_colocation — wrong error: % %', SQLERRM, v_log;
    END IF;
  END;
  v_log := v_log || E'\n  PASS 8 vote_audit_log_rejects_member_ballot_colocation';

  ------------------------------------------------------------------------------
  -- 9. check_in_returns_no_ballot_id  (return signature is identity-only)
  ------------------------------------------------------------------------------
  v_txt := pg_get_function_result('public.check_in_paper_voter(text,uuid,uuid)'::regprocedure);
  IF v_txt ILIKE '%ballot_id%' OR v_txt ILIKE '%candidate_id%' THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: 9.check_in_returns_no_ballot_id — result exposes vote handle: % %', v_txt, v_log;
  END IF;
  v_log := v_log || E'\n  PASS 9 check_in_returns_no_ballot_id';

  ------------------------------------------------------------------------------
  -- 10. check_in_consumes_single_voting_token_for_update
  ------------------------------------------------------------------------------
  SELECT success, message INTO v_ok, v_msg FROM public.check_in_paper_voter(v_sc1, v_m1, NULL);
  IF v_ok IS NOT TRUE THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: 10.check_in_consumes_single_voting_token_for_update — check-in failed: % %', v_msg, v_log;
  END IF;
  SELECT is_used, channel_sent INTO v_bool, v_txt FROM tokens WHERE id = v_t1;
  IF v_bool IS NOT TRUE OR v_txt <> 'PAPER' THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: 10 — token not consumed as PAPER (is_used=%, channel=%) %', v_bool, v_txt, v_log;
  END IF;
  SELECT status::TEXT INTO v_txt FROM paper_ballots WHERE short_code = v_sc1;
  IF v_txt <> 'ISSUED_TO_VOTER' THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: 10 — slip status expected ISSUED_TO_VOTER, got % %', v_txt, v_log;
  END IF;
  v_log := v_log || E'\n  PASS 10 check_in_consumes_single_voting_token_for_update';

  ------------------------------------------------------------------------------
  -- 11. check_in_aborts_zero_active_tokens
  ------------------------------------------------------------------------------
  SELECT success, message INTO v_ok, v_msg FROM public.check_in_paper_voter(v_sc2, v_m2, NULL);
  IF v_ok IS NOT FALSE OR v_msg NOT ILIKE '%no active voting entitlement%' THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: 11.check_in_aborts_zero_active_tokens — ok=%, msg=% %', v_ok, v_msg, v_log;
  END IF;
  v_log := v_log || E'\n  PASS 11 check_in_aborts_zero_active_tokens';

  ------------------------------------------------------------------------------
  -- 12. check_in_aborts_multiple_active_tokens
  ------------------------------------------------------------------------------
  SELECT success, message INTO v_ok, v_msg FROM public.check_in_paper_voter(v_sc3, v_m3, NULL);
  IF v_ok IS NOT FALSE OR v_msg NOT ILIKE '%multiple active voting tokens%' THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: 12.check_in_aborts_multiple_active_tokens — ok=%, msg=% %', v_ok, v_msg, v_log;
  END IF;
  v_log := v_log || E'\n  PASS 12 check_in_aborts_multiple_active_tokens';

  ------------------------------------------------------------------------------
  -- 13. generate_blank_pool_returns_ballot_ids_only
  ------------------------------------------------------------------------------
  v_txt := pg_get_function_result('public.generate_anonymous_blank_ballot_pool(int,uuid)'::regprocedure);
  IF v_txt ILIKE '%member%' OR v_txt ILIKE '%short_code%' OR v_txt ILIKE '%token%' THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: 13 — pool result exposes identity handle: % %', v_txt, v_log;
  END IF;
  SELECT success, generated_count, ballot_ids INTO v_ok, v_cnt, v_ids
    FROM public.generate_anonymous_blank_ballot_pool(3, NULL);
  IF v_ok IS NOT TRUE OR v_cnt <> 3 OR array_length(v_ids, 1) <> 3 THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: 13.generate_blank_pool_returns_ballot_ids_only — ok=%, cnt=%, len=% %',
      v_ok, v_cnt, array_length(v_ids,1), v_log;
  END IF;
  v_b1 := v_ids[1];
  v_b2 := v_ids[2];
  v_log := v_log || E'\n  PASS 13 generate_blank_pool_returns_ballot_ids_only';

  ------------------------------------------------------------------------------
  -- 14. generated_ballot_id_payload_is_opaque_paper_random
  -- Payload must be EXACTLY 'PAPER:' + 64 lowercase hex chars (32 random bytes) —
  -- no embedded member/candidate/timestamp/batch identifiers.
  ------------------------------------------------------------------------------
  v_payload := private.hmac_verify(v_b1);
  IF v_payload IS NULL OR v_payload !~ '^PAPER:[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: 14.generated_ballot_id_payload_is_opaque_paper_random — payload=% %', v_payload, v_log;
  END IF;
  v_log := v_log || E'\n  PASS 14 generated_ballot_id_payload_is_opaque_paper_random';

  ------------------------------------------------------------------------------
  -- 18. record_writes_ballots_and_ballot_audit_only  (cast B1, then assert writes)
  --     (run before 16/19 which depend on B1 being CAST)
  ------------------------------------------------------------------------------
  SELECT success, message, receipt_code INTO v_ok, v_msg, v_receipt
    FROM public.submit_paper_vote(v_b1, v_cand1, NULL);
  IF v_ok IS NOT TRUE THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: 18 — submit failed: % %', v_msg, v_log;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM ballots WHERE ballot_id = v_b1 AND channel = 'PAPER' AND candidate_id = v_cand1) THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: 18 — no PAPER ballots row for cast blank %', v_log;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM ballot_audit_log WHERE ballot_id = v_b1 AND action = 'PAPER_BALLOT_CAST') THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: 18 — no PAPER_BALLOT_CAST ballot_audit_log row %', v_log;
  END IF;
  SELECT status INTO v_txt FROM anonymous_paper_blanks WHERE ballot_id = v_b1;
  IF v_txt <> 'CAST' THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: 18 — blank not marked CAST (status=%) %', v_txt, v_log;
  END IF;
  v_log := v_log || E'\n  PASS 18 record_writes_ballots_and_ballot_audit_only';

  ------------------------------------------------------------------------------
  -- 17. record_returns_no_ballot_id_or_member
  ------------------------------------------------------------------------------
  v_txt := pg_get_function_result('public.submit_paper_vote(text,uuid,uuid)'::regprocedure);
  IF v_txt ILIKE '%ballot_id%' OR v_txt ILIKE '%member%' OR v_txt NOT ILIKE '%receipt_code%' THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: 17.record_returns_no_ballot_id_or_member — result=% %', v_txt, v_log;
  END IF;
  IF v_receipt IS NULL OR v_receipt NOT LIKE 'PB-%' THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: 17 — receipt not opaque PB- code: % %', v_receipt, v_log;
  END IF;
  v_log := v_log || E'\n  PASS 17 record_returns_no_ballot_id_or_member';

  ------------------------------------------------------------------------------
  -- 16. record_rejects_non_available_blank  (double-cast B1)
  ------------------------------------------------------------------------------
  SELECT success, message INTO v_ok, v_msg FROM public.submit_paper_vote(v_b1, v_cand1, NULL);
  IF v_ok IS NOT FALSE OR v_msg NOT ILIKE '%already been cast or voided%' THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: 16.record_rejects_non_available_blank — ok=%, msg=% %', v_ok, v_msg, v_log;
  END IF;
  v_log := v_log || E'\n  PASS 16 record_rejects_non_available_blank';

  ------------------------------------------------------------------------------
  -- 15. record_rejects_non_pool_ballot_id  (valid HMAC, not in pool)
  ------------------------------------------------------------------------------
  v_nonpool := private.hmac_sign('PAPER:' || encode(gen_random_bytes(32), 'hex'));
  SELECT success, message INTO v_ok, v_msg FROM public.submit_paper_vote(v_nonpool, v_cand1, NULL);
  IF v_ok IS NOT FALSE OR v_msg NOT ILIKE '%not from the anonymous blank pool%' THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: 15.record_rejects_non_pool_ballot_id — ok=%, msg=% %', v_ok, v_msg, v_log;
  END IF;
  v_log := v_log || E'\n  PASS 15 record_rejects_non_pool_ballot_id';

  ------------------------------------------------------------------------------
  -- 19. correction_never_reads_member_tables
  --   behavioural: correct B1 to cand2 (updates ballots + ballot_audit_log)
  --   static: function body references no identity plane
  ------------------------------------------------------------------------------
  SELECT success, message INTO v_ok, v_msg FROM public.correct_paper_vote(v_b1, v_cand2, NULL, 'w6 test');
  IF v_ok IS NOT TRUE THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: 19 — correction failed: % %', v_msg, v_log;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM ballots WHERE ballot_id = v_b1 AND candidate_id = v_cand2) THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: 19 — corrected candidate not persisted %', v_log;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM ballot_audit_log WHERE ballot_id = v_b1 AND action = 'PAPER_BALLOT_CORRECTED') THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: 19 — no PAPER_BALLOT_CORRECTED audit row %', v_log;
  END IF;
  v_def := pg_get_functiondef('private.correct_paper_vote(text,uuid,uuid,text)'::regprocedure);
  IF v_def ILIKE '%members%' OR v_def ILIKE '%member_id%' OR v_def ILIKE '%short_code%' OR v_def ILIKE '%participation_audit%' THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: 19.correction_never_reads_member_tables — body references identity plane %', v_log;
  END IF;
  v_log := v_log || E'\n  PASS 19 correction_never_reads_member_tables';

  ------------------------------------------------------------------------------
  -- 20. spoil_check_in_releases_only_paper_token
  ------------------------------------------------------------------------------
  SELECT success, message INTO v_ok, v_msg FROM public.check_in_paper_voter(v_sc4, v_m4, NULL);
  IF v_ok IS NOT TRUE THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: 20 — precondition check-in failed: % %', v_msg, v_log;
  END IF;
  SELECT success, message INTO v_ok, v_msg FROM public.spoil_paper_check_in(v_sc4, 'w6 test spoil', NULL);
  IF v_ok IS NOT TRUE THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: 20.spoil_check_in_releases_only_paper_token — spoil failed: % %', v_msg, v_log;
  END IF;
  SELECT is_used, reservation_released_at IS NOT NULL INTO v_bool, v_released FROM tokens WHERE id = v_t4;
  IF v_bool IS NOT FALSE OR v_released IS NOT TRUE THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: 20 — token not released (is_used=%, released=%) %', v_bool, v_released, v_log;
  END IF;
  SELECT status::TEXT INTO v_txt FROM paper_ballots WHERE short_code = v_sc4;
  IF v_txt <> 'SPOILED' THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: 20 — slip status expected SPOILED, got % %', v_txt, v_log;
  END IF;
  -- must NOT have touched M1's consumed token (only the paper reservation it owns)
  SELECT is_used INTO v_bool FROM tokens WHERE id = v_t1;
  IF v_bool IS NOT TRUE THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: 20 — spoil wrongly released an unrelated token %', v_log;
  END IF;
  v_log := v_log || E'\n  PASS 20 spoil_check_in_releases_only_paper_token';

  ------------------------------------------------------------------------------
  -- 21. spoil_check_in_returns_no_ballot_id
  ------------------------------------------------------------------------------
  v_txt := pg_get_function_result('public.spoil_paper_check_in(text,text,uuid)'::regprocedure);
  IF v_txt ILIKE '%ballot_id%' OR v_txt ILIKE '%candidate_id%' THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: 21.spoil_check_in_returns_no_ballot_id — result=% %', v_txt, v_log;
  END IF;
  v_log := v_log || E'\n  PASS 21 spoil_check_in_returns_no_ballot_id';

  ------------------------------------------------------------------------------
  -- 22. void_anonymous_blank_never_releases_token
  --   behavioural: void AVAILABLE blank B2; assert no token used-count change
  --   static: function body references no tokens table
  ------------------------------------------------------------------------------
  SELECT count(*) INTO v_used_before FROM tokens WHERE is_used = TRUE OR reservation_released_at IS NOT NULL;
  SELECT success, message INTO v_ok, v_msg FROM public.void_anonymous_paper_blank(v_b2, 'w6 test void', NULL);
  IF v_ok IS NOT TRUE THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: 22 — void failed: % %', v_msg, v_log;
  END IF;
  SELECT status INTO v_txt FROM anonymous_paper_blanks WHERE ballot_id = v_b2;
  IF v_txt <> 'VOIDED' THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: 22 — blank not VOIDED (status=%) %', v_txt, v_log;
  END IF;
  SELECT count(*) INTO v_used_after FROM tokens WHERE is_used = TRUE OR reservation_released_at IS NOT NULL;
  IF v_used_after <> v_used_before THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: 22.void_anonymous_blank_never_releases_token — token state changed (%->%) %',
      v_used_before, v_used_after, v_log;
  END IF;
  v_def := pg_get_functiondef('private.void_anonymous_paper_blank(text,text,uuid)'::regprocedure);
  IF v_def ILIKE '%tokens%' THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: 22 — void body references tokens table %', v_log;
  END IF;
  v_log := v_log || E'\n  PASS 22 void_anonymous_blank_never_releases_token';

  ------------------------------------------------------------------------------
  -- 23. deprecated_matched_pair_rpcs_fail_closed
  ------------------------------------------------------------------------------
  SELECT success, message INTO v_ok, v_msg FROM public.issue_preprinted_paper_ballot('x', v_m1, NULL);
  IF v_ok IS NOT FALSE OR v_msg NOT ILIKE '%superseded%' THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: 23 — issue_preprinted_paper_ballot not fail-closed (ok=%, msg=%) %', v_ok, v_msg, v_log;
  END IF;
  SELECT success, message INTO v_ok, v_msg FROM public.spoil_paper_ballot('x', 'r', NULL);
  IF v_ok IS NOT FALSE OR v_msg NOT ILIKE '%superseded%' THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: 23 — spoil_paper_ballot not fail-closed (ok=%, msg=%) %', v_ok, v_msg, v_log;
  END IF;
  SELECT success, message INTO v_ok, v_msg FROM public.submit_paper_invalid('x', 'r');
  IF v_ok IS NOT FALSE OR v_msg NOT ILIKE '%superseded%' THEN
    RAISE EXCEPTION 'W6_GUARD_FAIL: 23 — submit_paper_invalid not fail-closed (ok=%, msg=%) %', v_ok, v_msg, v_log;
  END IF;
  BEGIN
    PERFORM public.generate_blank_paper_ballot_batch(1, NULL);
    RAISE EXCEPTION 'W6_GUARD_FAIL: 23 — generate_blank_paper_ballot_batch did not fail closed %', v_log;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'W6_GUARD_FAIL%' THEN RAISE; END IF;
    IF SQLERRM NOT ILIKE '%superseded%' THEN
      RAISE EXCEPTION 'W6_GUARD_FAIL: 23 — batch wrong error: % %', SQLERRM, v_log;
    END IF;
  END;
  v_log := v_log || E'\n  PASS 23 deprecated_matched_pair_rpcs_fail_closed';

  ------------------------------------------------------------------------------
  -- Terminal rollback sentinel (SUCCESS). Undoes all synthetic fixtures + writes.
  ------------------------------------------------------------------------------
  RAISE EXCEPTION E'ROLLBACK_OK: all 23 Wave6 paper-severance guards passed.%', v_log;
END;
$harness$;
