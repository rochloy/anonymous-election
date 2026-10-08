-- test_db_security_sabotage.sql
--
-- DELIBERATELY breaks six security invariants to prove the suite can fail
-- (the test-a-guard-against-known-bad-input rule). Used only by
-- `scripts/test-db-security.sh prove-red` against the DISPOSABLE LOCAL
-- FIXTURE. Refuses to run if the database looks Supabase-provisioned.
--
-- Violations applied (expected suite failures in brackets):
--   GRANT SELECT ON public.candidates TO anon                    [S01]
--   GRANT USAGE ON SCHEMA private TO anon                        [S02]
--   private.sabotage_canary() with default PUBLIC EXECUTE        [S03, S06]
--   private.hmac_sign(text) recreated                            [S03, S08]
--   default-privilege grant of SELECT on tables to anon          [S04]
--   backup_sabotage schema holding co-located member/ballot data [S13]
--
-- Undo with test_db_security_restore.sql.

DO $$ BEGIN
IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname='auth') THEN
  RAISE EXCEPTION 'REFUSING TO SABOTAGE: this database looks Supabase-provisioned (auth schema present). Sabotage is for the disposable local fixture only.';
END IF;
END $$;

GRANT SELECT ON public.candidates TO anon;
GRANT USAGE ON SCHEMA private TO anon;

CREATE FUNCTION private.sabotage_canary() RETURNS void
  LANGUAGE plpgsql AS $$ BEGIN NULL; END $$;

CREATE FUNCTION private.hmac_sign(p_payload text) RETURNS text
  LANGUAGE plpgsql AS $$ BEGIN RETURN 'sabotage'; END $$;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  GRANT SELECT ON TABLES TO anon;

CREATE SCHEMA backup_sabotage;
CREATE TABLE backup_sabotage.leak (member_id uuid, ballot_id text, candidate_id uuid);
INSERT INTO backup_sabotage.leak
VALUES (gen_random_uuid(), 'PAPER:sabotage', gen_random_uuid());
