-- MIGRATION: Wave 6 nomination prefix-search fix
-- Supersedes the matching predicate in migration_nomination_submission.sql
-- for private.search_members_for_nomination to guarantee short-prefix matches
-- (ILIKE prefix) while preserving fuzzy tolerance (pg_trgm word_similarity).
-- Run AFTER migration_nomination_submission.sql.

CREATE OR REPLACE FUNCTION private.search_members_for_nomination(
  p_token_hash VARCHAR(64), p_query TEXT
)
RETURNS TABLE (member_id UUID, full_name TEXT)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE v_phase election_phase; v_token_id UUID; v_is_used BOOLEAN;
        v_expires_at TIMESTAMPTZ; v_voided_at TIMESTAMPTZ;
BEGIN
  IF p_query IS NULL OR length(trim(p_query)) < 2 THEN RETURN; END IF;
  SELECT current_phase INTO v_phase FROM election_settings WHERE id=1;
  IF v_phase <> 'NOMINATION' THEN RETURN; END IF;

  SELECT id, is_used, expires_at, voided_at
    INTO v_token_id, v_is_used, v_expires_at, v_voided_at
    FROM tokens WHERE token_hash = p_token_hash AND type='NOMINATION';   -- NO row lock, NO update
  IF v_token_id IS NULL OR v_is_used OR v_voided_at IS NOT NULL
     OR v_expires_at IS NULL OR v_expires_at <= NOW() THEN RETURN; END IF;

  RETURN QUERY
    SELECT m.id, m.full_name::text FROM members m
    WHERE m.is_active = TRUE
      AND (
        m.full_name ILIKE p_query || '%'
        OR p_query <% m.full_name
      )
    ORDER BY word_similarity(p_query, m.full_name) DESC, m.full_name
    LIMIT 5;                                                    -- minimal fields only
END; $$;
