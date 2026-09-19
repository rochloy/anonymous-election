-- ============================================================================
-- migration_wave9_allow_member_add_during_voting.sql
-- Wave 9 — configurable late member addition during the VOTING phase.
--
-- Adds election_settings.allow_adding_member_during_voting (default FALSE).
-- When TRUE, private.create_member is additionally permitted during VOTING,
-- to accommodate members physically present at paper voting whose roster
-- entry was not completed before voting started. New members are created
-- is_active=TRUE and inherit the members.voting_eligible DEFAULT TRUE, so
-- they are immediately paper-check-in-able.
--
-- Scope (deliberate):
--   * set_member_active (activate/deactivate EXISTING members) is NOT relaxed —
--     it keeps calling assert_electorate_editable() (SETUP/NOMINATION/
--     NOMINATION_CLOSED only).
--   * Bulk CSV import keeps its own API-layer phase gate (members-import
--     route) and is NOT relaxed.
--   * Token dispatch is untouched.
--
-- The setting itself is only changeable during SETUP/NOMINATION/
-- NOMINATION_CLOSED/VOTING (enforced at the settings API layer).
-- ============================================================================

ALTER TABLE election_settings
  ADD COLUMN IF NOT EXISTS allow_adding_member_during_voting BOOLEAN NOT NULL DEFAULT FALSE;

-- ============================================================================
-- 1) Creation gate: SETUP/NOMINATION/NOMINATION_CLOSED always; VOTING only
--    when the flag is enabled; VOTING_CLOSED/COMPLETED never.
-- ============================================================================
CREATE OR REPLACE FUNCTION private.assert_member_creation_allowed()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_phase election_phase;
  v_allow_during_voting BOOLEAN;
BEGIN
  SELECT current_phase, allow_adding_member_during_voting
  INTO v_phase, v_allow_during_voting
  FROM election_settings
  WHERE id = 1;

  IF v_phase IN ('SETUP', 'NOMINATION', 'NOMINATION_CLOSED') THEN
    RETURN;
  END IF;

  IF v_phase = 'VOTING' AND v_allow_during_voting IS TRUE THEN
    RETURN;
  END IF;

  RAISE EXCEPTION 'Member creation is only allowed during SETUP, NOMINATION, or NOMINATION_CLOSED phases, or during VOTING when allow_adding_member_during_voting is enabled.';
END;
$$;

-- ============================================================================
-- 2) create_member: swap the gate from assert_electorate_editable() to
--    assert_member_creation_allowed(). Body otherwise identical to
--    migration_member_mgmt_phase_gate.sql (the previous final writer).
--    CREATE OR REPLACE preserves existing privileges on create_member and
--    its public wrapper (which delegates by signature and needs no change).
-- ============================================================================
CREATE OR REPLACE FUNCTION private.create_member(
  p_full_name TEXT,
  p_email TEXT DEFAULT NULL,
  p_phone TEXT DEFAULT NULL,
  p_member_code TEXT DEFAULT NULL
)
RETURNS members
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_member members;
  v_member_code TEXT;
BEGIN
  PERFORM private.assert_member_creation_allowed();

  IF trim(coalesce(p_full_name, '')) = '' THEN
    RAISE EXCEPTION 'full_name is required';
  END IF;

  v_member_code := NULLIF(trim(coalesce(p_member_code, '')), '');
  IF v_member_code IS NULL THEN
    v_member_code := 'M-' || encode(gen_random_bytes(4), 'hex');
  END IF;

  INSERT INTO members (member_code, full_name, email, phone, is_active)
  VALUES (
    v_member_code,
    trim(p_full_name),
    NULLIF(trim(coalesce(p_email, '')), ''),
    NULLIF(trim(coalesce(p_phone, '')), ''),
    TRUE
  )
  RETURNING * INTO v_member;

  RETURN v_member;
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'MEMBER_UNIQUE_CONFLICT: member_code/email/phone already exists' USING ERRCODE = '23505';
END;
$$;

-- ============================================================================
-- 3) Grants: assert_member_creation_allowed is internal (PERFORMed inside the
--    SECURITY DEFINER create_member); no direct execution grant, mirroring
--    assert_electorate_editable. Revoke from client roles defensively.
-- ============================================================================
REVOKE EXECUTE ON FUNCTION private.assert_member_creation_allowed() FROM PUBLIC, anon, authenticated;
