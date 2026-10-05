-- ============================================================================
-- Lock down audit-log hash-chain functions (canonical run order item 42)
-- Purpose: migration_audit_log_hash_chain.sql created public.insert_audit_log
--   and public.compute_audit_log_hash as SECURITY DEFINER in the
--   PostgREST-exposed `public` schema and only GRANTed service_role — it never
--   REVOKEd the default PUBLIC EXECUTE. Live check (2026-10-05) confirmed both
--   were executable by `anon`, so anyone holding the anon key could POST
--   /rest/v1/rpc/insert_audit_log and append forged rows to vote_audit_log
--   (audit-integrity / hash-chain pollution).
--
-- The app calls insert_audit_log only with the service-role key
-- (lib/audit-log.ts); other SECURITY DEFINER functions call it as their owner.
-- Neither path depends on anon/authenticated EXECUTE.
--
-- Signatures MUST match exactly (a mismatch fails 42883 and leaves the PUBLIC
-- default in place). Idempotent; safe to re-run.
-- ============================================================================

REVOKE EXECUTE ON FUNCTION public.insert_audit_log(TEXT, UUID, UUID, JSONB)
  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.compute_audit_log_hash(TEXT, UUID, UUID, JSONB, CHAR, TIMESTAMPTZ)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.insert_audit_log(TEXT, UUID, UUID, JSONB) TO service_role;
GRANT EXECUTE ON FUNCTION public.compute_audit_log_hash(TEXT, UUID, UUID, JSONB, CHAR, TIMESTAMPTZ) TO service_role;

NOTIFY pgrst, 'reload schema';
