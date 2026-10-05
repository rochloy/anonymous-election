-- ============================================================================
-- VERIFY SCRIPT: nomination adjudication hardening (post-item-44)
-- Not part of canonical run order. Run manually in SQL Editor.
-- Rollback-only: synthetic fixture IDs only, no real PII.
-- Fails loudly with EXCEPTION when any assertion is unmet.
-- ============================================================================

BEGIN;

DO $$
DECLARE
  v_admin_id UUID := gen_random_uuid();
  v_member_id UUID := gen_random_uuid();
  v_candidate_id UUID := gen_random_uuid();

  v_n_discard_1 UUID := gen_random_uuid();
  v_n_discard_2 UUID := gen_random_uuid();
  v_n_merge UUID := gen_random_uuid();
  v_n_promote UUID := gen_random_uuid();
  v_n_dup_a UUID := gen_random_uuid();
  v_n_dup_b UUID := gen_random_uuid();
  v_unknown UUID := gen_random_uuid();

  v_ok BOOLEAN;
  v_msg TEXT;
  v_out_candidate UUID;

  v_count INT;
  v_cursor_date DATE := NULL;
  v_cursor_id UUID := NULL;
  v_page_count INT := 0;
  v_last_date DATE;
  v_last_id UUID;
BEGIN
  -- Synthetic fixture scope
  INSERT INTO admin_sessions(id, token_hash, expires_at, user_agent, ip_address)
  VALUES (v_admin_id, repeat('a', 64), now() + interval '1 hour', 'verify-item-44', '127.0.0.1'::inet);

  INSERT INTO members(id, member_code, full_name, email, phone, is_active)
  VALUES (v_member_id, 'VERIFY-ITEM44-MEMBER', 'Verify Item44 Member', NULL, NULL, TRUE);

  INSERT INTO candidates(id, full_name, statement, is_active)
  VALUES (v_candidate_id, 'Verify Existing Candidate', NULL, TRUE);

  INSERT INTO anonymous_nominations(id, nominee_member_id, nominee_name, reason, source)
  VALUES
    (v_n_discard_1, NULL, 'Verify Discard 1', 'fixture', 'ADMIN'),
    (v_n_discard_2, NULL, 'Verify Discard 2', 'fixture', 'ADMIN'),
    (v_n_merge, NULL, 'Verify Merge', 'fixture', 'ADMIN'),
    (v_n_promote, NULL, 'Verify Promote', 'fixture', 'ADMIN'),
    (v_n_dup_a, NULL, 'Verify Dup A', 'fixture', 'ADMIN'),
    (v_n_dup_b, NULL, 'Verify Dup B', 'fixture', 'ADMIN');

  UPDATE election_settings SET current_phase = 'NOMINATION_CLOSED' WHERE id = 1;

  -- 1) First decision on one scoped nomination succeeds (private)
  SELECT success, message, candidate_id
    INTO v_ok, v_msg, v_out_candidate
  FROM private.adjudicate_nomination(
    'DISCARD', v_admin_id, ARRAY[v_n_discard_1], NULL, NULL, NULL, NULL, 'verify-item44-first'
  )
  LIMIT 1;

  IF COALESCE(v_ok, FALSE) IS NOT TRUE THEN
    RAISE EXCEPTION 'Expected first private DISCARD success=true, got success=% message=%', v_ok, v_msg;
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM nomination_adjudications
  WHERE note = 'verify-item44-first';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Expected exactly 1 adjudication row for first decision, got %', v_count;
  END IF;

  -- 2) Repeat decision on same nomination rejects (private)
  SELECT success, message, candidate_id
    INTO v_ok, v_msg, v_out_candidate
  FROM private.adjudicate_nomination(
    'DISCARD', v_admin_id, ARRAY[v_n_discard_1], NULL, NULL, NULL, NULL, 'verify-item44-repeat'
  )
  LIMIT 1;

  IF COALESCE(v_ok, TRUE) IS NOT FALSE THEN
    RAISE EXCEPTION 'Expected repeat private DISCARD success=false, got success=% message=%', v_ok, v_msg;
  END IF;

  -- 3) Mixed decided + undecided input rejects (private)
  SELECT success, message, candidate_id
    INTO v_ok, v_msg, v_out_candidate
  FROM private.adjudicate_nomination(
    'DISCARD', v_admin_id, ARRAY[v_n_discard_1, v_n_discard_2], NULL, NULL, NULL, NULL, 'verify-item44-mixed'
  )
  LIMIT 1;

  IF COALESCE(v_ok, TRUE) IS NOT FALSE THEN
    RAISE EXCEPTION 'Expected mixed private DISCARD success=false, got success=% message=%', v_ok, v_msg;
  END IF;

  -- 4) Nonexistent nomination ID rejects (private)
  SELECT success, message, candidate_id
    INTO v_ok, v_msg, v_out_candidate
  FROM private.adjudicate_nomination(
    'DISCARD', v_admin_id, ARRAY[v_unknown], NULL, NULL, NULL, NULL, 'verify-item44-missing'
  )
  LIMIT 1;

  IF COALESCE(v_ok, TRUE) IS NOT FALSE THEN
    RAISE EXCEPTION 'Expected nonexistent private DISCARD success=false, got success=% message=%', v_ok, v_msg;
  END IF;

  -- 5) Null and duplicate UUID guards reject (private)
  SELECT success, message, candidate_id
    INTO v_ok, v_msg, v_out_candidate
  FROM private.adjudicate_nomination(
    'DISCARD', v_admin_id, ARRAY[v_n_discard_2, NULL::uuid], NULL, NULL, NULL, NULL, 'verify-item44-null'
  )
  LIMIT 1;
  IF COALESCE(v_ok, TRUE) IS NOT FALSE THEN
    RAISE EXCEPTION 'Expected null-id private DISCARD rejection, got success=% message=%', v_ok, v_msg;
  END IF;

  SELECT success, message, candidate_id
    INTO v_ok, v_msg, v_out_candidate
  FROM private.adjudicate_nomination(
    'DISCARD', v_admin_id, ARRAY[v_n_dup_a, v_n_dup_a], NULL, NULL, NULL, NULL, 'verify-item44-dup'
  )
  LIMIT 1;
  IF COALESCE(v_ok, TRUE) IS NOT FALSE THEN
    RAISE EXCEPTION 'Expected duplicate-id private DISCARD rejection, got success=% message=%', v_ok, v_msg;
  END IF;

  -- 6) Public wrapper works for MERGE and PROMOTE
  SELECT success, message, candidate_id
    INTO v_ok, v_msg, v_out_candidate
  FROM public.adjudicate_nomination(
    'MERGE', v_admin_id, ARRAY[v_n_merge], NULL, NULL, NULL, v_candidate_id, 'verify-item44-merge'
  )
  LIMIT 1;
  IF COALESCE(v_ok, FALSE) IS NOT TRUE OR v_out_candidate IS DISTINCT FROM v_candidate_id THEN
    RAISE EXCEPTION 'Expected public MERGE success with candidate %, got success=% candidate=% message=%', v_candidate_id, v_ok, v_out_candidate, v_msg;
  END IF;

  SELECT success, message, candidate_id
    INTO v_ok, v_msg, v_out_candidate
  FROM public.adjudicate_nomination(
    'PROMOTE', v_admin_id, ARRAY[v_n_promote], v_member_id, NULL, 'verify promote statement', NULL, 'verify-item44-promote'
  )
  LIMIT 1;
  IF COALESCE(v_ok, FALSE) IS NOT TRUE OR v_out_candidate IS NULL THEN
    RAISE EXCEPTION 'Expected public PROMOTE success with new candidate, got success=% candidate=% message=%', v_ok, v_out_candidate, v_msg;
  END IF;

  -- 8) Known-bad historical duplicate adjudication rows also exclude pending
  INSERT INTO nomination_adjudications(admin_id, decision, candidate_id, nominee_member_id, affected_nomination_ids, note)
  VALUES
    (v_admin_id, 'DISCARD', NULL, NULL, ARRAY[v_n_dup_a], 'verify-item44-histdup-a'),
    (v_admin_id, 'DISCARD', NULL, NULL, ARRAY[v_n_dup_a], 'verify-item44-histdup-b');

  -- 7/8/9) Verify pending helper by paging all rows into a temp table (isolated).
  CREATE TEMP TABLE tmp_pending_seen (
    id UUID,
    nominee_name TEXT,
    reason TEXT,
    submitted_date DATE
  ) ON COMMIT DROP;

  LOOP
    WITH page AS (
      SELECT *
      FROM public.get_pending_unmatched_nominations(200, v_cursor_date, v_cursor_id)
      ORDER BY submitted_date DESC NULLS LAST, id ASC
    )
    INSERT INTO tmp_pending_seen(id, nominee_name, reason, submitted_date)
    SELECT id, nominee_name, reason, submitted_date
    FROM page;

    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_page_count := v_page_count + 1;

    IF v_count = 0 THEN
      EXIT;
    END IF;

    SELECT p.submitted_date, p.id
      INTO v_last_date, v_last_id
    FROM public.get_pending_unmatched_nominations(200, v_cursor_date, v_cursor_id) p
    ORDER BY p.submitted_date DESC NULLS LAST, p.id ASC
    LIMIT 1 OFFSET v_count - 1;

    IF v_last_id IS NULL THEN
      RAISE EXCEPTION 'Pending helper pagination cursor failed to advance';
    END IF;

    v_cursor_date := v_last_date;
    v_cursor_id := v_last_id;

    IF v_count < 200 THEN
      EXIT;
    END IF;

    IF v_page_count >= 100 THEN
      RAISE EXCEPTION 'Pending helper pagination exceeded verification cap';
    END IF;
  END LOOP;

  SELECT COUNT(*) INTO v_count
  FROM tmp_pending_seen
  WHERE id IN (v_n_discard_1, v_n_merge, v_n_promote);

  IF v_count <> 0 THEN
    RAISE EXCEPTION 'Expected pending helper to exclude adjudicated IDs, found % leaked rows', v_count;
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM tmp_pending_seen
  WHERE id = v_n_dup_a;

  IF v_count <> 0 THEN
    RAISE EXCEPTION 'Expected pending helper to exclude historically duplicated adjudicated ID, found % rows', v_count;
  END IF;

  -- 9) Pending helper includes untouched fixture nominations
  SELECT COUNT(*) INTO v_count
  FROM tmp_pending_seen
  WHERE id = v_n_dup_b;

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Expected untouched fixture nomination to remain pending exactly once, got %', v_count;
  END IF;
END;
$$;

ROLLBACK;
