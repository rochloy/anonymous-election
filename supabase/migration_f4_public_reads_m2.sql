BEGIN;

-- M2: remove superseded PUBLIC SELECT policies after F4 RPC cutover.
-- First-run only. Atomic. No role/grant/function/data mutations.

DO $$
DECLARE
  v_policy RECORD;
  v_expr text;
  v_allowlisted boolean;
  v_col RECORD;
  v_allowlist_count integer := 0;
  v_effective_select boolean;
  v_overload_count integer;
  v_owner name;
  v_fn oid;
  v_fn_name text;
  v_fn_cfg text[];
  v_fn_ret text;
  v_fn_is_secdef boolean;
  v_role RECORD;
BEGIN
  -- -------------------------------------------------------------------------
  -- Preflight: old/public + new/reader policy posture before drop.
  -- -------------------------------------------------------------------------
  FOR v_policy IN
    SELECT *
    FROM (VALUES
      ('election_settings'::name, 'Public can view settings'::name),
      ('candidates'::name, 'Public can view candidates'::name),
      ('ballots'::name, 'Public can view receipt codes'::name)
    ) AS p(tablename, policyname)
  LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM pg_policies pol
      WHERE pol.schemaname = 'public'
        AND pol.tablename = v_policy.tablename
        AND pol.policyname = v_policy.policyname
        AND pol.permissive = 'PERMISSIVE'
        AND pol.cmd = 'SELECT'
        AND pol.roles = ARRAY['public'::name]
    ) THEN
      RAISE EXCEPTION 'precondition failed: missing/invalid PUBLIC SELECT policy %.%', v_policy.tablename, v_policy.policyname;
    END IF;
  END LOOP;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies p
    WHERE p.schemaname = 'public'
      AND p.tablename = 'election_settings'
      AND p.policyname = 'f4_public_reader_settings_id1'
      AND p.permissive = 'PERMISSIVE'
      AND p.cmd = 'SELECT'
      AND p.roles = ARRAY['f4_public_reader'::name]
  ) THEN
    RAISE EXCEPTION 'precondition failed: missing/invalid reader policy f4_public_reader_settings_id1';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies p
    WHERE p.schemaname = 'public'
      AND p.tablename = 'candidates'
      AND p.policyname = 'f4_public_reader_active_candidates'
      AND p.permissive = 'PERMISSIVE'
      AND p.cmd = 'SELECT'
      AND p.roles = ARRAY['f4_public_reader'::name]
  ) THEN
    RAISE EXCEPTION 'precondition failed: missing/invalid reader policy f4_public_reader_active_candidates';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies p
    WHERE p.schemaname = 'public'
      AND p.tablename = 'ballots'
      AND p.policyname = 'f4_public_reader_ballots_verify'
      AND p.permissive = 'PERMISSIVE'
      AND p.cmd = 'SELECT'
      AND p.roles = ARRAY['f4_public_reader'::name]
  ) THEN
    RAISE EXCEPTION 'precondition failed: missing/invalid reader policy f4_public_reader_ballots_verify';
  END IF;

  SELECT pg_get_expr(p.polqual, p.polrelid)
    INTO v_expr
  FROM pg_policy p
  JOIN pg_class c ON c.oid = p.polrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relname = 'election_settings'
    AND p.polname = 'f4_public_reader_settings_id1';
  IF v_expr IS DISTINCT FROM '(id = 1)' THEN
    RAISE EXCEPTION 'precondition failed: unexpected USING for f4_public_reader_settings_id1: %', v_expr;
  END IF;

  SELECT pg_get_expr(p.polqual, p.polrelid)
    INTO v_expr
  FROM pg_policy p
  JOIN pg_class c ON c.oid = p.polrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relname = 'candidates'
    AND p.polname = 'f4_public_reader_active_candidates';
  IF v_expr IS DISTINCT FROM '(is_active = true)' THEN
    RAISE EXCEPTION 'precondition failed: unexpected USING for f4_public_reader_active_candidates: %', v_expr;
  END IF;

  SELECT pg_get_expr(p.polqual, p.polrelid)
    INTO v_expr
  FROM pg_policy p
  JOIN pg_class c ON c.oid = p.polrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relname = 'ballots'
    AND p.polname = 'f4_public_reader_ballots_verify';
  IF v_expr IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'precondition failed: unexpected USING for f4_public_reader_ballots_verify: %', v_expr;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_policies p
    WHERE p.schemaname = 'public'
      AND p.tablename IN ('election_settings', 'candidates', 'ballots')
      AND p.cmd = 'SELECT'
      AND p.policyname NOT IN (
        'Public can view settings',
        'Public can view candidates',
        'Public can view receipt codes',
        'f4_public_reader_settings_id1',
        'f4_public_reader_active_candidates',
        'f4_public_reader_ballots_verify'
      )
  ) THEN
    RAISE EXCEPTION 'precondition failed: unexpected SELECT policy detected on F4 source tables';
  END IF;

  IF (
    SELECT count(*)
    FROM pg_policies p
    WHERE p.schemaname = 'public'
      AND p.tablename IN ('election_settings', 'candidates', 'ballots')
      AND p.cmd = 'SELECT'
  ) <> 6 THEN
    RAISE EXCEPTION 'precondition failed: expected exactly 6 SELECT policies across source tables before cleanup';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname IN ('election_settings', 'candidates', 'ballots')
      AND c.relkind IN ('r', 'p')
      AND NOT c.relrowsecurity
  ) THEN
    RAISE EXCEPTION 'precondition failed: RLS must be enabled on all source tables';
  END IF;

  IF has_table_privilege('anon', 'public.ballots', 'SELECT')
     OR has_table_privilege('anon', 'public.candidates', 'SELECT')
     OR has_table_privilege('anon', 'public.election_settings', 'SELECT') THEN
    RAISE EXCEPTION 'precondition failed: anon has forbidden direct table SELECT';
  END IF;

  IF has_table_privilege('authenticated', 'public.ballots', 'SELECT')
     OR has_table_privilege('authenticated', 'public.candidates', 'SELECT')
     OR has_table_privilege('authenticated', 'public.election_settings', 'SELECT') THEN
    RAISE EXCEPTION 'precondition failed: authenticated has forbidden direct table SELECT';
  END IF;

  IF has_any_column_privilege('anon', 'public.ballots', 'SELECT')
     OR has_any_column_privilege('anon', 'public.candidates', 'SELECT')
     OR has_any_column_privilege('anon', 'public.election_settings', 'SELECT') THEN
    RAISE EXCEPTION 'precondition failed: anon has forbidden direct column SELECT';
  END IF;

  IF has_any_column_privilege('authenticated', 'public.ballots', 'SELECT')
     OR has_any_column_privilege('authenticated', 'public.candidates', 'SELECT')
     OR has_any_column_privilege('authenticated', 'public.election_settings', 'SELECT') THEN
    RAISE EXCEPTION 'precondition failed: authenticated has forbidden direct column SELECT';
  END IF;

  SELECT rolname, rolcanlogin, rolsuper, rolbypassrls, rolinherit
    INTO v_role
  FROM pg_roles
  WHERE rolname = 'f4_public_reader';

  IF v_role.rolname IS NULL THEN
    RAISE EXCEPTION 'precondition failed: missing role f4_public_reader';
  END IF;
  IF v_role.rolcanlogin OR v_role.rolsuper OR v_role.rolbypassrls OR v_role.rolinherit THEN
    RAISE EXCEPTION 'precondition failed: f4_public_reader role attributes are too broad';
  END IF;

  IF NOT has_function_privilege('anon', 'public.f4_election_status()', 'EXECUTE')
     OR NOT has_function_privilege('anon', 'public.f4_candidates()', 'EXECUTE')
     OR NOT has_function_privilege('anon', 'public.f4_verify_ballot(text,text)', 'EXECUTE')
     OR NOT has_function_privilege('anon', 'public.f4_results(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'precondition failed: anon execute privilege missing for one or more F4 functions';
  END IF;

  IF has_function_privilege('authenticated', 'public.f4_election_status()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.f4_candidates()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.f4_verify_ballot(text,text)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.f4_results(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'precondition failed: authenticated retains execute on one or more F4 functions';
  END IF;
END
$$;

DROP POLICY "Public can view settings" ON public.election_settings;
DROP POLICY "Public can view candidates" ON public.candidates;
DROP POLICY "Public can view receipt codes" ON public.ballots;

-- ---------------------------------------------------------------------------
-- Postconditions (same critical invariant set as standalone verifier).
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_role RECORD;
  v_role_oid oid;
  v_owner name;
  v_col RECORD;
  v_table name;
  v_fn oid;
  v_fn_name text;
  v_fn_cfg text[];
  v_allowlisted boolean;
  v_effective_select boolean;
  v_allowlist_count integer := 0;
  v_overload_count integer;
  v_expr text;
  v_fn_ret text;
  v_fn_is_secdef boolean;
BEGIN
  IF to_regprocedure('public.f4_election_status()') IS NULL
     OR to_regprocedure('public.f4_candidates()') IS NULL
     OR to_regprocedure('public.f4_verify_ballot(text,text)') IS NULL
     OR to_regprocedure('public.f4_results(text)') IS NULL THEN
    RAISE EXCEPTION 'missing required F4 function signature(s)';
  END IF;

  SELECT count(*)
    INTO v_overload_count
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname IN ('f4_election_status', 'f4_candidates', 'f4_verify_ballot', 'f4_results');
  IF v_overload_count <> 4 THEN
    RAISE EXCEPTION 'unexpected F4 overload count: expected 4, got %', v_overload_count;
  END IF;

  SELECT rolname, rolcanlogin, rolsuper, rolbypassrls, rolinherit
    INTO v_role
  FROM pg_roles
  WHERE rolname = 'f4_public_reader';

  IF v_role.rolname IS NULL THEN
    RAISE EXCEPTION 'missing role f4_public_reader';
  END IF;
  IF v_role.rolcanlogin OR v_role.rolsuper OR v_role.rolbypassrls OR v_role.rolinherit THEN
    RAISE EXCEPTION 'f4_public_reader role attributes are too broad';
  END IF;

  SELECT oid INTO v_role_oid
  FROM pg_roles
  WHERE rolname = 'f4_public_reader';

  IF has_schema_privilege('f4_public_reader', 'public', 'CREATE') THEN
    RAISE EXCEPTION 'f4_public_reader retains CREATE on schema public';
  END IF;

  IF pg_has_role('postgres', 'f4_public_reader', 'SET') THEN
    RAISE EXCEPTION 'postgres still has SET ROLE privilege on f4_public_reader';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_auth_members m
    WHERE m.member = v_role_oid
      AND m.inherit_option
  ) THEN
    RAISE EXCEPTION 'f4_public_reader inherits memberships via pg_auth_members.inherit_option=true';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname IN ('election_settings', 'candidates', 'ballots')
      AND c.relkind IN ('r', 'p')
      AND c.relowner = v_role_oid
  ) THEN
    RAISE EXCEPTION 'f4_public_reader unexpectedly owns one or more source tables';
  END IF;

  SELECT r.rolname INTO v_owner
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  JOIN pg_roles r ON r.oid = p.proowner
  WHERE n.nspname = 'public'
    AND p.proname = 'f4_election_status'
    AND pg_get_function_identity_arguments(p.oid) = '';
  IF v_owner IS DISTINCT FROM 'f4_public_reader' THEN
    RAISE EXCEPTION 'unexpected owner for public.f4_election_status(): %', v_owner;
  END IF;

  SELECT r.rolname INTO v_owner
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  JOIN pg_roles r ON r.oid = p.proowner
  WHERE n.nspname = 'public'
    AND p.proname = 'f4_candidates'
    AND pg_get_function_identity_arguments(p.oid) = '';
  IF v_owner IS DISTINCT FROM 'f4_public_reader' THEN
    RAISE EXCEPTION 'unexpected owner for public.f4_candidates(): %', v_owner;
  END IF;

  SELECT r.rolname INTO v_owner
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  JOIN pg_roles r ON r.oid = p.proowner
  WHERE n.nspname = 'public'
    AND p.proname = 'f4_verify_ballot'
    AND pg_get_function_identity_arguments(p.oid) = 'p_ballot_id text, p_receipt_code text';
  IF v_owner IS DISTINCT FROM 'f4_public_reader' THEN
    RAISE EXCEPTION 'unexpected owner for public.f4_verify_ballot(text,text): %', v_owner;
  END IF;

  SELECT r.rolname INTO v_owner
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  JOIN pg_roles r ON r.oid = p.proowner
  WHERE n.nspname = 'public'
    AND p.proname = 'f4_results'
    AND pg_get_function_identity_arguments(p.oid) = 'p_receipt_code text';
  IF v_owner IS DISTINCT FROM 'f4_public_reader' THEN
    RAISE EXCEPTION 'unexpected owner for public.f4_results(text): %', v_owner;
  END IF;

  FOR v_fn IN
    SELECT unnest(ARRAY[
      to_regprocedure('public.f4_election_status()'),
      to_regprocedure('public.f4_candidates()'),
      to_regprocedure('public.f4_verify_ballot(text,text)'),
      to_regprocedure('public.f4_results(text)')
    ])
  LOOP
    SELECT p.proname, p.prosecdef, p.prorettype::regtype::text, p.proconfig
      INTO v_fn_name, v_fn_is_secdef, v_fn_ret, v_fn_cfg
    FROM pg_proc p
    WHERE p.oid = v_fn;

    IF NOT v_fn_is_secdef THEN
      RAISE EXCEPTION 'function % must be SECURITY DEFINER', v_fn_name;
    END IF;

    IF v_fn_ret IS DISTINCT FROM 'jsonb' THEN
      RAISE EXCEPTION 'function % must return jsonb, got %', v_fn_name, v_fn_ret;
    END IF;

    IF COALESCE(array_length(v_fn_cfg, 1), 0) <> 1
       OR v_fn_cfg[1] IS DISTINCT FROM 'search_path=""'
       OR EXISTS (
         SELECT 1
         FROM unnest(v_fn_cfg) AS cfg
         WHERE cfg <> 'search_path=""'
            OR cfg ILIKE '%temp%'
       ) THEN
      RAISE EXCEPTION 'function % must have exactly proconfig={search_path=""} and no extra/untrusted security config', v_fn_name;
    END IF;
  END LOOP;

  IF NOT has_function_privilege('anon', 'public.f4_election_status()', 'EXECUTE')
     OR NOT has_function_privilege('anon', 'public.f4_candidates()', 'EXECUTE')
     OR NOT has_function_privilege('anon', 'public.f4_verify_ballot(text,text)', 'EXECUTE')
     OR NOT has_function_privilege('anon', 'public.f4_results(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon execute privilege missing for one or more F4 functions';
  END IF;

  IF has_function_privilege('authenticated', 'public.f4_election_status()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.f4_candidates()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.f4_verify_ballot(text,text)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.f4_results(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated retains execute on one or more F4 functions';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_proc AS p
    JOIN pg_namespace AS n ON n.oid = p.pronamespace
    CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) AS acl
    WHERE n.nspname = 'public'
      AND p.oid IN (
        to_regprocedure('public.f4_election_status()'),
        to_regprocedure('public.f4_candidates()'),
        to_regprocedure('public.f4_verify_ballot(text,text)'),
        to_regprocedure('public.f4_results(text)')
      )
      AND acl.grantee = 0
      AND acl.privilege_type = 'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'PUBLIC retains execute on one or more F4 functions';
  END IF;

  IF has_table_privilege('f4_public_reader', 'public.election_settings', 'SELECT')
     OR has_table_privilege('f4_public_reader', 'public.candidates', 'SELECT')
     OR has_table_privilege('f4_public_reader', 'public.ballots', 'SELECT') THEN
    RAISE EXCEPTION 'f4_public_reader has forbidden table-wide SELECT';
  END IF;

  FOR v_table IN SELECT unnest(ARRAY['election_settings'::name, 'candidates'::name, 'ballots'::name])
  LOOP
    IF has_table_privilege('f4_public_reader', format('public.%I', v_table), 'INSERT')
       OR has_table_privilege('f4_public_reader', format('public.%I', v_table), 'UPDATE')
       OR has_table_privilege('f4_public_reader', format('public.%I', v_table), 'DELETE')
       OR has_table_privilege('f4_public_reader', format('public.%I', v_table), 'TRUNCATE')
       OR has_table_privilege('f4_public_reader', format('public.%I', v_table), 'REFERENCES')
       OR has_table_privilege('f4_public_reader', format('public.%I', v_table), 'TRIGGER') THEN
      RAISE EXCEPTION 'f4_public_reader has forbidden write-like table privilege(s) on %', v_table;
    END IF;

    IF has_any_column_privilege('f4_public_reader', format('public.%I', v_table), 'INSERT,UPDATE,REFERENCES') THEN
      RAISE EXCEPTION 'f4_public_reader has forbidden write-like column privilege(s) on %', v_table;
    END IF;
  END LOOP;

  FOR v_col IN
    SELECT c.relname AS table_name, a.attname AS column_name
    FROM pg_class AS c
    JOIN pg_namespace AS n ON n.oid = c.relnamespace
    JOIN pg_attribute AS a ON a.attrelid = c.oid
    WHERE n.nspname = 'public'
      AND c.relname IN ('election_settings', 'candidates', 'ballots')
      AND c.relkind IN ('r', 'p')
      AND a.attnum > 0
      AND NOT a.attisdropped
    ORDER BY c.relname, a.attnum
  LOOP
    v_allowlisted :=
      (v_col.table_name = 'election_settings' AND v_col.column_name IN ('id', 'current_phase', 'nomination_start', 'nomination_end', 'voting_start', 'voting_end', 'allow_write_ins', 'max_nominees_per_member'))
      OR
      (v_col.table_name = 'candidates' AND v_col.column_name IN ('id', 'full_name', 'statement', 'photo_url', 'is_active', 'created_at'))
      OR
      (v_col.table_name = 'ballots' AND v_col.column_name IN ('ballot_id', 'receipt_code', 'channel', 'cast_date', 'candidate_id'));

    IF v_allowlisted THEN
      v_allowlist_count := v_allowlist_count + 1;
    END IF;

    v_effective_select := has_column_privilege('f4_public_reader', format('public.%I', v_col.table_name), v_col.column_name, 'SELECT');

    IF v_allowlisted AND NOT v_effective_select THEN
      RAISE EXCEPTION 'missing required column SELECT grant: %.%', v_col.table_name, v_col.column_name;
    END IF;

    IF NOT v_allowlisted AND v_effective_select THEN
      RAISE EXCEPTION 'forbidden column SELECT grant detected: %.%', v_col.table_name, v_col.column_name;
    END IF;
  END LOOP;

  IF v_allowlist_count <> 19 THEN
    RAISE EXCEPTION 'unexpected F4 allowlist shape, expected 19 columns got %', v_allowlist_count;
  END IF;

  IF has_table_privilege('anon', 'public.ballots', 'SELECT')
     OR has_table_privilege('anon', 'public.candidates', 'SELECT')
     OR has_table_privilege('anon', 'public.election_settings', 'SELECT') THEN
    RAISE EXCEPTION 'anon has forbidden direct table SELECT';
  END IF;

  IF has_table_privilege('authenticated', 'public.ballots', 'SELECT')
     OR has_table_privilege('authenticated', 'public.candidates', 'SELECT')
     OR has_table_privilege('authenticated', 'public.election_settings', 'SELECT') THEN
    RAISE EXCEPTION 'authenticated has forbidden direct table SELECT';
  END IF;

  IF has_any_column_privilege('anon', 'public.ballots', 'SELECT')
     OR has_any_column_privilege('anon', 'public.candidates', 'SELECT')
     OR has_any_column_privilege('anon', 'public.election_settings', 'SELECT') THEN
    RAISE EXCEPTION 'anon has forbidden direct column SELECT';
  END IF;

  IF has_any_column_privilege('authenticated', 'public.ballots', 'SELECT')
     OR has_any_column_privilege('authenticated', 'public.candidates', 'SELECT')
     OR has_any_column_privilege('authenticated', 'public.election_settings', 'SELECT') THEN
    RAISE EXCEPTION 'authenticated has forbidden direct column SELECT';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies p
    WHERE p.schemaname = 'public'
      AND p.tablename = 'election_settings'
      AND p.policyname = 'f4_public_reader_settings_id1'
      AND p.permissive = 'PERMISSIVE'
      AND p.cmd = 'SELECT'
      AND p.roles = ARRAY['f4_public_reader'::name]
  ) THEN
    RAISE EXCEPTION 'missing/invalid RLS policy f4_public_reader_settings_id1';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies p
    WHERE p.schemaname = 'public'
      AND p.tablename = 'candidates'
      AND p.policyname = 'f4_public_reader_active_candidates'
      AND p.permissive = 'PERMISSIVE'
      AND p.cmd = 'SELECT'
      AND p.roles = ARRAY['f4_public_reader'::name]
  ) THEN
    RAISE EXCEPTION 'missing/invalid RLS policy f4_public_reader_active_candidates';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies p
    WHERE p.schemaname = 'public'
      AND p.tablename = 'ballots'
      AND p.policyname = 'f4_public_reader_ballots_verify'
      AND p.permissive = 'PERMISSIVE'
      AND p.cmd = 'SELECT'
      AND p.roles = ARRAY['f4_public_reader'::name]
  ) THEN
    RAISE EXCEPTION 'missing/invalid RLS policy f4_public_reader_ballots_verify';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_policies p
    WHERE p.schemaname = 'public'
      AND p.policyname IN ('Public can view settings', 'Public can view candidates', 'Public can view receipt codes')
  ) THEN
    RAISE EXCEPTION 'legacy PUBLIC SELECT policy/policies still present after cleanup';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_policies p
    WHERE p.schemaname = 'public'
      AND p.tablename IN ('election_settings', 'candidates', 'ballots')
      AND p.cmd = 'SELECT'
      AND p.policyname NOT IN (
        'f4_public_reader_settings_id1',
        'f4_public_reader_active_candidates',
        'f4_public_reader_ballots_verify'
      )
  ) THEN
    RAISE EXCEPTION 'unexpected SELECT policy detected on F4 source tables';
  END IF;

  IF (
    SELECT count(*)
    FROM pg_policies p
    WHERE p.schemaname = 'public'
      AND p.tablename IN ('election_settings', 'candidates', 'ballots')
      AND p.cmd = 'SELECT'
  ) <> 3 THEN
    RAISE EXCEPTION 'expected exactly 3 SELECT policies across source tables after cleanup';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname IN ('election_settings', 'candidates', 'ballots')
      AND c.relkind IN ('r', 'p')
      AND NOT c.relrowsecurity
  ) THEN
    RAISE EXCEPTION 'RLS must be enabled (relrowsecurity=true) on all target tables';
  END IF;

  SELECT pg_get_expr(p.polqual, p.polrelid)
    INTO v_expr
  FROM pg_policy p
  JOIN pg_class c ON c.oid = p.polrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relname = 'election_settings'
    AND p.polname = 'f4_public_reader_settings_id1';
  IF v_expr IS DISTINCT FROM '(id = 1)' THEN
    RAISE EXCEPTION 'unexpected USING clause for election_settings policy: %', v_expr;
  END IF;

  SELECT pg_get_expr(p.polqual, p.polrelid)
    INTO v_expr
  FROM pg_policy p
  JOIN pg_class c ON c.oid = p.polrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relname = 'candidates'
    AND p.polname = 'f4_public_reader_active_candidates';
  IF v_expr IS DISTINCT FROM '(is_active = true)' THEN
    RAISE EXCEPTION 'unexpected USING clause for candidates policy: %', v_expr;
  END IF;

  SELECT pg_get_expr(p.polqual, p.polrelid)
    INTO v_expr
  FROM pg_policy p
  JOIN pg_class c ON c.oid = p.polrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relname = 'ballots'
    AND p.polname = 'f4_public_reader_ballots_verify';
  IF v_expr IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'unexpected USING clause for ballots policy: %', v_expr;
  END IF;
END
$$;

COMMIT;
