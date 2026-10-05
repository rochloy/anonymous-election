-- ============================================================================
-- VERIFY SCRIPT: wipe email confirmation hardening (post-item-43)
-- NOT part of canonical run order. Read-only / rollback-only verification script
-- to run manually in Supabase SQL Editor after applying migration item 43.
-- ============================================================================

-- A) Function signatures + execute privileges
SELECT
  n.nspname AS schema_name,
  p.proname AS function_name,
  oidvectortypes(p.proargtypes) AS arg_types,
  has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_exec,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_exec,
  has_function_privilege('service_role', p.oid, 'EXECUTE') AS service_role_exec
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE p.proname = 'wipe_election_data'
  AND n.nspname IN ('public', 'private')
ORDER BY n.nspname, oidvectortypes(p.proargtypes);

-- Expect exactly two rows:
--   public.wipe_election_data(uuid, character varying)
--   private.wipe_election_data(uuid, character varying)
-- and privileges anon/authenticated = false, service_role = true.

-- B) Table RLS + anon/auth SELECT privilege checks
SELECT
  relrowsecurity,
  has_table_privilege('anon', 'public.wipe_confirmation_tokens', 'SELECT') AS anon_select,
  has_table_privilege('authenticated', 'public.wipe_confirmation_tokens', 'SELECT') AS authenticated_select
FROM pg_class
WHERE oid = 'public.wipe_confirmation_tokens'::regclass;

-- Expect: relrowsecurity = true, anon_select = false, authenticated_select = false.

-- C) No-token path rejection proof (must never wipe)
BEGIN;

DO $$
DECLARE
  v_rejected BOOLEAN := FALSE;
BEGIN
  BEGIN
    PERFORM * FROM private.wipe_election_data(gen_random_uuid(), repeat('0', 64));
  EXCEPTION
    WHEN OTHERS THEN
      v_rejected := TRUE;
      RAISE NOTICE 'PASS: rejected (%)', SQLERRM;
  END;
  -- Outside the handler, so it cannot be swallowed: if the wipe ran, this
  -- aborts the transaction and the ROLLBACK below discards everything.
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'FAIL: wipe ran without a confirmed token';
  END IF;
END;
$$;

-- Only reached if the probe above was rejected.
SELECT 'PASS: no-token wipe rejected' AS result,
       count(*) AS members_count_after_attempt
FROM public.members;

ROLLBACK;
