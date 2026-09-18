-- ============================================================================
-- migration_wave8_voting_entitlement_provision.sql
-- v0.14.0 Wave 8 — voting entitlement provisioning + lazy paper check-in create.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================================
-- 1) Ensure exactly one non-voided VOTING entitlement per eligible active member.
-- ============================================================================
CREATE OR REPLACE FUNCTION private.ensure_voting_entitlement(
  p_member_id UUID,
  p_admin_id UUID DEFAULT NULL,
  p_token_hash VARCHAR(64) DEFAULT NULL,
  p_channel_sent VARCHAR(20) DEFAULT 'NONE'
)
RETURNS TABLE (
  success BOOLEAN,
  code TEXT,
  message TEXT,
  token_id UUID,
  created BOOLEAN,
  expires_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_member RECORD;
  v_token RECORD;
  v_token_count INTEGER := 0;
  v_ttl_hours INTEGER := 168;
  v_hash VARCHAR(64);
BEGIN
  SELECT id, is_active, voting_eligible
  INTO v_member
  FROM members
  WHERE id = p_member_id
  FOR UPDATE;

  IF v_member.id IS NULL OR v_member.is_active IS NOT TRUE OR v_member.voting_eligible IS NOT TRUE THEN
    RETURN QUERY SELECT FALSE, 'VOTER_INELIGIBLE'::TEXT, 'Member is not eligible to vote.'::TEXT, NULL::UUID, FALSE, NULL::TIMESTAMPTZ;
    RETURN;
  END IF;

  FOR v_token IN
    SELECT id, is_used, tokens.expires_at
    FROM tokens
    WHERE member_id = p_member_id
      AND type = 'VOTING'
      AND voided_at IS NULL
    ORDER BY created_at DESC, id
    FOR UPDATE
  LOOP
    v_token_count := v_token_count + 1;
  END LOOP;

  IF v_token_count > 1 THEN
    RETURN QUERY SELECT FALSE, 'INTEGRITY_ERROR'::TEXT, 'Integrity error: multiple non-voided voting entitlements found for member.'::TEXT, NULL::UUID, FALSE, NULL::TIMESTAMPTZ;
    RETURN;
  END IF;

  IF v_token_count = 1 THEN
    IF v_token.is_used IS TRUE THEN
      RETURN QUERY SELECT FALSE, 'ENTITLEMENT_CONSUMED'::TEXT, 'Voting entitlement already consumed.'::TEXT, v_token.id, FALSE, v_token.expires_at;
      RETURN;
    END IF;

    RETURN QUERY SELECT TRUE, 'ENTITLEMENT_EXISTS'::TEXT, 'Voting entitlement already exists.'::TEXT, v_token.id, FALSE, v_token.expires_at;
    RETURN;
  END IF;

  IF p_channel_sent NOT IN ('NONE', 'EMAIL') THEN
    RETURN QUERY SELECT FALSE, 'INTEGRITY_ERROR'::TEXT, 'Invalid entitlement channel. Allowed: NONE, EMAIL.'::TEXT, NULL::UUID, FALSE, NULL::TIMESTAMPTZ;
    RETURN;
  END IF;

  SELECT COALESCE(voting_token_ttl_hours, 168)
  INTO v_ttl_hours
  FROM election_settings
  WHERE id = 1;

  v_hash := COALESCE(p_token_hash, encode(digest(gen_random_bytes(32), 'sha256'), 'hex'));

  INSERT INTO tokens (
    member_id,
    token_hash,
    type,
    is_used,
    channel_sent,
    expires_at
  )
  VALUES (
    p_member_id,
    v_hash,
    'VOTING',
    FALSE,
    p_channel_sent,
    now() + (v_ttl_hours * interval '1 hour')
  )
  RETURNING id, tokens.expires_at
  INTO token_id, expires_at;

  RETURN QUERY SELECT TRUE, 'ENTITLEMENT_CREATED'::TEXT, 'Voting entitlement created.'::TEXT, token_id, TRUE, expires_at;
END;
$$;

CREATE OR REPLACE FUNCTION public.ensure_voting_entitlement(
  p_member_id UUID,
  p_admin_id UUID DEFAULT NULL,
  p_token_hash VARCHAR(64) DEFAULT NULL,
  p_channel_sent VARCHAR(20) DEFAULT 'NONE'
)
RETURNS TABLE (
  success BOOLEAN,
  code TEXT,
  message TEXT,
  token_id UUID,
  created BOOLEAN,
  expires_at TIMESTAMPTZ
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, private
AS $$
  SELECT * FROM private.ensure_voting_entitlement(p_member_id, p_admin_id, p_token_hash, p_channel_sent);
$$;

-- ============================================================================
-- 2) Batch entitlement provisioning (no email, no hashes).
-- ============================================================================
CREATE OR REPLACE FUNCTION private.provision_voting_entitlements(
  p_member_ids UUID[] DEFAULT NULL,
  p_admin_id UUID DEFAULT NULL
)
RETURNS TABLE (
  requested_count INT,
  created_count INT,
  existing_count INT,
  ineligible_count INT,
  consumed_count INT,
  integrity_failed_count INT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_member RECORD;
  v_result RECORD;
  v_requested_count INT := 0;
  v_created_count INT := 0;
  v_existing_count INT := 0;
  v_ineligible_count INT := 0;
  v_consumed_count INT := 0;
  v_integrity_failed_count INT := 0;
BEGIN
  FOR v_member IN
    SELECT m.id, m.voting_eligible
    FROM members m
    WHERE m.is_active = TRUE
      AND (p_member_ids IS NULL OR m.id = ANY(p_member_ids))
  LOOP
    v_requested_count := v_requested_count + 1;

    IF v_member.voting_eligible IS NOT TRUE THEN
      v_ineligible_count := v_ineligible_count + 1;
      CONTINUE;
    END IF;

    SELECT * INTO v_result
    FROM private.ensure_voting_entitlement(v_member.id, p_admin_id, NULL, 'NONE');

    IF v_result.success IS TRUE THEN
      IF v_result.created IS TRUE THEN
        v_created_count := v_created_count + 1;
      ELSE
        v_existing_count := v_existing_count + 1;
      END IF;
    ELSIF v_result.code = 'VOTER_INELIGIBLE' THEN
      v_ineligible_count := v_ineligible_count + 1;
    ELSIF v_result.code = 'ENTITLEMENT_CONSUMED' THEN
      v_consumed_count := v_consumed_count + 1;
    ELSIF v_result.code = 'INTEGRITY_ERROR' THEN
      v_integrity_failed_count := v_integrity_failed_count + 1;
    ELSE
      v_integrity_failed_count := v_integrity_failed_count + 1;
    END IF;
  END LOOP;

  -- SEC-18: route through the hash-chaining audit RPC, NOT a raw insert.
  -- A direct INSERT would leave record_hash/previous_hash NULL and break the
  -- tamper-evident chain. insert_audit_log is SECURITY DEFINER and computes the
  -- chain via compute_audit_log_hash.
  PERFORM public.insert_audit_log(
    'ENTITLEMENTS_PROVISIONED',
    p_admin_id,
    NULL::UUID,
    jsonb_build_object(
      'requested_count', v_requested_count,
      'created_count', v_created_count,
      'existing_count', v_existing_count,
      'ineligible_count', v_ineligible_count,
      'consumed_count', v_consumed_count,
      'integrity_failed_count', v_integrity_failed_count
    )
  );

  RETURN QUERY
  SELECT
    v_requested_count,
    v_created_count,
    v_existing_count,
    v_ineligible_count,
    v_consumed_count,
    v_integrity_failed_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.provision_voting_entitlements(
  p_member_ids UUID[] DEFAULT NULL,
  p_admin_id UUID DEFAULT NULL
)
RETURNS TABLE (
  requested_count INT,
  created_count INT,
  existing_count INT,
  ineligible_count INT,
  consumed_count INT,
  integrity_failed_count INT
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, private
AS $$
  SELECT * FROM private.provision_voting_entitlements(p_member_ids, p_admin_id);
$$;

-- ============================================================================
-- 3) Wave 8 amendment of check_in_paper_voter: lazy-create entitlement when absent.
-- ============================================================================
CREATE OR REPLACE FUNCTION private.check_in_paper_voter(
  p_short_code TEXT,
  p_member_id UUID,
  p_admin_id UUID DEFAULT NULL
)
RETURNS TABLE (
  success BOOLEAN,
  message TEXT,
  member_name TEXT,
  member_code TEXT,
  short_code TEXT,
  participation_date DATE,
  status TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_short_code TEXT := upper(trim(p_short_code));
  v_member RECORD;
  v_paper RECORD;
  v_token RECORD;
  v_token_count INTEGER := 0;
  v_updated INTEGER := 0;
  v_has_digital_res BOOLEAN := FALSE;
  v_entitlement RECORD;
BEGIN
  IF v_short_code IS NULL OR v_short_code = '' THEN
    RETURN QUERY SELECT FALSE, 'short_code is required.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::DATE, NULL::TEXT;
    RETURN;
  END IF;

  SELECT m.id, m.member_code, m.full_name, m.voting_eligible
  INTO v_member
  FROM members m
  WHERE m.id = p_member_id
    AND m.is_active = TRUE
  FOR SHARE;

  IF v_member.id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Member not found or inactive.'::TEXT, NULL::TEXT, NULL::TEXT, v_short_code, NULL::DATE, NULL::TEXT;
    RETURN;
  END IF;

  IF v_member.voting_eligible IS NOT TRUE THEN
    RETURN QUERY SELECT FALSE, 'Member is not eligible to vote.'::TEXT, v_member.full_name::TEXT, v_member.member_code::TEXT, v_short_code, NULL::DATE, NULL::TEXT;
    RETURN;
  END IF;

  SELECT *
  INTO v_paper
  FROM paper_ballots
  WHERE paper_ballots.short_code = v_short_code
  FOR UPDATE;

  IF v_paper.id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Identity slip short code not found.'::TEXT, v_member.full_name::TEXT, v_member.member_code::TEXT, v_short_code, NULL::DATE, NULL::TEXT;
    RETURN;
  END IF;

  IF v_paper.status <> 'AVAILABLE' THEN
    RETURN QUERY SELECT FALSE, 'Identity slip is not available for check-in.'::TEXT, v_member.full_name::TEXT, v_member.member_code::TEXT, v_short_code, v_paper.checked_in_date, v_paper.status::TEXT;
    RETURN;
  END IF;

  IF v_paper.member_id IS NOT NULL AND v_paper.member_id <> p_member_id THEN
    RETURN QUERY SELECT FALSE, 'Identity slip belongs to a different member.'::TEXT, v_member.full_name::TEXT, v_member.member_code::TEXT, v_short_code, NULL::DATE, NULL::TEXT;
    RETURN;
  END IF;

  FOR v_token IN
    SELECT id, is_used, channel_sent, reserved_channel
    FROM tokens
    WHERE member_id = p_member_id
      AND type = 'VOTING'
      AND voided_at IS NULL
    ORDER BY created_at DESC, id
    FOR UPDATE
  LOOP
    v_token_count := v_token_count + 1;
    IF v_token_count > 1 THEN
      RETURN QUERY SELECT FALSE, 'Integrity error: multiple active voting tokens found for member.'::TEXT, v_member.full_name::TEXT, v_member.member_code::TEXT, v_short_code, NULL::DATE, NULL::TEXT;
      RETURN;
    END IF;
  END LOOP;

  IF v_token_count = 0 THEN
    SELECT * INTO v_entitlement
    FROM private.ensure_voting_entitlement(p_member_id, p_admin_id, NULL, 'NONE');

    IF v_entitlement.success IS NOT TRUE THEN
      RETURN QUERY SELECT FALSE, COALESCE(v_entitlement.message, 'No active voting entitlement found.')::TEXT, v_member.full_name::TEXT, v_member.member_code::TEXT, v_short_code, NULL::DATE, NULL::TEXT;
      RETURN;
    END IF;

    SELECT id, is_used, channel_sent, reserved_channel
    INTO v_token
    FROM tokens
    WHERE id = v_entitlement.token_id
      AND voided_at IS NULL
    FOR UPDATE;

    IF v_token.id IS NULL THEN
      RETURN QUERY SELECT FALSE, 'Could not resolve voting entitlement token.'::TEXT, v_member.full_name::TEXT, v_member.member_code::TEXT, v_short_code, NULL::DATE, NULL::TEXT;
      RETURN;
    END IF;
  END IF;

  IF v_token.is_used IS TRUE THEN
    RETURN QUERY SELECT FALSE, 'Voting entitlement already consumed.'::TEXT, v_member.full_name::TEXT, v_member.member_code::TEXT, v_short_code, NULL::DATE, NULL::TEXT;
    RETURN;
  END IF;

  SELECT TRUE INTO v_has_digital_res
    FROM digital_credential_reservations
   WHERE token_id = v_token.id AND expires_at > now()
   LIMIT 1;
  IF v_has_digital_res IS TRUE THEN
    RETURN QUERY SELECT FALSE, 'Member has an active digital voting credential; release or wait for it to expire before paper check-in.'::TEXT, v_member.full_name::TEXT, v_member.member_code::TEXT, v_short_code, NULL::DATE, NULL::TEXT;
    RETURN;
  END IF;

  UPDATE tokens
  SET is_used = TRUE,
      used_at = now(),
      channel_sent = 'PAPER',
      reserved_at = now(),
      reserved_channel = 'PAPER',
      reservation_released_at = NULL
  WHERE id = v_token.id
    AND is_used = FALSE
    AND voided_at IS NULL;

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  IF v_updated <> 1 THEN
    RETURN QUERY SELECT FALSE, 'Could not consume paper voting entitlement.'::TEXT, v_member.full_name::TEXT, v_member.member_code::TEXT, v_short_code, NULL::DATE, NULL::TEXT;
    RETURN;
  END IF;

  UPDATE paper_ballots
  SET member_id = p_member_id,
      token_id = v_token.id,
      status = 'ISSUED_TO_VOTER',
      checked_in_at = now(),
      checked_in_date = CURRENT_DATE,
      checked_in_by = p_admin_id
  WHERE id = v_paper.id;

  INSERT INTO participation_audit(action, member_id, token_id, channel, event_date, admin_id)
  VALUES ('PAPER_CHECK_IN', p_member_id, v_token.id, 'PAPER', CURRENT_DATE, p_admin_id);

  RETURN QUERY SELECT TRUE, 'Paper voter checked in.'::TEXT, v_member.full_name::TEXT, v_member.member_code::TEXT, v_short_code, CURRENT_DATE, 'ISSUED_TO_VOTER'::TEXT;
END;
$$;

-- ============================================================================
-- 4) Grants (service_role only).
-- ============================================================================
REVOKE EXECUTE ON FUNCTION private.ensure_voting_entitlement(UUID, UUID, VARCHAR, VARCHAR) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.ensure_voting_entitlement(UUID, UUID, VARCHAR, VARCHAR) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.provision_voting_entitlements(UUID[], UUID) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.provision_voting_entitlements(UUID[], UUID) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION private.ensure_voting_entitlement(UUID, UUID, VARCHAR, VARCHAR) TO service_role;
GRANT EXECUTE ON FUNCTION public.ensure_voting_entitlement(UUID, UUID, VARCHAR, VARCHAR) TO service_role;
GRANT EXECUTE ON FUNCTION private.provision_voting_entitlements(UUID[], UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.provision_voting_entitlements(UUID[], UUID) TO service_role;
