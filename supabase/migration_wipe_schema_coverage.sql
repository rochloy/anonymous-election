-- migration_wipe_schema_coverage.sql
--
-- Canonical run order item 50. F16 structural fix: the wipe's fail-closed
-- completeness assertion covered an enumerated list of public tables only.
-- The historical backup_wave6 schema (5 tables, 65 rows of co-located
-- member_id/ballot_id/candidate_id) survived a full wipe undetected exactly
-- this way: the assertion verified the enumerated tables as empty while the
-- rogue schema kept its data.
--
-- The check is now structural:
--   (a) any non-system schema other than public/private/governance aborts
--       the wipe outright (Supabase platform schemas are allowlisted;
--       pg_* filtered by pattern);
--   (b) the survivor allowlist (election_settings, the governance ledger)
--       must exist -- typos fail loudly;
--   (c) every other table / partitioned table / materialized view in the
--       application schemas must be empty, discovered dynamically -- new
--       tables are covered by default instead of having to be remembered.
--
-- The modified function body is extracted verbatim from the live hosted
-- schema; only the assertion block is replaced (verified by the fail-closed
-- post-conditions at the end of this file).
BEGIN;

CREATE OR REPLACE FUNCTION private.wipe_election_data(p_admin_id uuid, p_token_hash character varying) RETURNS TABLE(success boolean, message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'governance', 'extensions'
    AS $$
DECLARE
  v_phase election_phase;
  v_token_record RECORD;
BEGIN
  SELECT current_phase
    INTO v_phase
  FROM election_settings
  WHERE id = 1
  FOR UPDATE;

  IF NOT FOUND OR v_phase IS NULL THEN
    RAISE EXCEPTION 'Missing election settings row (id=1).';
  END IF;

  IF v_phase <> 'SETUP' THEN
    RAISE EXCEPTION 'Database wipe is only allowed during SETUP phase.';
  END IF;

  SELECT admin_session_id, confirmed_at, expires_at
    INTO v_token_record
  FROM wipe_confirmation_tokens
  WHERE admin_session_id = p_admin_id
    AND token_hash = p_token_hash
  FOR UPDATE;

  IF NOT FOUND OR v_token_record.confirmed_at IS NULL THEN
    RAISE EXCEPTION 'wipe not confirmed';
  END IF;

  IF v_token_record.expires_at <= clock_timestamp() THEN
    RAISE EXCEPTION 'wipe confirmation expired';
  END IF;

  PERFORM private.append_governance_event(
    'WIPE_STARTED', p_admin_id, 'admin', NULL, NULL,
    'Election data wipe for new-election setup', 'Legitimate interest',
    NULL, NULL, NULL,
    jsonb_build_object('scope', 'all election-scoped tables + members')
  );

  TRUNCATE candidates, tokens, anonymous_nominations, ballots, paper_ballots,
    paper_ballot_batches, vote_audit_log, eligibility_adjudications, phase_change_tokens,
    wipe_confirmation_tokens, admin_sessions, rate_limit_hits,
    anonymous_paper_blanks, anonymous_digital_credentials,
    digital_credential_reservations, nomination_adjudications,
    participation_audit, ballot_audit_log
    CASCADE;

  DELETE FROM members WHERE id IS NOT NULL;

  UPDATE election_settings SET current_phase = 'SETUP' WHERE id = 1;

  -- F16 structural fix (2026-10-08): dynamic completeness check over ALL
  -- application schemas (public, private, governance) instead of an
  -- enumerated public-table list, plus outright rejection of any unexpected
  -- non-system schema. A rogue schema (e.g. the historical backup_wave6,
  -- which survived a full wipe with co-located member/ballot/candidate
  -- rows) or a rogue table can no longer evade the check. Fail-closed: new
  -- tables and schemas are covered by default; only the explicit survivor
  -- allowlist below is exempt, and its entries must exist.
  DECLARE
    v_schema_bad TEXT;
    v_table_bad  TEXT;
    v_survivor   TEXT;
    v_row        RECORD;
    v_has_rows   BOOLEAN;
    v_survivors  TEXT[] := ARRAY[
      'public.election_settings',
      'governance.processing_activity_ledger'
    ];
  BEGIN
    -- (a) No unexpected non-system schema may exist at all.
    SELECT string_agg(nspname, ', ' ORDER BY nspname)
      INTO v_schema_bad
    FROM pg_namespace
    WHERE nspname NOT IN (
        'public', 'private', 'governance',
        'auth', 'storage', 'realtime', 'vault', 'extensions',
        'graphql', 'graphql_public', 'pgbouncer', 'supabase_migrations',
        'information_schema'
      )
      AND nspname NOT LIKE 'pg\_%';

    IF v_schema_bad IS NOT NULL THEN
      RAISE EXCEPTION
        'wipe completeness check failed: unexpected schema(s) present: %',
        v_schema_bad;
    END IF;

    -- (b) Survivor allowlist entries must exist (typo protection).
    FOREACH v_survivor IN ARRAY v_survivors LOOP
      IF to_regclass(v_survivor) IS NULL THEN
        RAISE EXCEPTION
          'wipe completeness check failed: survivor allowlist entry % does not exist',
          v_survivor;
      END IF;
    END LOOP;

    -- (c) Every other table / partitioned table / materialized view in the
    --     application schemas must be empty.
    FOR v_row IN
      SELECT n.nspname AS sch, c.relname AS tbl
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE c.relkind IN ('r', 'p', 'm')
        AND n.nspname IN ('public', 'private', 'governance')
        AND (n.nspname || '.' || c.relname) <> ALL (v_survivors)
      ORDER BY n.nspname, c.relname
    LOOP
      EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.%I)', v_row.sch, v_row.tbl)
        INTO v_has_rows;
      IF v_has_rows THEN
        v_table_bad := coalesce(v_table_bad || ', ', '') || v_row.sch || '.' || v_row.tbl;
      END IF;
    END LOOP;

    IF v_table_bad IS NOT NULL THEN
      RAISE EXCEPTION
        'wipe completeness check failed: non-empty table(s) after wipe: %',
        v_table_bad;
    END IF;
  END;

  PERFORM private.append_governance_event(
    'WIPE_COMPLETED', p_admin_id, 'admin', NULL, NULL,
    'Election data wipe for new-election setup', 'Legitimate interest',
    NULL, NULL, NULL,
    jsonb_build_object('scope', 'all election-scoped tables + members', 'result', 'clean SETUP state')
  );

  RETURN QUERY SELECT TRUE, 'Election data wiped. Database is ready for a new election (SETUP phase). All admin sessions were revoked.'::TEXT;
END;
$$;


-- ---------------------------------------------------------------------------
-- Re-assert the ACL posture (matches the live ACL exactly).
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION private.wipe_election_data(p_admin_id uuid, p_token_hash character varying) FROM PUBLIC;
GRANT ALL ON FUNCTION private.wipe_election_data(p_admin_id uuid, p_token_hash character varying) TO service_role;
REVOKE ALL ON FUNCTION public.wipe_election_data(p_admin_id uuid, p_token_hash character varying) FROM PUBLIC;
GRANT ALL ON FUNCTION public.wipe_election_data(p_admin_id uuid, p_token_hash character varying) TO service_role;

-- ---------------------------------------------------------------------------
-- Fail-closed post-conditions. Any violation aborts the transaction.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_def TEXT;
BEGIN
  v_def := pg_get_functiondef('private.wipe_election_data(uuid,character varying)'::regprocedure);

  IF position('unexpected schema(s) present' IN v_def) = 0 THEN
    RAISE EXCEPTION 'ABORT: the unexpected-schema rejection is missing from the wipe check.';
  END IF;
  IF position('non-empty table(s) after wipe' IN v_def) = 0 THEN
    RAISE EXCEPTION 'ABORT: the dynamic table-emptiness check is missing from the wipe check.';
  END IF;
  IF position('''public.election_settings''' IN v_def) = 0
     OR position('''governance.processing_activity_ledger''' IN v_def) = 0 THEN
    RAISE EXCEPTION 'ABORT: the survivor allowlist is incomplete.';
  END IF;
  IF v_def LIKE '%OR EXISTS (SELECT 1 FROM candidates)%' THEN
    RAISE EXCEPTION 'ABORT: the old enumerated assertion is still present.';
  END IF;

  IF NOT has_function_privilege('service_role', 'private.wipe_election_data(uuid,character varying)', 'EXECUTE') THEN
    RAISE EXCEPTION 'ABORT: service_role lost EXECUTE on the private wipe RPC.';
  END IF;
  IF has_function_privilege('anon', 'private.wipe_election_data(uuid,character varying)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'private.wipe_election_data(uuid,character varying)', 'EXECUTE') THEN
    RAISE EXCEPTION 'ABORT: anon/authenticated must not hold EXECUTE on the private wipe RPC.';
  END IF;
  IF NOT has_function_privilege('service_role', 'public.wipe_election_data(uuid,character varying)', 'EXECUTE') THEN
    RAISE EXCEPTION 'ABORT: service_role lost EXECUTE on the public wipe wrapper.';
  END IF;
  IF has_function_privilege('anon', 'public.wipe_election_data(uuid,character varying)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.wipe_election_data(uuid,character varying)', 'EXECUTE') THEN
    RAISE EXCEPTION 'ABORT: anon/authenticated must not hold EXECUTE on the public wipe wrapper.';
  END IF;
  IF position('private.wipe_election_data' IN
       pg_get_functiondef('public.wipe_election_data(uuid,character varying)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'ABORT: the public wrapper no longer delegates to the private RPC.';
  END IF;

  RAISE NOTICE 'OK: wipe completeness check is schema-structural; ACL posture intact.';
END
$$;

COMMIT;
