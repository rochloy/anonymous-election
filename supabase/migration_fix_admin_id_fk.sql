-- ============================================================================
-- migration_fix_admin_id_fk.sql
-- Fix: `admin_id` was FK'd to members(id) on vote_audit_log and
-- nomination_adjudications, but the app's admin identity is an admin_sessions.id
-- (getAdminSession() returns the admin_sessions PK). Every non-null admin_id
-- insert therefore violated the FK, which:
--   (1) silently broke ALL admin-attributed audit logging (insert_audit_log +
--       the audit-log.ts fallback both hit the FK; callers ignore the error), and
--   (2) 400'd nomination adjudication (PROMOTE/MERGE/DISCARD). PROMOTE inserted a
--       candidate BEFORE the failing adjudication row, orphaning candidates.
--
-- Remediation (Plan C, oracle-reviewed 2026-09-05):
--   * Repoint both admin_id FKs -> admin_sessions(id) ON DELETE RESTRICT.
--     NOT "ON DELETE SET NULL": admin_id is hashed into the SEC-18 tamper-evident
--     chain, so nulling it post-insert would forge apparent tampering.
--   * RESTRICT means referenced sessions can no longer be deleted while audit rows
--     point at them -> session lifecycle becomes revoke-not-delete (revoked_at +
--     revoke_reason columns; token_hash scrubbed to NULL on revoke). App changes
--     in app/api/admin/logout/route.ts and app/api/admin/auth.ts.
--   * Make adjudication atomic via private.adjudicate_nomination (candidate +
--     adjudication + audit in one transaction). Public wrapper for PostgREST.
--   * Append-only guard on vote_audit_log (defence-in-depth for the hash chain).
--
-- Idempotent; safe to re-run. Run LAST in the canonical rebuild order.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. admin_sessions: revoke-not-delete lifecycle columns
-- ----------------------------------------------------------------------------
ALTER TABLE admin_sessions
  ADD COLUMN IF NOT EXISTS revoked_at    TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS revoke_reason TEXT;

-- Allow token_hash to be scrubbed to NULL on revoke (removes usable bearer
-- material while retaining the row as an audit principal). UNIQUE tolerates
-- multiple NULLs in Postgres.
ALTER TABLE admin_sessions ALTER COLUMN token_hash DROP NOT NULL;

CREATE INDEX IF NOT EXISTS idx_admin_sessions_revoked_at ON admin_sessions(revoked_at);

-- ----------------------------------------------------------------------------
-- 2. Repoint admin_id FKs: members(id) -> admin_sessions(id) ON DELETE RESTRICT
--    (vote_audit_log + nomination_adjudications are empty at migration time;
--     ADD CONSTRAINT validates existing rows.)
-- ----------------------------------------------------------------------------
ALTER TABLE vote_audit_log          DROP CONSTRAINT IF EXISTS vote_audit_log_admin_id_fkey;
ALTER TABLE nomination_adjudications DROP CONSTRAINT IF EXISTS nomination_adjudications_admin_id_fkey;

ALTER TABLE vote_audit_log
  ADD CONSTRAINT vote_audit_log_admin_id_fkey
  FOREIGN KEY (admin_id) REFERENCES admin_sessions(id) ON DELETE RESTRICT;

ALTER TABLE nomination_adjudications
  ADD CONSTRAINT nomination_adjudications_admin_id_fkey
  FOREIGN KEY (admin_id) REFERENCES admin_sessions(id) ON DELETE RESTRICT;

COMMENT ON COLUMN vote_audit_log.admin_id IS
  'Admin session id -> admin_sessions(id) (NOT members). See migration_fix_admin_id_fk.sql.';
COMMENT ON COLUMN nomination_adjudications.admin_id IS
  'Admin session id -> admin_sessions(id) (NOT members). See migration_fix_admin_id_fk.sql.';

-- ----------------------------------------------------------------------------
-- 3. Append-only guard on vote_audit_log (protects the SEC-18 hash chain).
--    INSERT stays allowed; UPDATE/DELETE rejected. TRUNCATE bypasses row
--    triggers, so the data-only wipe procedure is unaffected.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.reject_vote_audit_log_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
BEGIN
  RAISE EXCEPTION 'vote_audit_log is append-only; UPDATE/DELETE is not permitted.';
END;
$$;

DROP TRIGGER IF EXISTS trg_vote_audit_log_immutable ON vote_audit_log;
CREATE TRIGGER trg_vote_audit_log_immutable
  BEFORE UPDATE OR DELETE ON vote_audit_log
  FOR EACH ROW EXECUTE FUNCTION private.reject_vote_audit_log_mutation();

-- ----------------------------------------------------------------------------
-- 4. private.adjudicate_nomination — atomic candidate + adjudication + audit.
--    A failure at any step rolls the whole transaction back, so PROMOTE can no
--    longer orphan a candidate, and audit logging is hard-failed (in-txn).
--    Soft validation errors return success=false; the unique "one PROMOTE per
--    nominee" index raises 23505 (mapped to 409 by the route).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.adjudicate_nomination(
  p_decision                TEXT,
  p_admin_session_id        UUID,
  p_affected_nomination_ids UUID[],
  p_nominee_member_id       UUID DEFAULT NULL,
  p_nominee_name            TEXT DEFAULT NULL,
  p_candidate_statement     TEXT DEFAULT NULL,
  p_candidate_id            UUID DEFAULT NULL,
  p_note                    TEXT DEFAULT NULL
)
RETURNS TABLE (success BOOLEAN, message TEXT, candidate_id UUID)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_phase        election_phase;
  v_name         TEXT;
  v_candidate_id UUID := NULL;
BEGIN
  IF p_decision NOT IN ('PROMOTE','MERGE','DISCARD') THEN
    RETURN QUERY SELECT FALSE, 'Invalid decision.'::TEXT, NULL::UUID; RETURN;
  END IF;
  IF p_admin_session_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Admin session required.'::TEXT, NULL::UUID; RETURN;
  END IF;
  IF p_affected_nomination_ids IS NULL OR array_length(p_affected_nomination_ids, 1) IS NULL THEN
    RETURN QUERY SELECT FALSE, 'affectedNominationIds is required.'::TEXT, NULL::UUID; RETURN;
  END IF;

  SELECT current_phase INTO v_phase FROM election_settings WHERE id = 1;
  IF v_phase <> 'NOMINATION_CLOSED' THEN
    RETURN QUERY SELECT FALSE, 'Adjudication is only allowed during NOMINATION_CLOSED.'::TEXT, NULL::UUID; RETURN;
  END IF;

  IF p_decision = 'PROMOTE' THEN
    IF p_nominee_member_id IS NOT NULL THEN
      SELECT full_name INTO v_name FROM members WHERE id = p_nominee_member_id;
      IF v_name IS NULL THEN
        RETURN QUERY SELECT FALSE, 'Nominee member not found.'::TEXT, NULL::UUID; RETURN;
      END IF;
    ELSE
      v_name := trim(coalesce(p_nominee_name, ''));
      IF v_name = '' THEN
        RETURN QUERY SELECT FALSE, 'Nominee name is required for promote.'::TEXT, NULL::UUID; RETURN;
      END IF;
    END IF;

    INSERT INTO candidates (full_name, statement, is_active)
    VALUES (v_name, p_candidate_statement, TRUE)
    RETURNING id INTO v_candidate_id;

  ELSIF p_decision = 'MERGE' THEN
    IF p_candidate_id IS NULL THEN
      RETURN QUERY SELECT FALSE, 'candidateId is required for merge.'::TEXT, NULL::UUID; RETURN;
    END IF;
    v_candidate_id := p_candidate_id;
  END IF;

  -- Atomic adjudication row. May raise unique_violation (23505) on
  -- idx_adjudication_one_promote_per_nominee -> whole txn rolls back.
  INSERT INTO nomination_adjudications
    (admin_id, decision, candidate_id, nominee_member_id, affected_nomination_ids, note)
  VALUES
    (p_admin_session_id, p_decision, v_candidate_id, p_nominee_member_id, p_affected_nomination_ids, p_note);

  -- Hard-fail audit: same transaction. If this fails, the adjudication rolls back.
  PERFORM insert_audit_log(
    'ADMIN_ACTION',
    p_admin_session_id,
    NULL,
    jsonb_build_object(
      'op',                   'adjudicate_nomination',
      'decision',             p_decision,
      'nomineeMemberId',      p_nominee_member_id,
      'candidateId',          v_candidate_id,
      'affectedNominationIds', to_jsonb(p_affected_nomination_ids)
    )
  );

  RETURN QUERY SELECT TRUE, 'Adjudicated.'::TEXT, v_candidate_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION private.adjudicate_nomination(TEXT, UUID, UUID[], UUID, TEXT, TEXT, UUID, TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.adjudicate_nomination(TEXT, UUID, UUID[], UUID, TEXT, TEXT, UUID, TEXT)
  TO service_role;

-- ----------------------------------------------------------------------------
-- 5. Public PostgREST wrapper (private schema is not exposed).
--    Locked down per the wrapper gotcha: REVOKE the PUBLIC default, GRANT
--    service_role only.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.adjudicate_nomination(
  p_decision                TEXT,
  p_admin_session_id        UUID,
  p_affected_nomination_ids UUID[],
  p_nominee_member_id       UUID DEFAULT NULL,
  p_nominee_name            TEXT DEFAULT NULL,
  p_candidate_statement     TEXT DEFAULT NULL,
  p_candidate_id            UUID DEFAULT NULL,
  p_note                    TEXT DEFAULT NULL
)
RETURNS TABLE (success BOOLEAN, message TEXT, candidate_id UUID)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, private
AS $$
  SELECT * FROM private.adjudicate_nomination(
    p_decision, p_admin_session_id, p_affected_nomination_ids,
    p_nominee_member_id, p_nominee_name, p_candidate_statement,
    p_candidate_id, p_note);
$$;

REVOKE EXECUTE ON FUNCTION public.adjudicate_nomination(TEXT, UUID, UUID[], UUID, TEXT, TEXT, UUID, TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.adjudicate_nomination(TEXT, UUID, UUID[], UUID, TEXT, TEXT, UUID, TEXT)
  TO service_role;
