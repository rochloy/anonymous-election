-- ============================================================================
-- Nomination adjudication hardening (canonical run order item 44)
-- Replaces private/public adjudicate_nomination signatures in-place.
--
-- Goals:
-- - reject NULL / duplicate / nonexistent affected nomination UUIDs
-- - lock target anonymous_nominations rows deterministically (UUID ASC) with FOR UPDATE
-- - separately reject any overlap with nomination_adjudications.affected_nomination_ids
--   across ALL historical decisions before candidate creation
-- - preserve existing adjudication actions + append-only audit side effects
-- - preserve service_role-only ACL for private/public wrappers
--
-- Concurrency note: assumes READ COMMITTED (Supabase default).
-- ============================================================================

BEGIN;

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
  v_phase          election_phase;
  v_name           TEXT;
  v_candidate_id   UUID := NULL;
  v_input_count    INT;
  v_distinct_count INT;
  v_null_count     INT;
  v_exists_count   INT;
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

  SELECT
    COUNT(*),
    COUNT(*) FILTER (WHERE id IS NULL),
    COUNT(DISTINCT id)
  INTO v_input_count, v_null_count, v_distinct_count
  FROM unnest(p_affected_nomination_ids) AS t(id);

  IF v_null_count > 0 THEN
    RETURN QUERY SELECT FALSE, 'affectedNominationIds cannot contain null.'::TEXT, NULL::UUID; RETURN;
  END IF;

  IF v_input_count <> v_distinct_count THEN
    RETURN QUERY SELECT FALSE, 'affectedNominationIds cannot contain duplicates.'::TEXT, NULL::UUID; RETURN;
  END IF;

  SELECT current_phase INTO v_phase FROM election_settings WHERE id = 1;
  IF v_phase <> 'NOMINATION_CLOSED' THEN
    RETURN QUERY SELECT FALSE, 'Adjudication is only allowed during NOMINATION_CLOSED.'::TEXT, NULL::UUID; RETURN;
  END IF;

  -- Lock target nomination rows deterministically (UUID ASC), no SKIP LOCKED.
  WITH input_ids AS (
    SELECT id
    FROM unnest(p_affected_nomination_ids) AS t(id)
  )
  SELECT COUNT(*) INTO v_exists_count
  FROM (
    SELECT an.id
    FROM anonymous_nominations an
    JOIN input_ids i ON i.id = an.id
    ORDER BY an.id ASC
    FOR UPDATE
  ) locked;

  IF v_exists_count <> v_input_count THEN
    RETURN QUERY SELECT FALSE, 'One or more affected nominations do not exist.'::TEXT, NULL::UUID; RETURN;
  END IF;

  -- Separate overlap check against ALL prior decisions (historical rows included).
  IF EXISTS (
    SELECT 1
    FROM nomination_adjudications na
    WHERE na.affected_nomination_ids && p_affected_nomination_ids
  ) THEN
    RETURN QUERY SELECT FALSE, 'One or more nominations were already adjudicated.'::TEXT, NULL::UUID; RETURN;
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

  INSERT INTO nomination_adjudications
    (admin_id, decision, candidate_id, nominee_member_id, affected_nomination_ids, note)
  VALUES
    (p_admin_session_id, p_decision, v_candidate_id, p_nominee_member_id, p_affected_nomination_ids, p_note);

  PERFORM insert_audit_log(
    'ADMIN_ACTION',
    p_admin_session_id,
    NULL,
    jsonb_build_object(
      'op',                    'adjudicate_nomination',
      'decision',              p_decision,
      'nomineeMemberId',       p_nominee_member_id,
      'candidateId',           v_candidate_id,
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

-- Service-role-only pending unmatched read helper for the admin nominations API.
CREATE OR REPLACE FUNCTION private.get_pending_unmatched_nominations(
  p_limit INT DEFAULT 200,
  p_cursor_date DATE DEFAULT NULL,
  p_cursor_id UUID DEFAULT NULL
)
RETURNS TABLE (
  id UUID,
  nominee_name TEXT,
  reason TEXT,
  submitted_date DATE
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, private
AS $$
  SELECT an.id, an.nominee_name::TEXT, an.reason::TEXT, an.submitted_date
  FROM anonymous_nominations an
  WHERE an.nominee_member_id IS NULL
    AND (
      (p_cursor_date IS NULL AND p_cursor_id IS NULL)
      OR coalesce(an.submitted_date, DATE '0001-01-01') < coalesce(p_cursor_date, DATE '0001-01-01')
      OR (
        coalesce(an.submitted_date, DATE '0001-01-01') = coalesce(p_cursor_date, DATE '0001-01-01')
        AND p_cursor_id IS NOT NULL
        AND an.id > p_cursor_id
      )
    )
    AND NOT EXISTS (
      SELECT 1
      FROM nomination_adjudications na
      WHERE an.id = ANY(na.affected_nomination_ids)
    )
  ORDER BY an.submitted_date DESC NULLS LAST, an.id ASC
  LIMIT GREATEST(COALESCE(p_limit, 200), 0)
;
$$;

REVOKE EXECUTE ON FUNCTION private.get_pending_unmatched_nominations(INT, DATE, UUID)
  FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.get_pending_unmatched_nominations(INT, DATE, UUID)
  TO service_role;

CREATE OR REPLACE FUNCTION public.get_pending_unmatched_nominations(
  p_limit INT DEFAULT 200,
  p_cursor_date DATE DEFAULT NULL,
  p_cursor_id UUID DEFAULT NULL
)
RETURNS TABLE (
  id UUID,
  nominee_name TEXT,
  reason TEXT,
  submitted_date DATE
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, private
AS $$
  SELECT * FROM private.get_pending_unmatched_nominations(p_limit, p_cursor_date, p_cursor_id);
$$;

REVOKE EXECUTE ON FUNCTION public.get_pending_unmatched_nominations(INT, DATE, UUID)
  FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.get_pending_unmatched_nominations(INT, DATE, UUID)
  TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
