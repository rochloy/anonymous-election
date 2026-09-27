-- ============================================================================
-- Wipe election data (v0.15.2+)
-- Purpose: in-app "Danger zone" database wipe for new-election setup.
--   - SETUP-only (server-side gate): catastrophic mid-election; the blast
--     radius is bounded to roster/candidates/settings, never votes.
--   - ATOMIC: one function call = one transaction — a mid-way failure rolls
--     back everything (row-by-row DELETEs from the app could not guarantee
--     this).
--   - Data-only: the seed.sql truncate list (FK-safety UAT-verified, Wave 7);
--     the HMAC key and schema are untouched. The SQL Editor reseed remains
--     the path for schema changes / full rebuilds.
--   - Governance: WIPE_STARTED + WIPE_COMPLETED appended to the wipe-surviving
--     governance ledger INSIDE this transaction (the ledger is never-truncated
--     by design; vote_audit_log is wiped and must NOT carry the wipe event).
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
  DELETE FROM members;

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

-- NOTE: the function's identity is wipe_election_data(UUID) — the REVOKE/GRANT
-- must match that signature exactly, or they fail with 42883 and the function
-- keeps its default PUBLIC execute privilege (a security hole).
REVOKE EXECUTE ON FUNCTION private.wipe_election_data(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.wipe_election_data(UUID) TO service_role;
