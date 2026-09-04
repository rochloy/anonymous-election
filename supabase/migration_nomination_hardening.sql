-- migration_nomination_hardening.sql  (oracle security follow-up SEC-02b + SEC-03)
-- Run AFTER migration_rate_limit.sql and migration_nomination_submission.sql.
-- Idempotent: safe to re-apply at the Option-B wipe.

-- ============================================================================
-- SEC-03: check_rate_limit is SECURITY DEFINER and must not be callable by
-- untrusted roles. All invocations go through the service-role server client;
-- PUBLIC/anon/authenticated have no business executing it directly.
-- (This REVOKE deliberately lives here, NOT in the already-applied
--  migration_rate_limit.sql, to avoid re-editing an applied migration.)
-- ============================================================================
REVOKE EXECUTE ON FUNCTION check_rate_limit(TEXT, INT, INT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION check_rate_limit(TEXT, INT, INT) TO service_role;

-- ============================================================================
-- SEC-02b: check_rate_limit only deletes stale rows for the identifier it is
-- called with, so identifiers that stop being hit leave rows behind forever.
-- This global sweep lets an operator (or scheduled job) reclaim them. The
-- existing composite index leads with `identifier`, so a WHERE created_at < X
-- scan across all identifiers can't use it — add a standalone created_at index.
-- ============================================================================
CREATE INDEX IF NOT EXISTS idx_rate_limit_hits_created_at
  ON rate_limit_hits(created_at);

CREATE OR REPLACE FUNCTION private.cleanup_rate_limit_hits(p_older_than_seconds INT DEFAULT 3600)
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE v_deleted INT;
BEGIN
  DELETE FROM rate_limit_hits
    WHERE created_at < now() - (p_older_than_seconds || ' seconds')::INTERVAL;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END; $$;

REVOKE EXECUTE ON FUNCTION private.cleanup_rate_limit_hits(INT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.cleanup_rate_limit_hits(INT) TO service_role;
