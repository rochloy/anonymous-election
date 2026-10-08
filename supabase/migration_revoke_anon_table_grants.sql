-- migration_revoke_anon_table_grants.sql
--
-- Removes residual non-DML table privileges (TRUNCATE, REFERENCES, TRIGGER,
-- MAINTAIN) held by `anon` and `authenticated` on every table in `public`,
-- AND removes the ALTER DEFAULT PRIVILEGES rule that re-grants them on every
-- newly created table.
--
-- WHY THIS MATTERS
-- `anon`/`authenticated` held TRUNCATE on 15 public tables, including
-- `ballots` and `vote_audit_log`. TRUNCATE does not fire ON DELETE triggers
-- and is not subject to row-level security, so the append-only guarantee
-- provided by private.reject_vote_audit_log_mutation() does NOT apply to it.
-- These roles held no SELECT/INSERT/UPDATE/DELETE, so nothing in the
-- application depends on any of this; PostgREST does not expose TRUNCATE.
-- This is defence-in-depth, closing a privilege that has no legitimate use.
--
-- ROOT CAUSE
-- `ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public` granted
-- `Dxtm` (TRUNCATE, REFERENCES, TRIGGER, MAINTAIN) to anon + authenticated on
-- every new table. A prior fix revoked the DML letters (`arwd`) but left these.
-- Revoking the existing grants WITHOUT fixing the default would regress on the
-- very next migration that creates a table.
--
-- NOT IN SCOPE (deliberate): the `supabase_admin`-owned default-privilege rule
-- in `public`, which grants anon/authenticated `arwdDxtm` on tables created by
-- supabase_admin. App migrations run as `postgres`, so that rule is not the
-- operative path, but it should be reviewed separately.
--
-- F4 PUBLIC READS ARE UNAFFECTED: the public transparency surface works via
-- EXECUTE on the f4_* SECURITY DEFINER functions (owned by f4_public_reader),
-- not via table privileges held by `anon`. Function EXECUTE grants are not
-- touched by this migration.
--
-- Idempotent. Safe to re-run.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Remove the existing grants on all current tables in `public`.
-- ---------------------------------------------------------------------------
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Stop the default-privilege rule from re-granting them on new tables.
--    Must name the same grantor role (`postgres`) that created the rule.
-- ---------------------------------------------------------------------------
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON TABLES FROM anon, authenticated;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON SEQUENCES FROM anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2b. Remove PUBLIC EXECUTE from every function in schema `private`.
--
--     Verified on hosted 2026-10-08: 10 of 47 private functions are
--     PUBLIC-executable -- 8 with proacl IS NULL (PostgreSQL's default, which
--     includes PUBLIC) and 2 (hmac_sign, hmac_verify) carrying an explicit
--     `=X/postgres` ACL entry. Among them: purge_roster_pii,
--     append_governance_event, adjudicate_eligibility, and the vote_audit_log
--     colocation/mutation trigger guards.
--
--     Root cause is NOT a deliberate grant. `GRANT ... TO service_role`
--     without a matching `REVOKE ... FROM PUBLIC` simply leaves PostgreSQL's
--     default PUBLIC EXECUTE in place. Reproduced locally: creating a function
--     and granting only to service_role yields exactly the hosted ACL
--     `{=X/postgres,postgres=X/postgres,service_role=X/postgres}`.
--
--     Currently UNREACHABLE because anon/authenticated lack USAGE on schema
--     `private`. That single schema grant is the only thing standing between
--     the internet and purge_roster_pii. This removes the dependence on it.
--
--     SAFE FOR TRIGGER FUNCTIONS. PostgreSQL checks EXECUTE on a trigger
--     function at CREATE TRIGGER time, not at fire time. Verified empirically
--     on a local PostgreSQL 17.6 container: after revoking EXECUTE from
--     PUBLIC/anon/authenticated/service_role, a BEFORE INSERT guard still
--     raised on a violating row, and a legitimate row still inserted.
--
--     Dynamic rather than enumerated so it cannot drift as functions are added.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  r      RECORD;
  v_done INT := 0;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'private'
      AND (
        p.proacl IS NULL
        OR EXISTS (SELECT 1 FROM unnest(p.proacl) AS a(item) WHERE a.item::text LIKE '=%')
      )
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated', r.sig);
    v_done := v_done + 1;
  END LOOP;

  RAISE NOTICE 'Revoked PUBLIC EXECUTE from % function(s) in schema private.', v_done;
END
$$;

-- ---------------------------------------------------------------------------
-- 3. Fail-closed post-condition.
--    Aborts the transaction if ANY table privilege survives for either role.
--    Run this block on its own against the pre-migration catalog to prove it
--    actually fails (RED) before trusting a green result here.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_remaining INT;
  v_detail    TEXT;
BEGIN
  SELECT count(*), string_agg(DISTINCT c.relname || ':' || r.rolname || ':' || p.priv, ', ')
    INTO v_remaining, v_detail
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  CROSS JOIN (SELECT unnest(ARRAY['anon','authenticated']) AS rolname) r
  CROSS JOIN (SELECT unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE',
                                  'TRUNCATE','REFERENCES','TRIGGER','MAINTAIN']) AS priv) p
  WHERE n.nspname = 'public'
    AND c.relkind = 'r'
    AND has_table_privilege(r.rolname, c.oid, p.priv);

  IF v_remaining > 0 THEN
    RAISE EXCEPTION
      'ABORT: % residual public-table privilege(s) still held by anon/authenticated: %',
      v_remaining, v_detail;
  END IF;

  RAISE NOTICE 'OK: anon and authenticated hold zero table privileges in schema public.';
END
$$;

-- ---------------------------------------------------------------------------
-- 4. Fail-closed post-condition on the default-privilege rule itself.
--    Guards against the regression this migration exists to prevent.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_bad TEXT;
BEGIN
  -- Scope: TABLES ('r') and SEQUENCES ('S') only -- the object classes this
  -- migration actually alters. Deliberately NOT functions ('f'): default
  -- EXECUTE grants on new functions are a separate concern, already clean on
  -- the hosted database ({postgres=X/postgres}) though not in a stock Supabase
  -- image. Asserting over 'f' here would conflate two unrelated issues.
  SELECT string_agg(pg_get_userbyid(d.defaclrole) || ' [' || d.defaclobjtype::text || '] -> '
                    || d.defaclacl::text, '; ')
    INTO v_bad
  FROM pg_default_acl d
  JOIN pg_namespace n ON n.oid = d.defaclnamespace
  WHERE n.nspname = 'public'
    AND d.defaclobjtype IN ('r', 'S')
    AND pg_get_userbyid(d.defaclrole) = 'postgres'
    AND d.defaclacl::text ~ '(anon|authenticated)=';

  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION
      'ABORT: postgres default privileges for tables/sequences in public still reference anon/authenticated: %',
      v_bad;
  END IF;

  RAISE NOTICE 'OK: no postgres-owned default table/sequence grants to anon/authenticated in public.';
END
$$;

COMMIT;
