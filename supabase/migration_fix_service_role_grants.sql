-- MIGRATION: Grant service_role table privileges on paper_ballots + vote_audit_log
-- Run this in the Supabase SQL Editor.
--
-- ROOT CAUSE:
--   paper_ballots and vote_audit_log were created in migration_paper_ballots.sql
--   with RLS enabled and EXECUTE granted on the RPC functions, but NO table-level
--   privileges were ever granted to service_role. The SECURITY DEFINER RPCs still
--   work (they run as the function owner and bypass table grants), but direct
--   PostgREST reads from the admin API (app/api/admin/members/route.ts) run as
--   service_role and failed with:
--     42501 — permission denied for table paper_ballots
--   That error was being swallowed, so every member showed as ELIGIBLE even when
--   they already had an active paper ballot.
--
-- NOTE: service_role bypasses RLS, so no RLS policies are needed here — only the
--   table-level GRANTs. RLS stays enabled to keep anon/authenticated locked out.

GRANT SELECT, INSERT, UPDATE, DELETE ON public.paper_ballots  TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.vote_audit_log TO service_role;

-- Belt-and-suspenders: ensure any future tables in public also default-grant to
-- service_role (matches how the base-schema tables behave).
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO service_role;

-- Verify (optional): after running, this should return two rows.
-- SELECT grantee, table_name, privilege_type
-- FROM information_schema.role_table_grants
-- WHERE table_schema = 'public'
--   AND table_name IN ('paper_ballots', 'vote_audit_log')
--   AND grantee = 'service_role'
-- ORDER BY table_name, privilege_type;
