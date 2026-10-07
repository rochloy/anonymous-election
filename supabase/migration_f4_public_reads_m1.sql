BEGIN;

-- M1: least-privilege public read boundary for F4.
-- Forward-only, additive, no election data writes.

-- Fail-loud precondition: this migration is first-run only.
-- Reject any pre-existing role or public function name/signature collisions.
DO $$
DECLARE
  v_existing integer;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'f4_public_reader') THEN
    RAISE EXCEPTION 'precondition failed: role f4_public_reader already exists';
  END IF;

  SELECT pg_catalog.count(*)
    INTO v_existing
  FROM pg_proc AS p
  JOIN pg_namespace AS n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname IN ('f4_election_status', 'f4_candidates', 'f4_verify_ballot', 'f4_results');

  IF v_existing <> 0 THEN
    RAISE EXCEPTION 'precondition failed: expected zero pre-existing public f4 function(s), found %', v_existing;
  END IF;
END
$$;

CREATE ROLE f4_public_reader
  NOLOGIN
  NOSUPERUSER
  NOCREATEDB
  NOCREATEROLE
  NOINHERIT
  NOBYPASSRLS;

-- Temporary membership posture for owner transfer workflow.
GRANT f4_public_reader TO postgres WITH SET TRUE, INHERIT FALSE;
GRANT CREATE ON SCHEMA public TO f4_public_reader;

-- Narrow schema/table access for the dedicated reader.
GRANT USAGE ON SCHEMA public TO f4_public_reader;

GRANT SELECT (id, current_phase, nomination_start, nomination_end, voting_start, voting_end, allow_write_ins, max_nominees_per_member)
  ON public.election_settings TO f4_public_reader;
GRANT SELECT (id, full_name, statement, photo_url, is_active, created_at)
  ON public.candidates TO f4_public_reader;
GRANT SELECT (ballot_id, receipt_code, channel, cast_date, candidate_id)
  ON public.ballots TO f4_public_reader;

DROP POLICY IF EXISTS f4_public_reader_settings_id1 ON public.election_settings;
CREATE POLICY f4_public_reader_settings_id1
  ON public.election_settings
  FOR SELECT
  TO f4_public_reader
  USING (id = 1);

DROP POLICY IF EXISTS f4_public_reader_active_candidates ON public.candidates;
CREATE POLICY f4_public_reader_active_candidates
  ON public.candidates
  FOR SELECT
  TO f4_public_reader
  USING (is_active = true);

DROP POLICY IF EXISTS f4_public_reader_ballots_verify ON public.ballots;
CREATE POLICY f4_public_reader_ballots_verify
  ON public.ballots
  FOR SELECT
  TO f4_public_reader
  USING (true);

CREATE FUNCTION public.f4_election_status()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_current_phase public.election_phase;
  v_nomination_start timestamptz;
  v_nomination_end timestamptz;
  v_voting_start timestamptz;
  v_voting_end timestamptz;
  v_allow_write_ins boolean;
  v_max_nominees_per_member integer;
BEGIN
  SELECT
    s.current_phase,
    s.nomination_start,
    s.nomination_end,
    s.voting_start,
    s.voting_end,
    s.allow_write_ins,
    s.max_nominees_per_member
    INTO
      v_current_phase,
      v_nomination_start,
      v_nomination_end,
      v_voting_start,
      v_voting_end,
      v_allow_write_ins,
      v_max_nominees_per_member
  FROM public.election_settings
  AS s
  WHERE id = 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'public read unavailable';
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'phase', v_current_phase::text,
    'current_phase', v_current_phase::text,
    'nomination_start', v_nomination_start,
    'nomination_end', v_nomination_end,
    'voting_start', v_voting_start,
    'voting_end', v_voting_end,
    'allow_write_ins', v_allow_write_ins,
    'max_nominees_per_member', v_max_nominees_per_member
  );
END;
$$;

CREATE FUNCTION public.f4_candidates()
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'id', c.id,
        'full_name', c.full_name,
        'statement', c.statement,
        'photo_url', c.photo_url
      )
      ORDER BY c.created_at ASC, c.id ASC
    ),
    '[]'::jsonb
  )
  FROM public.candidates AS c
  WHERE c.is_active = true;
$$;

CREATE FUNCTION public.f4_verify_ballot(p_ballot_id text, p_receipt_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_ballot_id text;
  v_receipt text;
  v_bound constant integer := 256;
  v_found_channel text;
  v_found_cast_date date;
  v_found_receipt_code text;
BEGIN
  v_ballot_id := NULLIF(pg_catalog.btrim(p_ballot_id), '');
  v_receipt := NULLIF(pg_catalog.upper(pg_catalog.btrim(p_receipt_code)), '');

  IF v_ballot_id IS NOT NULL AND pg_catalog.length(v_ballot_id) > v_bound THEN
    RETURN pg_catalog.jsonb_build_object('found', false);
  END IF;

  IF v_receipt IS NOT NULL THEN
    IF pg_catalog.length(v_receipt) > 32 THEN
      RETURN pg_catalog.jsonb_build_object('found', false);
    END IF;

    IF v_receipt !~ '^VC-[0-9A-F]{10}$' THEN
      RETURN pg_catalog.jsonb_build_object('found', false);
    END IF;

    v_receipt := 'VC-' || pg_catalog.lower(pg_catalog.right(v_receipt, 10));
  END IF;

  IF v_ballot_id IS NULL AND v_receipt IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('found', false);
  END IF;

  IF v_ballot_id IS NOT NULL THEN
    SELECT b.channel, b.cast_date, b.receipt_code
      INTO v_found_channel, v_found_cast_date, v_found_receipt_code
    FROM public.ballots AS b
    WHERE b.ballot_id = v_ballot_id
    LIMIT 1;

    IF NOT FOUND THEN
      RETURN pg_catalog.jsonb_build_object('found', false);
    END IF;

    RETURN pg_catalog.jsonb_build_object(
      'found', true,
      'channel', v_found_channel,
      'cast_date', v_found_cast_date,
      'receipt_match', CASE
        WHEN v_receipt IS NULL THEN NULL
        ELSE (v_found_receipt_code = v_receipt)
      END
    );
  END IF;

  SELECT b.channel, b.cast_date
    INTO v_found_channel, v_found_cast_date
  FROM public.ballots AS b
  WHERE b.receipt_code = v_receipt
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('found', false);
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'found', true,
    'channel', v_found_channel,
    'cast_date', v_found_cast_date
  );
END;
$$;

CREATE FUNCTION public.f4_results(p_receipt_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_phase public.election_phase;
  v_receipt text;
  v_total_votes bigint;
  v_receipt_found boolean := NULL;
  v_results jsonb;
BEGIN
  SELECT s.current_phase
    INTO v_phase
  FROM public.election_settings AS s
  WHERE s.id = 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'public read unavailable';
  END IF;

  IF v_phase NOT IN ('VOTING_CLOSED', 'COMPLETED') THEN
    RETURN pg_catalog.jsonb_build_object(
      'published', false,
      'phase', v_phase::text
    );
  END IF;

  v_receipt := NULLIF(pg_catalog.upper(pg_catalog.btrim(p_receipt_code)), '');
  IF v_receipt IS NOT NULL THEN
    IF pg_catalog.length(v_receipt) > 32 THEN
      RAISE EXCEPTION 'public read unavailable';
    END IF;
    v_receipt := pg_catalog.lower(v_receipt);
  END IF;

  SELECT pg_catalog.count(b.candidate_id)
    INTO v_total_votes
  FROM public.ballots AS b;

  IF v_receipt IS NOT NULL THEN
    SELECT EXISTS(
      SELECT 1
      FROM public.ballots AS b
      WHERE pg_catalog.lower(b.receipt_code) = v_receipt
    )
      INTO v_receipt_found;
  END IF;

  SELECT COALESCE(
           pg_catalog.jsonb_agg(r.row_obj ORDER BY r.votes DESC, r.created_at ASC, r.id ASC),
           '[]'::jsonb
         )
    INTO v_results
  FROM (
    SELECT
      c.id,
      c.created_at,
      pg_catalog.count(b.candidate_id) AS votes,
      pg_catalog.jsonb_build_object(
        'id', c.id,
        'full_name', c.full_name,
        'statement', c.statement,
        'photo_url', c.photo_url,
        'votes', pg_catalog.count(b.candidate_id),
        'percentage', CASE
          WHEN v_total_votes > 0
            THEN pg_catalog.round((pg_catalog.count(b.candidate_id)::numeric * 100.0) / v_total_votes::numeric, 1)
          ELSE 0
        END
      ) AS row_obj
    FROM public.candidates AS c
    LEFT JOIN public.ballots AS b
      ON b.candidate_id = c.id
    WHERE c.is_active = true
    GROUP BY c.id, c.full_name, c.statement, c.photo_url, c.created_at
  ) AS r;

  RETURN pg_catalog.jsonb_build_object(
    'published', true,
    'phase', v_phase::text,
    'totalVotes', v_total_votes,
    'results', v_results,
    'receipt_found', v_receipt_found
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.f4_election_status() FROM PUBLIC, authenticated;
REVOKE EXECUTE ON FUNCTION public.f4_candidates() FROM PUBLIC, authenticated;
REVOKE EXECUTE ON FUNCTION public.f4_verify_ballot(text, text) FROM PUBLIC, authenticated;
REVOKE EXECUTE ON FUNCTION public.f4_results(text) FROM PUBLIC, authenticated;

GRANT EXECUTE ON FUNCTION public.f4_election_status() TO anon;
GRANT EXECUTE ON FUNCTION public.f4_candidates() TO anon;
GRANT EXECUTE ON FUNCTION public.f4_verify_ballot(text, text) TO anon;
GRANT EXECUTE ON FUNCTION public.f4_results(text) TO anon;

ALTER FUNCTION public.f4_election_status() OWNER TO f4_public_reader;
ALTER FUNCTION public.f4_candidates() OWNER TO f4_public_reader;
ALTER FUNCTION public.f4_verify_ballot(text, text) OWNER TO f4_public_reader;
ALTER FUNCTION public.f4_results(text) OWNER TO f4_public_reader;

REVOKE CREATE ON SCHEMA public FROM f4_public_reader;
REVOKE SET OPTION FOR f4_public_reader FROM postgres;

-- Fail-loud postconditions.
DO $$
DECLARE
  v_owner name;
  v_role record;
  v_authenticated_inherits_anon boolean;
  v_col record;
  v_allowlisted boolean;
  v_effective_select boolean;
  v_allowlist_count integer;
  v_overload_count integer;
BEGIN
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

  IF has_schema_privilege('f4_public_reader', 'public', 'CREATE') THEN
    RAISE EXCEPTION 'f4_public_reader retains CREATE on schema public';
  END IF;

  IF pg_has_role('postgres', 'f4_public_reader', 'SET') THEN
    RAISE EXCEPTION 'postgres still has SET ROLE privilege on f4_public_reader';
  END IF;

  IF has_table_privilege('f4_public_reader', 'public.election_settings', 'SELECT') THEN
    RAISE EXCEPTION 'f4_public_reader has forbidden table-wide SELECT on election_settings';
  END IF;
  IF has_table_privilege('f4_public_reader', 'public.candidates', 'SELECT') THEN
    RAISE EXCEPTION 'f4_public_reader has forbidden table-wide SELECT on candidates';
  END IF;
  IF has_table_privilege('f4_public_reader', 'public.ballots', 'SELECT') THEN
    RAISE EXCEPTION 'f4_public_reader has forbidden table-wide SELECT on ballots';
  END IF;

  v_allowlist_count := 0;
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
    RAISE EXCEPTION 'unexpected f4 allowlist shape, expected 19 columns got %', v_allowlist_count;
  END IF;

  IF has_table_privilege('f4_public_reader', 'public.ballots', 'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
     OR has_table_privilege('f4_public_reader', 'public.candidates', 'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
     OR has_table_privilege('f4_public_reader', 'public.election_settings', 'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') THEN
    RAISE EXCEPTION 'f4_public_reader has forbidden write-like table privileges';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_roles r ON r.oid = c.relowner
    WHERE n.nspname = 'public'
      AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
      AND c.relname IN ('ballots', 'candidates', 'election_settings')
      AND r.rolname = 'f4_public_reader'
  ) THEN
    RAISE EXCEPTION 'f4_public_reader must not own source tables';
  END IF;

  SELECT r.rolname
    INTO v_owner
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  JOIN pg_roles r ON r.oid = p.proowner
  WHERE n.nspname = 'public'
    AND p.proname = 'f4_election_status'
    AND pg_get_function_identity_arguments(p.oid) = '';
  IF v_owner IS DISTINCT FROM 'f4_public_reader' THEN
    RAISE EXCEPTION 'unexpected owner for public.f4_election_status(): %', v_owner;
  END IF;

  SELECT r.rolname
    INTO v_owner
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  JOIN pg_roles r ON r.oid = p.proowner
  WHERE n.nspname = 'public'
    AND p.proname = 'f4_candidates'
    AND pg_get_function_identity_arguments(p.oid) = '';
  IF v_owner IS DISTINCT FROM 'f4_public_reader' THEN
    RAISE EXCEPTION 'unexpected owner for public.f4_candidates(): %', v_owner;
  END IF;

  SELECT r.rolname
    INTO v_owner
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  JOIN pg_roles r ON r.oid = p.proowner
  WHERE n.nspname = 'public'
    AND p.proname = 'f4_verify_ballot'
    AND pg_get_function_identity_arguments(p.oid) = 'p_ballot_id text, p_receipt_code text';
  IF v_owner IS DISTINCT FROM 'f4_public_reader' THEN
    RAISE EXCEPTION 'unexpected owner for public.f4_verify_ballot(text,text): %', v_owner;
  END IF;

  SELECT r.rolname
    INTO v_owner
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  JOIN pg_roles r ON r.oid = p.proowner
  WHERE n.nspname = 'public'
    AND p.proname = 'f4_results'
    AND pg_get_function_identity_arguments(p.oid) = 'p_receipt_code text';
  IF v_owner IS DISTINCT FROM 'f4_public_reader' THEN
    RAISE EXCEPTION 'unexpected owner for public.f4_results(text): %', v_owner;
  END IF;

  IF NOT has_function_privilege('anon', 'public.f4_election_status()', 'EXECUTE')
     OR NOT has_function_privilege('anon', 'public.f4_candidates()', 'EXECUTE')
     OR NOT has_function_privilege('anon', 'public.f4_verify_ballot(text,text)', 'EXECUTE')
     OR NOT has_function_privilege('anon', 'public.f4_results(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon execute privilege missing for one or more f4 functions';
  END IF;

  IF to_regprocedure('public.f4_election_status()') IS NULL
     OR to_regprocedure('public.f4_candidates()') IS NULL
     OR to_regprocedure('public.f4_verify_ballot(text,text)') IS NULL
     OR to_regprocedure('public.f4_results(text)') IS NULL THEN
    RAISE EXCEPTION 'missing required f4 function signature(s) for ACL verification';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_proc AS p
    JOIN pg_namespace AS n
      ON n.oid = p.pronamespace
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
    RAISE EXCEPTION 'PUBLIC retains execute on one or more f4 functions';
  END IF;

  IF has_function_privilege('authenticated', 'public.f4_election_status()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.f4_candidates()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.f4_verify_ballot(text,text)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.f4_results(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated retains execute on one or more f4 functions';
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

  SELECT pg_has_role('authenticated', 'anon', 'USAGE')
    INTO v_authenticated_inherits_anon;

  IF v_authenticated_inherits_anon THEN
    RAISE EXCEPTION 'oracle-conflict: authenticated effectively inherits anon; explicit authenticated EXECUTE deny is not enforceable while anon EXECUTE grant exists';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_auth_members AS m
    JOIN pg_roles AS granted ON granted.oid = m.roleid
    JOIN pg_roles AS member_role ON member_role.oid = m.member
    WHERE member_role.rolname = 'f4_public_reader'
      AND m.inherit_option
  ) THEN
    RAISE EXCEPTION 'f4_public_reader has inherited role memberships';
  END IF;

  SELECT pg_catalog.count(*)
    INTO v_overload_count
  FROM pg_proc AS p
  JOIN pg_namespace AS n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'f4_election_status';
  IF v_overload_count <> 1 THEN
    RAISE EXCEPTION 'unexpected overload count for public.f4_election_status: %', v_overload_count;
  END IF;

  SELECT pg_catalog.count(*)
    INTO v_overload_count
  FROM pg_proc AS p
  JOIN pg_namespace AS n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'f4_candidates';
  IF v_overload_count <> 1 THEN
    RAISE EXCEPTION 'unexpected overload count for public.f4_candidates: %', v_overload_count;
  END IF;

  SELECT pg_catalog.count(*)
    INTO v_overload_count
  FROM pg_proc AS p
  JOIN pg_namespace AS n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'f4_verify_ballot';
  IF v_overload_count <> 1 THEN
    RAISE EXCEPTION 'unexpected overload count for public.f4_verify_ballot: %', v_overload_count;
  END IF;

  SELECT pg_catalog.count(*)
    INTO v_overload_count
  FROM pg_proc AS p
  JOIN pg_namespace AS n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'f4_results';
  IF v_overload_count <> 1 THEN
    RAISE EXCEPTION 'unexpected overload count for public.f4_results: %', v_overload_count;
  END IF;
END
$$;

NOTIFY pgrst, 'reload schema';

COMMIT;
