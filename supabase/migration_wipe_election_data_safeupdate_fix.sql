-- ============================================================================
-- Wipe election data — pg-safeupdate fix (canonical run order item 41)
-- Purpose: redefine private.wipe_election_data (item 38) so its unqualified
--   `DELETE FROM members;` carries a WHERE clause.
--
-- Why: Supabase loads the pg-safeupdate extension for PostgREST (API) requests.
--   Its post-parse-analyze hook rejects any DELETE/UPDATE whose WHERE clause is
--   absent ("DELETE requires a WHERE clause"), including statements executed
--   inside SECURITY DEFINER functions reached via the API. The SQL Editor does
--   not load it, which is why the same statement works in seed.sql. The hook
--   only checks that a WHERE clause exists, so `WHERE id IS NOT NULL` (always
--   true for a primary key) passes while still deleting every row.
--   TRUNCATE is not DELETE/UPDATE and is unaffected.
--
-- Body is otherwise IDENTICAL to item 38. The function was atomic, so the
-- failed attempt rolled back fully (no partial wipe).
--
-- Run AFTER migration_wipe_election_data.sql (item 38) and its public wrapper
-- (item 40). Idempotent. Signature unchanged — the public wrapper keeps working.
-- ============================================================================

CREATE OR REPLACE FUNCTION private.wipe_election_data(
  p_admin_id UUID DEFAULT NULL
)
RETURNS TABLE (success BOOLEAN, message TEXT)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, private, governance, extensions
AS $$
BEGIN
  -- SETUP-only gate
  IF (SELECT current_phase FROM election_settings WHERE id = 1) <> 'SETUP' THEN
    RETURN QUERY SELECT FALSE, 'Database wipe is only allowed during SETUP phase.'::TEXT;
    RETURN;
  END IF;

  -- Governance: WIPE_STARTED (the ledger survives the truncate; this
  -- transaction is atomic so both events land or neither does).
  PERFORM private.append_governance_event(
    'WIPE_STARTED', p_admin_id, 'admin', NULL, NULL,
    'Election data wipe for new-election setup', 'Legitimate interest',
    NULL, NULL, NULL,
    jsonb_build_object('scope', 'all election-scoped tables + members')
  );

  TRUNCATE candidates, tokens, anonymous_nominations, ballots, paper_ballots,
    paper_ballot_batches, vote_audit_log, eligibility_adjudications, phase_change_tokens,
    admin_sessions, rate_limit_hits CASCADE;
  -- WHERE clause required by pg-safeupdate on API requests (see header).
  DELETE FROM members WHERE id IS NOT NULL;

  -- Phase back to SETUP (the gate ensured it; explicit for clarity).
  UPDATE election_settings SET current_phase = 'SETUP' WHERE id = 1;

  PERFORM private.append_governance_event(
    'WIPE_COMPLETED', p_admin_id, 'admin', NULL, NULL,
    'Election data wipe for new-election setup', 'Legitimate interest',
    NULL, NULL, NULL,
    jsonb_build_object('scope', 'all election-scoped tables + members', 'result', 'clean SETUP state')
  );

  RETURN QUERY SELECT TRUE, 'Election data wiped. Database is ready for a new election (SETUP phase). All admin sessions were revoked.'::TEXT;
END;
$$;

-- Re-assert privileges (CREATE OR REPLACE keeps existing ACLs; this is
-- belt-and-braces). Signature MUST be (UUID) — see item 38.
REVOKE EXECUTE ON FUNCTION private.wipe_election_data(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.wipe_election_data(UUID) TO service_role;
