-- ============================================================================
-- migration_wave7_digital_severance.sql
-- v0.13.0 Wave 7 (P3) — DIGITAL-plane structural severance (canonical run-order item 35).
--
-- Goal: break the identity<->vote linkage on the DIGITAL channel using the
-- council-ratified TWO-PHASE transient-reservation design (redeem -> cast).
-- Supersedes the single-call private.submit_anonymous_vote for digital voting
-- when election_settings.digital_write_mode = 'TWO_PHASE'.
--
-- Council cou-4 REJECTED "burn-on-redeem" (marks a failed voter's token `used`;
-- recovery then requires removing the reissue guard, after which the DB cannot
-- tell "credential lost" from "credential live" -> admin mints a 2nd
-- uninvalidatable credential = double vote). This migration implements the
-- ADOPTED design instead:
--
--   Phase 1  redeem_voting_token(token_hash)        [IDENTITY plane]
--     - locks the VOTING token FOR UPDATE; runs phase/expiry/void/eligibility/
--       paper-conflict/active-reservation checks;
--     - RESERVES (does NOT consume) the token: sets reserved_at + reserved_channel
--       ='DIGITAL'; is_used stays FALSE so H2 recoverability is preserved;
--     - mints a one-time credential, stores only its SHA-256 hash;
--     - writes a short-TTL transient reservation row (credential_hash -> token_id);
--     - returns the plaintext credential + TTL. No vote handle in arg-list; no
--       identity handle in return.
--
--   Phase 2  cast_anonymous_digital_vote(credential, candidate_id)  [ANON plane]
--     - resolves credential_hash FOR UPDATE; must be RESERVED;
--     - inserts an opaque HMAC 'DIGITAL:' ballot (no ids/timestamps in payload);
--     - marks the credential CAST;
--     - atomically consumes the token (is_used=TRUE, channel_sent='DIGITAL') and
--       HARD-DELETES the transient reservation row, severing token_id<->credential.
--     - arg-list carries only a vote handle (credential); return carries only
--       vote handles (receipt, ballot_id). token_id is resolved via the transient
--       bridge in a LOCAL variable only (allowed; not a durable/arg/return surface).
--
-- Abandoned casts: the reservation TTL-expires and is swept lazily (no cron),
-- which releases the token (clears reserved_at/reserved_channel) so the voter can
-- redeem again -> H2 recoverability.
--
-- RATIFIED EXCEPTION to the no-co-occurrence "no durable row" rule: the
-- digital_credential_reservations table intentionally co-locates a vote handle
-- (credential_hash) and an identity handle (token_id). It is transient (short TTL,
-- hard-deleted on cast, swept on expiry), RLS-enabled, and service_role-only.
--
-- Residual (out of scope, tracked in spec Section 10): a WAL/service-role adversary
-- who can read the reservation row DURING its short lifetime.
--
-- Bodies reproduce the current deployed definitions verbatim where a function is
-- amended (reissue_token, submit_anonymous_vote, spoil_paper_check_in,
-- check_in_paper_voter); only the Wave 7 blocks are spliced in. All existing
-- guards, locks, signatures, and grants are preserved.
-- ============================================================================

-- ============================================================================
-- 1. Settings: digital writer-mode flag + transient-credential TTL.
--    digital_write_mode defaults to 'LEGACY' so applying this migration does NOT
--    break live single-call digital voting mid-rollout. The operator flips it to
--    'TWO_PHASE' (fail-closing the legacy RPC, activating redeem->cast) only AFTER
--    the split app is deployed.
-- ============================================================================
ALTER TABLE election_settings
  ADD COLUMN IF NOT EXISTS digital_write_mode VARCHAR(16) NOT NULL DEFAULT 'LEGACY',
  ADD COLUMN IF NOT EXISTS digital_credential_ttl_minutes INT NOT NULL DEFAULT 15;

ALTER TABLE election_settings
  DROP CONSTRAINT IF EXISTS election_settings_digital_write_mode_chk;
ALTER TABLE election_settings
  ADD CONSTRAINT election_settings_digital_write_mode_chk
  CHECK (digital_write_mode IN ('LEGACY', 'TWO_PHASE'));

ALTER TABLE election_settings
  DROP CONSTRAINT IF EXISTS election_settings_digital_ttl_positive_chk;
ALTER TABLE election_settings
  ADD CONSTRAINT election_settings_digital_ttl_positive_chk
  CHECK (digital_credential_ttl_minutes > 0 AND digital_credential_ttl_minutes <= 1440);

-- ============================================================================
-- 2. Anonymous digital credential table (ANON plane).
--    Stores ONLY the SHA-256 hash of the one-time credential + its lifecycle
--    status. No member_id, token_id, candidate_id, ballot_id, or timestamps that
--    could correlate to a cast. This is a vote-handle-only surface.
-- ============================================================================
CREATE TABLE IF NOT EXISTS anonymous_digital_credentials (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  credential_hash TEXT NOT NULL UNIQUE,
  status VARCHAR(10) NOT NULL DEFAULT 'RESERVED'
    CHECK (status IN ('RESERVED', 'CAST')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  cast_at TIMESTAMPTZ NULL
);

COMMENT ON TABLE anonymous_digital_credentials IS
  'Anon-plane digital voting credentials: SHA-256 hash + RESERVED/CAST status only. No identity handle.';

CREATE INDEX IF NOT EXISTS idx_anon_digital_credentials_status
  ON anonymous_digital_credentials(status);

ALTER TABLE anonymous_digital_credentials ENABLE ROW LEVEL SECURITY;
GRANT ALL ON anonymous_digital_credentials TO service_role;

-- ============================================================================
-- 3. Transient credential reservation table (RATIFIED transient bridge).
--    The ONLY surface that co-locates a vote handle (credential_hash) and an
--    identity handle (token_id). Short TTL, hard-deleted on cast, swept on expiry.
--    RLS on, service_role-only, never PostgREST-exposed.
-- ============================================================================
CREATE TABLE IF NOT EXISTS digital_credential_reservations (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  credential_hash TEXT NOT NULL UNIQUE
    REFERENCES anonymous_digital_credentials(credential_hash) ON DELETE CASCADE,
  token_id UUID NOT NULL REFERENCES tokens(id) ON DELETE CASCADE,
  reserved_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  -- One active reservation per token at a time.
  CONSTRAINT digital_credential_reservations_token_uniq UNIQUE (token_id)
);

COMMENT ON TABLE digital_credential_reservations IS
  'TRANSIENT identity<->credential bridge (credential_hash -> token_id). Short TTL, hard-deleted on cast, swept on expiry. RATIFIED exception to no-durable-co-occurrence. service_role-only.';

CREATE INDEX IF NOT EXISTS idx_digital_cred_reservations_expires
  ON digital_credential_reservations(expires_at);

ALTER TABLE digital_credential_reservations ENABLE ROW LEVEL SECURITY;
GRANT ALL ON digital_credential_reservations TO service_role;

-- ============================================================================
-- 4. Extend the three audit firewalls to also reject digital two-phase handles
--    ('credential', 'credential_hash', 'reservation_id') in their details JSONB.
-- ============================================================================
ALTER TABLE participation_audit
  DROP CONSTRAINT IF EXISTS participation_audit_no_vote_handles_chk;
ALTER TABLE participation_audit
  ADD CONSTRAINT participation_audit_no_vote_handles_chk
  CHECK (
    NOT (COALESCE(details, '{}'::jsonb) ? 'ballot_id')
    AND NOT (COALESCE(details, '{}'::jsonb) ? 'candidate_id')
    AND NOT (COALESCE(details, '{}'::jsonb) ? 'receipt_code')
    AND NOT (COALESCE(details, '{}'::jsonb) ? 'short_code')
    AND NOT (COALESCE(details, '{}'::jsonb) ? 'batch_id')
    AND NOT (COALESCE(details, '{}'::jsonb) ? 'credential')
    AND NOT (COALESCE(details, '{}'::jsonb) ? 'credential_hash')
    AND NOT (COALESCE(details, '{}'::jsonb) ? 'reservation_id')
  );

ALTER TABLE ballot_audit_log
  DROP CONSTRAINT IF EXISTS ballot_audit_log_no_identity_handles_chk;
ALTER TABLE ballot_audit_log
  ADD CONSTRAINT ballot_audit_log_no_identity_handles_chk
  CHECK (
    NOT (COALESCE(details, '{}'::jsonb) ? 'member_id')
    AND NOT (COALESCE(details, '{}'::jsonb) ? 'token_id')
    AND NOT (COALESCE(details, '{}'::jsonb) ? 'short_code')
    AND NOT (COALESCE(details, '{}'::jsonb) ? 'batch_id')
    -- credential_hash / reservation_id are identity-adjacent bridge handles:
    -- they must never land on the anonymous ballot-side audit surface either.
    AND NOT (COALESCE(details, '{}'::jsonb) ? 'credential_hash')
    AND NOT (COALESCE(details, '{}'::jsonb) ? 'reservation_id')
  );

ALTER TABLE vote_audit_log
  DROP CONSTRAINT IF EXISTS vote_audit_log_wave6_no_colocation_chk;
ALTER TABLE vote_audit_log
  ADD CONSTRAINT vote_audit_log_wave6_no_colocation_chk
  CHECK (
    member_id IS NULL
    OR (
      ballot_id IS NULL
      AND candidate_id IS NULL
      AND NOT (COALESCE(details, '{}'::jsonb) ? 'ballot_id')
      AND NOT (COALESCE(details, '{}'::jsonb) ? 'candidate_id')
      AND NOT (COALESCE(details, '{}'::jsonb) ? 'receipt_code')
      AND NOT (COALESCE(details, '{}'::jsonb) ? 'short_code')
      AND NOT (COALESCE(details, '{}'::jsonb) ? 'batch_id')
      AND NOT (COALESCE(details, '{}'::jsonb) ? 'credential')
      AND NOT (COALESCE(details, '{}'::jsonb) ? 'credential_hash')
      AND NOT (COALESCE(details, '{}'::jsonb) ? 'reservation_id')
    )
  );

-- ============================================================================
-- 5. Lazy TTL sweep: release tokens whose digital reservation has expired.
--    Called opportunistically at the top of redeem/cast (no cron). Deletes
--    expired reservation rows and clears the reserving token's reservation marks
--    (is_used was never set at redeem, so no vote is undone -> H2 recoverable).
--    The associated RESERVED credential row is left as a dead, unusable hash
--    (cast requires a live reservation), harmless on the anon plane.
-- ============================================================================
CREATE OR REPLACE FUNCTION private.sweep_expired_digital_reservations()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_expired_token_ids UUID[];
  v_swept INT := 0;
BEGIN
  -- Capture the tokens tied to expired reservations, delete those reservations,
  -- then release the tokens. CASCADE from credential is not involved here (we
  -- delete the reservation directly, leaving the dead credential row).
  WITH expired AS (
    DELETE FROM digital_credential_reservations
    WHERE expires_at <= now()
    RETURNING token_id
  )
  SELECT array_agg(token_id) INTO v_expired_token_ids FROM expired;

  IF v_expired_token_ids IS NOT NULL THEN
    UPDATE tokens t
    SET reserved_at = NULL,
        reserved_channel = NULL,
        reservation_released_at = now()
    WHERE t.id = ANY(v_expired_token_ids)
      AND t.is_used = FALSE
      AND t.reserved_channel = 'DIGITAL';
    GET DIAGNOSTICS v_swept = ROW_COUNT;
  END IF;

  RETURN v_swept;
END;
$$;

REVOKE EXECUTE ON FUNCTION private.sweep_expired_digital_reservations() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.sweep_expired_digital_reservations() TO service_role;

-- ============================================================================
-- 6. Phase 1 — redeem_voting_token (IDENTITY plane).
--    Reserves (does NOT consume) the token and mints a one-time credential.
--    OUT columns are p_-prefixed to avoid RETURNS TABLE shadowing (42702).
-- ============================================================================
CREATE OR REPLACE FUNCTION private.redeem_voting_token(p_token_hash character varying)
 RETURNS TABLE(o_success boolean, o_message text, o_credential text, o_ttl_seconds int)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'extensions'
AS $function$
DECLARE
  v_token_id UUID;
  v_member_id UUID;
  v_is_used BOOLEAN;
  v_expires_at TIMESTAMPTZ;
  v_voided_at TIMESTAMPTZ;
  v_phase election_phase;
  v_voting_end TIMESTAMPTZ;
  v_voting_eligible BOOLEAN;
  v_paper_ballot RECORD;
  v_ttl_minutes INT;
  v_credential TEXT;
  v_credential_hash TEXT;
  v_active_reservation UUID;
BEGIN
  -- Opportunistic lazy sweep so abandoned reservations do not block re-redeem.
  PERFORM private.sweep_expired_digital_reservations();

  SELECT current_phase, voting_end, COALESCE(digital_credential_ttl_minutes, 15)
    INTO v_phase, v_voting_end, v_ttl_minutes
    FROM election_settings WHERE id = 1;

  IF v_phase != 'VOTING' OR (v_voting_end IS NOT NULL AND NOW() > v_voting_end) THEN
    RETURN QUERY SELECT FALSE, 'Voting phase is closed or expired.'::TEXT, NULL::TEXT, NULL::INT;
    RETURN;
  END IF;

  SELECT id, member_id, is_used, expires_at, voided_at
    INTO v_token_id, v_member_id, v_is_used, v_expires_at, v_voided_at
    FROM tokens
   WHERE token_hash = p_token_hash AND type = 'VOTING'
   FOR UPDATE;

  IF v_token_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Invalid or non-existent voting token.'::TEXT, NULL::TEXT, NULL::INT;
    RETURN;
  END IF;

  IF v_voided_at IS NOT NULL THEN
    RETURN QUERY SELECT FALSE, 'This voting token has been voided and reissued. Please use your most recent link.'::TEXT, NULL::TEXT, NULL::INT;
    RETURN;
  END IF;

  IF v_expires_at IS NULL OR v_expires_at <= NOW() THEN
    RETURN QUERY SELECT FALSE, 'This voting token has expired.'::TEXT, NULL::TEXT, NULL::INT;
    RETURN;
  END IF;

  IF v_is_used THEN
    RETURN QUERY SELECT FALSE, 'This token has already been used or reserved for paper voting.'::TEXT, NULL::TEXT, NULL::INT;
    RETURN;
  END IF;

  -- Eligibility gate (defense-in-depth), mirrors submit_anonymous_vote.
  SELECT voting_eligible INTO v_voting_eligible
    FROM members WHERE id = v_member_id AND is_active = TRUE FOR SHARE;
  IF NOT FOUND OR v_voting_eligible IS NOT TRUE THEN
    RETURN QUERY SELECT FALSE, 'Member is not eligible to vote.'::TEXT, NULL::TEXT, NULL::INT;
    RETURN;
  END IF;

  -- Paper-channel exclusivity: an issued/checked-in/voted paper ballot blocks digital.
  SELECT * INTO v_paper_ballot FROM paper_ballots
   WHERE member_id = v_member_id AND status IN ('ISSUED', 'ISSUED_TO_VOTER', 'VOTED')
   FOR SHARE;
  IF FOUND THEN
    RETURN QUERY SELECT FALSE, 'A paper ballot has already been issued for this member.'::TEXT, NULL::TEXT, NULL::INT;
    RETURN;
  END IF;

  -- Reserve-don't-consume single-flight: refuse if a live reservation already
  -- holds this token (post-sweep, so only genuinely live ones remain).
  SELECT id INTO v_active_reservation
    FROM digital_credential_reservations
   WHERE token_id = v_token_id AND expires_at > now()
   FOR UPDATE;
  IF v_active_reservation IS NOT NULL THEN
    RETURN QUERY SELECT FALSE, 'A digital voting credential is already active for this token. Please finish or wait for it to expire.'::TEXT, NULL::TEXT, NULL::INT;
    RETURN;
  END IF;

  -- Mint one-time credential; persist only its SHA-256 hash.
  v_credential := 'DVC-' || encode(gen_random_bytes(24), 'hex');
  v_credential_hash := encode(digest(v_credential, 'sha256'), 'hex');

  INSERT INTO anonymous_digital_credentials (credential_hash, status)
  VALUES (v_credential_hash, 'RESERVED');

  INSERT INTO digital_credential_reservations (credential_hash, token_id, expires_at)
  VALUES (v_credential_hash, v_token_id, now() + (v_ttl_minutes * interval '1 minute'));

  -- RESERVE (not consume) the token: mark the channel, leave is_used FALSE.
  UPDATE tokens
     SET reserved_at = now(),
         reserved_channel = 'DIGITAL',
         reservation_released_at = NULL
   WHERE id = v_token_id;

  RETURN QUERY SELECT TRUE, 'Credential issued.'::TEXT, v_credential, (v_ttl_minutes * 60);
END;
$function$;

REVOKE EXECUTE ON FUNCTION private.redeem_voting_token(character varying) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.redeem_voting_token(character varying) TO service_role;

-- ============================================================================
-- 7. Phase 2 — cast_anonymous_digital_vote (ANON plane).
--    Consumes the credential, inserts the opaque ballot, then atomically consumes
--    the token and HARD-DELETES the transient reservation (severs the bridge).
--    Arg-list = vote handle only; return = vote handles only.
-- ============================================================================
CREATE OR REPLACE FUNCTION private.cast_anonymous_digital_vote(p_credential text, p_candidate_id uuid)
 RETURNS TABLE(o_success boolean, o_message text, o_receipt_code text, o_ballot_id text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'extensions'
AS $function$
DECLARE
  v_credential_hash TEXT;
  v_cred_id UUID;
  v_cred_status VARCHAR(10);
  v_token_id UUID;         -- resolved via the transient bridge (local only)
  v_res_id UUID;
  v_res_expires TIMESTAMPTZ;
  v_token_is_used BOOLEAN;
  v_token_voided TIMESTAMPTZ;
  v_phase election_phase;
  v_voting_end TIMESTAMPTZ;
  v_receipt TEXT;
  v_ballot_id TEXT;
  v_payload TEXT;
  v_attempts INT := 0;
  v_insert_ok BOOLEAN := FALSE;
BEGIN
  -- Opportunistic lazy sweep first (an expired reservation must not be castable).
  PERFORM private.sweep_expired_digital_reservations();

  SELECT current_phase, voting_end INTO v_phase, v_voting_end
    FROM election_settings WHERE id = 1;

  IF v_phase != 'VOTING' OR (v_voting_end IS NOT NULL AND NOW() > v_voting_end) THEN
    RETURN QUERY SELECT FALSE, 'Voting phase is closed or expired.'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  v_credential_hash := encode(digest(p_credential, 'sha256'), 'hex');

  SELECT id, status INTO v_cred_id, v_cred_status
    FROM anonymous_digital_credentials
   WHERE credential_hash = v_credential_hash
   FOR UPDATE;

  IF v_cred_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Invalid voting credential.'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  IF v_cred_status = 'CAST' THEN
    RETURN QUERY SELECT FALSE, 'This credential has already been used to cast a vote.'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Resolve the transient bridge -> token. A missing reservation means the
  -- credential was swept (abandoned) or already cast: fail closed.
  SELECT id, token_id, expires_at INTO v_res_id, v_token_id, v_res_expires
    FROM digital_credential_reservations
   WHERE credential_hash = v_credential_hash
   FOR UPDATE;

  IF v_res_id IS NULL OR v_res_expires <= now() THEN
    RETURN QUERY SELECT FALSE, 'This credential has expired. Please request a new voting link.'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Lock and re-validate the token (defense-in-depth; token still un-consumed).
  SELECT is_used, voided_at INTO v_token_is_used, v_token_voided
    FROM tokens WHERE id = v_token_id FOR UPDATE;

  IF NOT FOUND OR v_token_voided IS NOT NULL OR v_token_is_used IS TRUE THEN
    RETURN QUERY SELECT FALSE, 'Voting entitlement is no longer valid.'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Insert the opaque, identity-free ballot (payload = pure random; no ids/time).
  v_payload := 'DIGITAL:' || encode(gen_random_bytes(32), 'hex');
  v_ballot_id := private.hmac_sign(v_payload);

  WHILE v_attempts < 5 AND NOT v_insert_ok LOOP
    v_receipt := 'VC-' || encode(gen_random_bytes(5), 'hex');
    BEGIN
      INSERT INTO ballots (ballot_id, candidate_id, receipt_code, channel, cast_date)
      VALUES (v_ballot_id, p_candidate_id, v_receipt, 'DIGITAL', CURRENT_DATE);
      v_insert_ok := TRUE;
    EXCEPTION WHEN unique_violation THEN
      v_attempts := v_attempts + 1;
    END;
  END LOOP;

  IF NOT v_insert_ok THEN
    RETURN QUERY SELECT FALSE, 'Could not generate unique receipt code after 5 attempts.'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Mark the credential CAST (anon plane).
  UPDATE anonymous_digital_credentials
     SET status = 'CAST', cast_at = now()
   WHERE id = v_cred_id;

  -- Consume the token and SEVER the bridge in the same tx: hard-delete the
  -- transient reservation. reserved_channel is set to 'DIGITAL' (never 'PAPER').
  UPDATE tokens
     SET is_used = TRUE,
         used_at = now(),
         channel_sent = 'DIGITAL',
         reserved_channel = 'DIGITAL'
   WHERE id = v_token_id;

  DELETE FROM digital_credential_reservations WHERE id = v_res_id;

  RETURN QUERY SELECT TRUE, 'Vote cast successfully.'::TEXT, v_receipt, v_ballot_id;
END;
$function$;

REVOKE EXECUTE ON FUNCTION private.cast_anonymous_digital_vote(text, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.cast_anonymous_digital_vote(text, uuid) TO service_role;

-- ============================================================================
-- 8. Token-only reservation release (ops / voluntary cancel at DB level).
--    Releases a live DIGITAL reservation for a token WITHOUT consuming it, so the
--    voter can redeem again. Identity-plane, token-keyed; never sees credential.
--    (v1 UI does NOT surface a Cancel button; this exists for ops + TTL parity.)
-- ============================================================================
CREATE OR REPLACE FUNCTION private.release_digital_voting_reservation(p_token_hash character varying)
 RETURNS TABLE(o_success boolean, o_message text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'extensions'
AS $function$
DECLARE
  v_token_id UUID;
  v_is_used BOOLEAN;
  v_res_id UUID;
BEGIN
  SELECT id, is_used INTO v_token_id, v_is_used
    FROM tokens WHERE token_hash = p_token_hash AND type = 'VOTING' FOR UPDATE;

  IF v_token_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Invalid or non-existent voting token.'::TEXT;
    RETURN;
  END IF;

  IF v_is_used IS TRUE THEN
    RETURN QUERY SELECT FALSE, 'Token is already consumed; nothing to release.'::TEXT;
    RETURN;
  END IF;

  SELECT id INTO v_res_id
    FROM digital_credential_reservations
   WHERE token_id = v_token_id
   FOR UPDATE;

  IF v_res_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'No active digital reservation for this token.'::TEXT;
    RETURN;
  END IF;

  -- Hard-delete the transient bridge (CASCADE removes the dead credential row).
  DELETE FROM anonymous_digital_credentials
   WHERE credential_hash = (SELECT credential_hash FROM digital_credential_reservations WHERE id = v_res_id);
  -- reservation row is removed by the CASCADE above; ensure token released.
  UPDATE tokens
     SET reserved_at = NULL,
         reserved_channel = NULL,
         reservation_released_at = now()
   WHERE id = v_token_id
     AND is_used = FALSE
     AND reserved_channel = 'DIGITAL';

  RETURN QUERY SELECT TRUE, 'Digital reservation released.'::TEXT;
END;
$function$;

REVOKE EXECUTE ON FUNCTION private.release_digital_voting_reservation(character varying) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.release_digital_voting_reservation(character varying) TO service_role;

-- ============================================================================
-- 9. AMEND reissue_token (change #2): refuse while an active digital reservation
--    exists for the token. Otherwise a reissue could mint a second live link
--    while a credential is still castable -> double vote. Body is the deployed
--    definition verbatim with one guard spliced in after the used/void checks.
-- ============================================================================
CREATE OR REPLACE FUNCTION private.reissue_token(
  p_old_token_id   UUID,
  p_admin_id       UUID,
  p_reason         TEXT,
  p_new_token_hash VARCHAR(64)
) RETURNS TABLE (success BOOLEAN, message TEXT)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_member_id   UUID;
  v_type        token_type;
  v_is_used     BOOLEAN;
  v_voided      TIMESTAMPTZ;
  v_ttl_hours   INT;
  v_new_expires TIMESTAMPTZ;
  v_active_res  UUID;
BEGIN
  -- Sweep first so a stale (expired) reservation does not block a legitimate reissue.
  PERFORM private.sweep_expired_digital_reservations();

  SELECT member_id, type, is_used, voided_at
    INTO v_member_id, v_type, v_is_used, v_voided
    FROM tokens WHERE id = p_old_token_id FOR UPDATE;

  IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Token not found'; RETURN; END IF;
  IF v_is_used THEN RETURN QUERY SELECT FALSE, 'Used token cannot be reissued.'; RETURN; END IF;
  IF v_voided IS NOT NULL THEN RETURN QUERY SELECT FALSE, 'Token already voided.'; RETURN; END IF;

  -- Wave 7: refuse while a live digital credential reservation holds this token.
  SELECT id INTO v_active_res
    FROM digital_credential_reservations
   WHERE token_id = p_old_token_id AND expires_at > now()
   FOR UPDATE;
  IF v_active_res IS NOT NULL THEN
    RETURN QUERY SELECT FALSE, 'Token has an active digital voting credential; release or wait for it to expire before reissuing.';
    RETURN;
  END IF;

  -- Recompute expiry for the token TYPE (do not copy a possibly-stale old value).
  IF v_type = 'VOTING' THEN
    SELECT voting_token_ttl_hours INTO v_ttl_hours FROM election_settings WHERE id = 1;
    v_new_expires := NOW() + (COALESCE(v_ttl_hours, 168) * interval '1 hour');
  ELSE
    v_new_expires := NOW() + interval '24 hours';
  END IF;

  UPDATE tokens SET voided_at = NOW(), void_reason = p_reason WHERE id = p_old_token_id;

  INSERT INTO tokens (member_id, token_hash, type, reissued_from_token_id, expires_at)
  VALUES (v_member_id, p_new_token_hash, v_type, p_old_token_id, v_new_expires);

  RETURN QUERY SELECT TRUE, 'Reissued';
END;
$$;

REVOKE EXECUTE ON FUNCTION private.reissue_token(UUID, UUID, TEXT, VARCHAR) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.reissue_token(UUID, UUID, TEXT, VARCHAR) TO service_role;

-- ============================================================================
-- 10. AMEND submit_anonymous_vote (legacy single-call digital path): FAIL CLOSED
--     when digital_write_mode = 'TWO_PHASE'. Deployed Wave 5 body reproduced
--     verbatim with a single mode gate spliced in at the top; every other guard,
--     lock and grant is preserved. When mode = 'LEGACY' behaviour is unchanged.
-- ============================================================================
CREATE OR REPLACE FUNCTION private.submit_anonymous_vote(p_token_hash character varying, p_candidate_id uuid)
 RETURNS TABLE(success boolean, message text, receipt_code text, ballot_id text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'extensions'
AS $function$
DECLARE
  v_token_id UUID;
  v_member_id UUID;
  v_is_used BOOLEAN;
  v_expires_at TIMESTAMPTZ;
  v_voided_at TIMESTAMPTZ;
  v_phase election_phase;
  v_voting_end TIMESTAMPTZ;
  v_receipt TEXT;
  v_ballot_id TEXT;
  v_payload TEXT;
  v_attempts INT := 0;
  v_insert_ok BOOLEAN := FALSE;
  v_paper_ballot RECORD;
  v_voting_eligible BOOLEAN;
  v_digital_mode VARCHAR(16);
BEGIN
  SELECT current_phase, voting_end, COALESCE(digital_write_mode, 'LEGACY')
    INTO v_phase, v_voting_end, v_digital_mode
    FROM election_settings WHERE id = 1;

  -- Wave 7: legacy single-call digital voting is disabled under two-phase mode.
  IF v_digital_mode = 'TWO_PHASE' THEN
    RETURN QUERY SELECT FALSE, 'Digital voting now uses a two-step secure flow. Please reopen your voting link.'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  IF v_phase != 'VOTING' OR (v_voting_end IS NOT NULL AND NOW() > v_voting_end) THEN
    RETURN QUERY SELECT FALSE, 'Voting phase is closed or expired.'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  SELECT id, member_id, is_used, expires_at, voided_at
    INTO v_token_id, v_member_id, v_is_used, v_expires_at, v_voided_at FROM tokens
  WHERE token_hash = p_token_hash AND type = 'VOTING' FOR UPDATE;

  IF v_token_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Invalid or non-existent voting token.'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  IF v_voided_at IS NOT NULL THEN
    RETURN QUERY SELECT FALSE, 'This voting token has been voided and reissued. Please use your most recent link.'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  IF v_expires_at IS NULL OR v_expires_at <= NOW() THEN
    RETURN QUERY SELECT FALSE, 'This voting token has expired.'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  IF v_is_used THEN
    RETURN QUERY SELECT FALSE, 'This token has already been used or reserved for paper voting.'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  SELECT voting_eligible INTO v_voting_eligible FROM members WHERE id = v_member_id AND is_active = TRUE FOR SHARE;
  IF NOT FOUND OR v_voting_eligible IS NOT TRUE THEN
    RETURN QUERY SELECT FALSE, 'Member is not eligible to vote.'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  SELECT * INTO v_paper_ballot FROM paper_ballots
  WHERE member_id = v_member_id AND status IN ('ISSUED', 'ISSUED_TO_VOTER', 'VOTED')
  FOR SHARE;

  IF FOUND THEN
    RETURN QUERY SELECT FALSE, 'A paper ballot has already been issued for this member.'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  v_payload := 'DIGITAL:' || encode(gen_random_bytes(32), 'hex');
  v_ballot_id := private.hmac_sign(v_payload);

  WHILE v_attempts < 5 AND NOT v_insert_ok LOOP
    v_receipt := 'VC-' || encode(gen_random_bytes(5), 'hex');
    BEGIN
      INSERT INTO ballots (ballot_id, candidate_id, receipt_code, channel, cast_date)
      VALUES (v_ballot_id, p_candidate_id, v_receipt, 'DIGITAL', CURRENT_DATE);
      v_insert_ok := TRUE;
    EXCEPTION WHEN unique_violation THEN
      v_attempts := v_attempts + 1;
    END;
  END LOOP;

  IF NOT v_insert_ok THEN
    RETURN QUERY SELECT FALSE, 'Could not generate unique receipt code after 5 attempts.'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  UPDATE tokens SET is_used = TRUE, used_at = NOW() WHERE id = v_token_id;

  RETURN QUERY SELECT TRUE, 'Vote cast successfully.'::TEXT, v_receipt, v_ballot_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION private.submit_anonymous_vote(character varying, uuid) TO service_role;

-- ============================================================================
-- 11. AMEND spoil_paper_check_in (Wave 6 spoil-after-record hole, changes #4/#5).
--     Decision A+C (user-approved):
--       A  DB FAILS CLOSED: because submit_paper_vote is member-blind and never
--          transitions the identity slip, the DB cannot prove a ballot was NOT
--          recorded. Spoil therefore NO LONGER auto-releases the token. It marks
--          the slip SPOILED for dispute history only. Re-enabling a genuinely
--          unused entitlement goes through reissue_token (dispute role), which
--          now also refuses while a digital reservation is active.
--       C  Operational control (documented in USER_GUIDE): a legitimate desk-time
--          spoil requires the voter to physically surrender the blank; the DB
--          cannot enforce this.
--     Also (#5): require reserved_channel = 'PAPER' so a DIGITAL-reserved token can
--     never be released via the paper spoil path.
-- ============================================================================
CREATE OR REPLACE FUNCTION private.spoil_paper_check_in(
  p_short_code TEXT,
  p_reason TEXT DEFAULT 'Spoiled before record',
  p_admin_id UUID DEFAULT NULL
)
RETURNS TABLE (
  success BOOLEAN,
  message TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_short_code TEXT := upper(trim(p_short_code));
  v_paper RECORD;
  v_token RECORD;
BEGIN
  SELECT *
  INTO v_paper
  FROM paper_ballots
  WHERE short_code = v_short_code
  FOR UPDATE;

  IF v_paper.id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Identity slip not found.'::TEXT;
    RETURN;
  END IF;

  IF v_paper.status <> 'ISSUED_TO_VOTER' THEN
    RETURN QUERY SELECT FALSE, 'Only checked-in, unclosed paper reservations can be spoiled here.'::TEXT;
    RETURN;
  END IF;

  IF v_paper.member_id IS NULL OR v_paper.token_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Identity slip has no member/token reservation to release.'::TEXT;
    RETURN;
  END IF;

  SELECT *
  INTO v_token
  FROM tokens
  WHERE id = v_paper.token_id
    AND member_id = v_paper.member_id
    AND type = 'VOTING'
  FOR UPDATE;

  IF v_token.id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Voting entitlement not found.'::TEXT;
    RETURN;
  END IF;

  -- Change #5: only a genuine PAPER reservation is in scope for this path.
  IF v_token.reserved_channel IS DISTINCT FROM 'PAPER' THEN
    RETURN QUERY SELECT FALSE, 'Reservation is not a PAPER reservation and cannot be spoiled here.'::TEXT;
    RETURN;
  END IF;

  -- Change #4 (FAIL CLOSED): the DB cannot prove the paper ballot was not already
  -- recorded (submit_paper_vote is member-blind and never transitions this slip),
  -- so the token entitlement is NOT auto-released. Mark the slip SPOILED for
  -- dispute history only. Re-enablement, if warranted, goes through reissue_token.
  UPDATE paper_ballots
  SET status = 'SPOILED',
      spoiled_at = now(),
      spoiled_by = p_admin_id,
      invalid_reason = p_reason
  WHERE id = v_paper.id;

  INSERT INTO participation_audit(action, member_id, token_id, channel, event_date, admin_id)
  VALUES ('PAPER_CHECK_IN_SPOILED_PRE_RECORD', v_paper.member_id, v_paper.token_id, 'PAPER', CURRENT_DATE, p_admin_id);

  RETURN QUERY SELECT TRUE, 'Identity slip marked SPOILED for dispute history. The voting entitlement was NOT auto-released; use reissue if a genuinely unused entitlement must be restored.'::TEXT;
END;
$$;

REVOKE EXECUTE ON FUNCTION private.spoil_paper_check_in(TEXT, TEXT, UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.spoil_paper_check_in(TEXT, TEXT, UUID) TO service_role;

-- ============================================================================
-- 11b. AMEND check_in_paper_voter (change #5, cross-channel exclusivity).
--      A digital reservation is reserve-don't-consume (is_used stays FALSE), so the
--      existing is_used guard does NOT catch it. Refuse paper check-in while a live
--      digital credential reservation holds the token. Both this function and
--      redeem_voting_token lock the token row FOR UPDATE first, so the reservation
--      check is race-free without an extra lock. Deployed Wave 6 body reproduced
--      verbatim with a single guard spliced in after the is_used check.
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
    RETURN QUERY SELECT FALSE, 'No active voting entitlement found.'::TEXT, v_member.full_name::TEXT, v_member.member_code::TEXT, v_short_code, NULL::DATE, NULL::TEXT;
    RETURN;
  END IF;

  IF v_token.is_used IS TRUE THEN
    RETURN QUERY SELECT FALSE, 'Voting entitlement already consumed.'::TEXT, v_member.full_name::TEXT, v_member.member_code::TEXT, v_short_code, NULL::DATE, NULL::TEXT;
    RETURN;
  END IF;

  -- Wave 7: refuse while a live digital credential reservation holds this token
  -- (reserve-don't-consume leaves is_used=FALSE, so the guard above misses it).
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

REVOKE EXECUTE ON FUNCTION private.check_in_paper_voter(TEXT, UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.check_in_paper_voter(TEXT, UUID, UUID) TO service_role;

-- ============================================================================
-- 12. Public PostgREST wrappers for the two-phase digital RPCs (private schema is
--     not PostgREST-exposed). Admin/server-only: service_role.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.redeem_voting_token(p_token_hash VARCHAR)
 RETURNS TABLE(o_success boolean, o_message text, o_credential text, o_ttl_seconds int)
 LANGUAGE sql SECURITY DEFINER
 SET search_path = public, private
AS $$
  SELECT * FROM private.redeem_voting_token(p_token_hash);
$$;
REVOKE EXECUTE ON FUNCTION public.redeem_voting_token(VARCHAR) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.redeem_voting_token(VARCHAR) TO service_role;

CREATE OR REPLACE FUNCTION public.cast_anonymous_digital_vote(p_credential TEXT, p_candidate_id UUID)
 RETURNS TABLE(o_success boolean, o_message text, o_receipt_code text, o_ballot_id text)
 LANGUAGE sql SECURITY DEFINER
 SET search_path = public, private
AS $$
  SELECT * FROM private.cast_anonymous_digital_vote(p_credential, p_candidate_id);
$$;
REVOKE EXECUTE ON FUNCTION public.cast_anonymous_digital_vote(TEXT, UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.cast_anonymous_digital_vote(TEXT, UUID) TO service_role;

CREATE OR REPLACE FUNCTION public.release_digital_voting_reservation(p_token_hash VARCHAR)
 RETURNS TABLE(o_success boolean, o_message text)
 LANGUAGE sql SECURITY DEFINER
 SET search_path = public, private
AS $$
  SELECT * FROM private.release_digital_voting_reservation(p_token_hash);
$$;
REVOKE EXECUTE ON FUNCTION public.release_digital_voting_reservation(VARCHAR) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.release_digital_voting_reservation(VARCHAR) TO service_role;

-- ============================================================================
-- END migration_wave7_digital_severance.sql
-- Post-apply operator step (AFTER split app deploy):
--   UPDATE election_settings SET digital_write_mode = 'TWO_PHASE' WHERE id = 1;
-- ============================================================================
