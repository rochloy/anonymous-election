-- test_db_security.sql
--
-- Standing read-only security-invariant suite for the anonymous-election DB.
-- Encodes the 2026-10-08 audit's verified end-state so regressions are caught
-- before they ship. Safe to run against the local disposable fixture AND the
-- hosted production database (catalog queries + read-only function probes;
-- no writes anywhere).
--
-- Every violation raises 'DB-SECURITY-FAIL Sxx: ...'. Run with ON_ERROR_STOP=0
-- (the runner, scripts/test-db-security.sh, does this) so ALL failures report
-- in one pass; the runner counts failures, rejects unexpected ERRORs (a
-- broken check must never read as a green), and verifies the SUITE-COMPLETE
-- sentinel so a truncated run cannot pass silently.
--
-- Proven RED: scripts/test-db-security.sh prove-red applies
-- test_db_security_sabotage.sql (six deliberate violations), shows the suite
-- fail, restores, and shows it pass again.
--
-- Invariants:
--   S01 anon/authenticated hold zero table privileges on public tables
--   S02 anon/authenticated hold no USAGE on schema private
--   S03 no PUBLIC-executable functions in schema private
--   S04 no postgres-owned default table/sequence grants to anon/authenticated
--   S05 anon executes exactly the four f4_* normal functions in public
--       (trigger/event-trigger functions and extension members are excluded:
--        the former are not RPC-callable, the latter are platform-owned)
--   S06 authenticated executes zero normal functions in public+private
--   S07 f4 posture: f4_public_reader-owned, anon EXECUTE, authenticated denied
--   S08 Option E: no hmac helpers exist, nothing references them
--   S09 ballot ID generator emits PAPER:<64hex> (70 chars, key-independent)
--   S10 identity-slip short_code uses CSPRNG and the documented shape
--   S11 f4_verify_ballot accepts VC-/PB- receipts, rejects bad prefixes
--   S12 wipe completeness assertion is schema-structural; ACLs service-only
--   S13 zero unexpected non-system schemas (the F16 universe check)
--   S14 every public table has RLS enabled

\echo '=== db-security suite: start ==='

\echo '--- S01: anon/authenticated table privileges (expect none) ---'
DO $$ DECLARE v_bad TEXT; BEGIN
SELECT string_agg(DISTINCT r.rolname || ':' || c.relname || ':' || p.priv, ', ') INTO v_bad
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
CROSS JOIN (SELECT unnest(ARRAY['anon','authenticated']) rolname) r
CROSS JOIN (SELECT unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER','MAINTAIN']) priv) p
WHERE n.nspname='public' AND c.relkind='r' AND has_table_privilege(r.rolname, c.oid, p.priv);
IF v_bad IS NOT NULL THEN
  RAISE EXCEPTION 'DB-SECURITY-FAIL S01: anon/authenticated hold table privileges: %', v_bad;
END IF;
END $$;

\echo '--- S02: schema private USAGE (expect none) ---'
DO $$ BEGIN
IF has_schema_privilege('anon','private','USAGE')
   OR has_schema_privilege('authenticated','private','USAGE') THEN
  RAISE EXCEPTION 'DB-SECURITY-FAIL S02: anon/authenticated hold USAGE on schema private';
END IF;
END $$;

\echo '--- S03: PUBLIC-executable private functions (expect none) ---'
DO $$ DECLARE v_bad TEXT; BEGIN
SELECT string_agg(p.proname, ', ') INTO v_bad
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='private'
  AND (p.proacl IS NULL
       OR EXISTS (SELECT 1 FROM unnest(p.proacl) AS a(item) WHERE a.item::text LIKE '=%'));
IF v_bad IS NOT NULL THEN
  RAISE EXCEPTION 'DB-SECURITY-FAIL S03: PUBLIC-executable private functions: %', v_bad;
END IF;
END $$;

\echo '--- S04: default privileges referencing anon/authenticated (expect none) ---'
DO $$ DECLARE v_bad TEXT; BEGIN
SELECT string_agg(pg_get_userbyid(d.defaclrole) || ' [' || d.defaclobjtype::text || '] -> '
                    || d.defaclacl::text, '; ') INTO v_bad
FROM pg_default_acl d
JOIN pg_namespace n ON n.oid = d.defaclnamespace
WHERE n.nspname='public'
  AND d.defaclobjtype IN ('r','S')
  AND pg_get_userbyid(d.defaclrole)='postgres'
  AND d.defaclacl::text ~ '(anon|authenticated)=';
IF v_bad IS NOT NULL THEN
  RAISE EXCEPTION 'DB-SECURITY-FAIL S04: default privileges still grant to anon/authenticated: %', v_bad;
END IF;
END $$;

\echo '--- S05: anon executable set in public (expect exactly the 4 f4_*) ---'
DO $$ DECLARE v_bad TEXT; v_n INT; BEGIN
SELECT string_agg(p.proname, ',' ORDER BY p.proname), count(*) INTO v_bad, v_n
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public'
  AND has_function_privilege('anon', p.oid, 'EXECUTE')
  AND p.prorettype NOT IN ('trigger'::regtype, 'event_trigger'::regtype)
  AND NOT EXISTS (SELECT 1 FROM pg_depend d
                  WHERE d.classid='pg_proc'::regclass AND d.objid=p.oid AND d.deptype='e');
IF v_n IS DISTINCT FROM 4
   OR v_bad IS DISTINCT FROM 'f4_candidates,f4_election_status,f4_results,f4_verify_ballot' THEN
  RAISE EXCEPTION 'DB-SECURITY-FAIL S05: anon executable set unexpected (n=%): %', coalesce(v_n,0), v_bad;
END IF;
END $$;

\echo '--- S06: authenticated normal-function execution (expect none) ---'
DO $$ DECLARE v_bad TEXT; BEGIN
SELECT string_agg(n.nspname||'.'||p.proname, ', ') INTO v_bad
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname IN ('public','private')
  AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
  AND p.prorettype NOT IN ('trigger'::regtype, 'event_trigger'::regtype)
  AND NOT EXISTS (SELECT 1 FROM pg_depend d
                  WHERE d.classid='pg_proc'::regclass AND d.objid=p.oid AND d.deptype='e');
IF v_bad IS NOT NULL THEN
  RAISE EXCEPTION 'DB-SECURITY-FAIL S06: authenticated executes normal functions: %', v_bad;
END IF;
END $$;

\echo '--- S07: f4 ownership + ACL posture ---'
DO $$ DECLARE v_bad TEXT; v_n INT; BEGIN
SELECT string_agg(p.proname, ', ') INTO v_bad
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public'
  AND p.proname IN ('f4_candidates','f4_election_status','f4_results','f4_verify_ballot')
  AND (pg_get_userbyid(p.proowner) <> 'f4_public_reader'
       OR NOT has_function_privilege('anon', p.oid, 'EXECUTE')
       OR has_function_privilege('authenticated', p.oid, 'EXECUTE'));
SELECT count(*) INTO v_n
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public'
  AND p.proname IN ('f4_candidates','f4_election_status','f4_results','f4_verify_ballot');
IF v_n <> 4 THEN
  v_bad := coalesce(v_bad || ', ', '') || 'expected 4 f4 functions, found ' || v_n;
END IF;
IF v_bad IS NOT NULL THEN
  RAISE EXCEPTION 'DB-SECURITY-FAIL S07: f4 posture broken: %', v_bad;
END IF;
END $$;

\echo '--- S08: Option E (no HMAC layer anywhere) ---'
DO $$ DECLARE v_bad TEXT; BEGIN
IF to_regprocedure('private.hmac_sign(text)') IS NOT NULL
   OR to_regprocedure('private.hmac_verify(text)') IS NOT NULL THEN
  RAISE EXCEPTION 'DB-SECURITY-FAIL S08: hmac helper functions exist';
END IF;
SELECT string_agg(n.nspname||'.'||p.proname, ', ') INTO v_bad
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname IN ('public','private') AND p.prokind IN ('f','p')
  AND pg_get_functiondef(p.oid) ~ 'private\.hmac_(sign|verify)';
IF v_bad IS NOT NULL THEN
  RAISE EXCEPTION 'DB-SECURITY-FAIL S08: functions still reference hmac helpers: %', v_bad;
END IF;
END $$;

\echo '--- S09: ballot ID generator shape ---'
DO $$ DECLARE v_id TEXT; BEGIN
v_id := private.generate_opaque_paper_ballot_id();
IF v_id IS NULL OR v_id !~ '^PAPER:[0-9a-f]{64}$' OR length(v_id) <> 70 THEN
  RAISE EXCEPTION 'DB-SECURITY-FAIL S09: ballot ID generator emitted an unexpected shape';
END IF;
END $$;

\echo '--- S10: short_code CSPRNG + shape ---'
DO $$ DECLARE v_def TEXT; v_code TEXT; BEGIN
v_def := pg_get_functiondef('private.generate_short_code()'::regprocedure);
IF v_def NOT LIKE '%gen_random_bytes%' OR v_def LIKE '%random(%' THEN
  RAISE EXCEPTION 'DB-SECURITY-FAIL S10: generate_short_code is not CSPRNG-backed';
END IF;
v_code := private.generate_short_code();
IF v_code IS NULL OR v_code !~ '^[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{3}[0-9A-Z]$' THEN
  RAISE EXCEPTION 'DB-SECURITY-FAIL S10: short_code shape broken: %', v_code;
END IF;
END $$;

\echo '--- S11: f4_verify_ballot receipt handling ---'
DO $$ DECLARE v_def TEXT; BEGIN
v_def := pg_get_functiondef('public.f4_verify_ballot(text,text)'::regprocedure);
IF position('''^(VC|PB)-[0-9A-F]{10}$''' IN v_def) = 0 THEN
  RAISE EXCEPTION 'DB-SECURITY-FAIL S11: f4_verify_ballot lost PB- receipt acceptance';
END IF;
IF public.f4_verify_ballot(NULL, 'XX-0000000000')::jsonb <> '{"found": false}'::jsonb THEN
  RAISE EXCEPTION 'DB-SECURITY-FAIL S11: bad-prefix receipt not rejected';
END IF;
IF public.f4_verify_ballot(NULL, 'PB-0000000000')::jsonb <> '{"found": false}'::jsonb THEN
  RAISE EXCEPTION 'DB-SECURITY-FAIL S11: unknown PB- receipt lookup misbehaves';
END IF;
IF public.f4_verify_ballot(NULL, 'VC-0000000000')::jsonb <> '{"found": false}'::jsonb THEN
  RAISE EXCEPTION 'DB-SECURITY-FAIL S11: unknown VC- receipt lookup misbehaves';
END IF;
END $$;

\echo '--- S12: wipe assertion structural + ACL posture ---'
DO $$ DECLARE v_def TEXT; BEGIN
v_def := pg_get_functiondef('private.wipe_election_data(uuid,character varying)'::regprocedure);
IF position('unexpected schema(s) present' IN v_def) = 0
   OR position('non-empty table(s) after wipe' IN v_def) = 0 THEN
  RAISE EXCEPTION 'DB-SECURITY-FAIL S12: wipe completeness assertion is not schema-structural';
END IF;
IF v_def LIKE '%OR EXISTS (SELECT 1 FROM candidates)%' THEN
  RAISE EXCEPTION 'DB-SECURITY-FAIL S12: old enumerated wipe assertion is present';
END IF;
IF NOT has_function_privilege('service_role','private.wipe_election_data(uuid,character varying)','EXECUTE')
   OR has_function_privilege('anon','private.wipe_election_data(uuid,character varying)','EXECUTE')
   OR has_function_privilege('authenticated','private.wipe_election_data(uuid,character varying)','EXECUTE')
   OR NOT has_function_privilege('service_role','public.wipe_election_data(uuid,character varying)','EXECUTE')
   OR has_function_privilege('anon','public.wipe_election_data(uuid,character varying)','EXECUTE')
   OR has_function_privilege('authenticated','public.wipe_election_data(uuid,character varying)','EXECUTE') THEN
  RAISE EXCEPTION 'DB-SECURITY-FAIL S12: wipe RPC ACL posture is broken';
END IF;
END $$;

\echo '--- S13: unexpected non-system schemas (expect none) ---'
DO $$ DECLARE v_bad TEXT; BEGIN
SELECT string_agg(nspname, ', ' ORDER BY nspname) INTO v_bad
FROM pg_namespace
WHERE nspname NOT IN ('public','private','governance',
                      'auth','storage','realtime','vault','extensions',
                      'graphql','graphql_public','pgbouncer','supabase_migrations',
                      'information_schema')
  AND nspname NOT LIKE 'pg\_%';
IF v_bad IS NOT NULL THEN
  RAISE EXCEPTION 'DB-SECURITY-FAIL S13: unexpected schema(s) present: %', v_bad;
END IF;
END $$;

\echo '--- S14: RLS enabled on every public table ---'
DO $$ DECLARE v_bad TEXT; BEGIN
SELECT string_agg(tablename, ', ') INTO v_bad
FROM pg_tables WHERE schemaname='public' AND rowsecurity=false;
IF v_bad IS NOT NULL THEN
  RAISE EXCEPTION 'DB-SECURITY-FAIL S14: public tables without RLS: %', v_bad;
END IF;
END $$;

\echo '=== db-security suite: all checks executed ==='
SELECT 'SUITE-COMPLETE' AS marker;
