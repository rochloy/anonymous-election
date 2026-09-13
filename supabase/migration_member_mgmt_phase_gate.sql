-- ============================================================================
-- migration_member_mgmt_phase_gate.sql
-- Member management phase gate + RPCs for create/activate/deactivate.
-- NOTE: Add this migration to the CANONICAL run order in docs/TECHNICAL_GUIDE.md.
-- ============================================================================

CREATE OR REPLACE FUNCTION private.assert_electorate_editable()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_phase election_phase;
BEGIN
  SELECT current_phase INTO v_phase FROM election_settings WHERE id = 1;
  IF v_phase NOT IN ('SETUP', 'NOMINATION', 'NOMINATION_CLOSED') THEN
    RAISE EXCEPTION 'Member edits are only allowed during SETUP, NOMINATION, or NOMINATION_CLOSED phases.';
  END IF;
END;
$$;

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
  PERFORM private.assert_electorate_editable();

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

CREATE OR REPLACE FUNCTION private.set_member_active(
  p_member_id UUID,
  p_active BOOLEAN
)
RETURNS members
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_member members;
BEGIN
  PERFORM private.assert_electorate_editable();

  UPDATE members
  SET is_active = p_active
  WHERE id = p_member_id
  RETURNING * INTO v_member;

  IF v_member.id IS NULL THEN
    RAISE EXCEPTION 'Member not found.';
  END IF;

  RETURN v_member;
END;
$$;

CREATE OR REPLACE FUNCTION public.assert_electorate_editable()
RETURNS VOID
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, private
AS $$
  SELECT private.assert_electorate_editable();
$$;

CREATE OR REPLACE FUNCTION public.create_member(
  p_full_name TEXT,
  p_email TEXT DEFAULT NULL,
  p_phone TEXT DEFAULT NULL,
  p_member_code TEXT DEFAULT NULL
)
RETURNS members
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, private
AS $$
  SELECT * FROM private.create_member(p_full_name, p_email, p_phone, p_member_code);
$$;

CREATE OR REPLACE FUNCTION public.set_member_active(
  p_member_id UUID,
  p_active BOOLEAN
)
RETURNS members
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, private
AS $$
  SELECT * FROM private.set_member_active(p_member_id, p_active);
$$;

REVOKE EXECUTE ON FUNCTION private.assert_electorate_editable() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.create_member(TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.set_member_active(UUID, BOOLEAN) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION private.assert_electorate_editable() TO service_role;
GRANT EXECUTE ON FUNCTION private.create_member(TEXT, TEXT, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION private.set_member_active(UUID, BOOLEAN) TO service_role;

REVOKE EXECUTE ON FUNCTION public.assert_electorate_editable() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.create_member(TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.set_member_active(UUID, BOOLEAN) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.assert_electorate_editable() TO service_role;
GRANT EXECUTE ON FUNCTION public.create_member(TEXT, TEXT, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.set_member_active(UUID, BOOLEAN) TO service_role;
