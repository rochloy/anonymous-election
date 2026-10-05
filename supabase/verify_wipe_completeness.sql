-- ============================================================================
-- VERIFY SCRIPT: wipe completeness migration shape (post-item-45)
-- NOT part of canonical run order. READ-ONLY verifier only.
--
-- This script does NOT invoke wipe_election_data and does NOT mutate data.
-- Rationale: a rollback-wrapped wipe invocation is still unsafe on live DBs.
--
-- For destructive/isolated behavior checks, use a separate disposable-DB harness
-- outside this repository's default verifier path.
-- ============================================================================

-- A) private/public signatures and ACL posture (fail-loud)
DO $$
DECLARE
  v_sig_count INT;
  v_acl_bad_count INT;
  v_legacy_count INT;
BEGIN
  SELECT COUNT(*)
    INTO v_sig_count
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE p.proname = 'wipe_election_data'
    AND n.nspname IN ('public', 'private')
    AND oidvectortypes(p.proargtypes) = 'uuid, character varying';

  IF v_sig_count <> 2 THEN
    RAISE EXCEPTION 'Expected exactly 2 wipe_election_data(uuid, character varying) signatures across public/private, got %', v_sig_count;
  END IF;

  SELECT COUNT(*)
    INTO v_acl_bad_count
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE p.proname = 'wipe_election_data'
    AND n.nspname IN ('public', 'private')
    AND oidvectortypes(p.proargtypes) = 'uuid, character varying'
    AND (
      has_function_privilege('service_role', p.oid, 'EXECUTE') IS NOT TRUE
      OR has_function_privilege('anon', p.oid, 'EXECUTE') IS TRUE
      OR has_function_privilege('authenticated', p.oid, 'EXECUTE') IS TRUE
    );

  IF v_acl_bad_count <> 0 THEN
    RAISE EXCEPTION 'ACL check failed on wipe_election_data(uuid, character varying): expected service_role=true, anon=false, authenticated=false';
  END IF;

  SELECT COUNT(*)
    INTO v_legacy_count
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE p.proname = 'wipe_election_data'
    AND n.nspname IN ('public', 'private')
    AND oidvectortypes(p.proargtypes) <> 'uuid, character varying';

  IF v_legacy_count <> 0 THEN
    RAISE EXCEPTION 'Legacy/extra wipe_election_data overloads found: %', v_legacy_count;
  END IF;
END;
$$;

-- B) Function body shape checks with fail-loud assertions
DO $$
DECLARE
  fn TEXT;
BEGIN
  SELECT pg_get_functiondef(p.oid)
    INTO fn
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'private'
    AND p.proname = 'wipe_election_data'
    AND oidvectortypes(p.proargtypes) = 'uuid, character varying';

  IF fn IS NULL THEN
    RAISE EXCEPTION 'Missing private.wipe_election_data(uuid, character varying)';
  END IF;

  IF fn NOT LIKE '%IF NOT FOUND OR v_phase IS NULL THEN%' THEN
    RAISE EXCEPTION 'Missing fail-closed settings-row guard (IF NOT FOUND OR v_phase IS NULL)';
  END IF;
  IF fn NOT LIKE '%FROM wipe_confirmation_tokens%FOR UPDATE%' THEN
    RAISE EXCEPTION 'Missing wipe_confirmation_tokens row lock FOR UPDATE';
  END IF;
  IF fn NOT LIKE '%v_token_record.expires_at <= clock_timestamp()%' THEN
    RAISE EXCEPTION 'Missing post-lock wall-clock expiry guard (clock_timestamp)';
  END IF;
  IF fn NOT LIKE '%TRUNCATE%anonymous_paper_blanks%' THEN
    RAISE EXCEPTION 'Missing anonymous_paper_blanks in truncate scope';
  END IF;
  IF fn NOT LIKE '%anonymous_digital_credentials%' THEN
    RAISE EXCEPTION 'Missing anonymous_digital_credentials in truncate scope';
  END IF;
  IF fn NOT LIKE '%digital_credential_reservations%' THEN
    RAISE EXCEPTION 'Missing digital_credential_reservations in truncate scope';
  END IF;
  IF fn NOT LIKE '%nomination_adjudications%' THEN
    RAISE EXCEPTION 'Missing nomination_adjudications in truncate/assert scope';
  END IF;
  IF fn NOT LIKE '%participation_audit%' THEN
    RAISE EXCEPTION 'Missing participation_audit in truncate/assert scope';
  END IF;
  IF fn NOT LIKE '%ballot_audit_log%' THEN
    RAISE EXCEPTION 'Missing ballot_audit_log in truncate/assert scope';
  END IF;
  IF fn NOT LIKE '%wipe completeness check failed%' THEN
    RAISE EXCEPTION 'Missing fail-closed post-wipe assertion';
  END IF;
  IF fn NOT LIKE '%DELETE FROM members WHERE id IS NOT NULL%' THEN
    RAISE EXCEPTION 'Missing safeupdate-compatible members delete';
  END IF;
  IF fn NOT LIKE '%append_governance_event(%WIPE_STARTED%' THEN
    RAISE EXCEPTION 'Missing WIPE_STARTED governance event';
  END IF;
  IF fn NOT LIKE '%append_governance_event(%WIPE_COMPLETED%' THEN
    RAISE EXCEPTION 'Missing WIPE_COMPLETED governance event';
  END IF;
END;
$$;
