-- ============================================================================
-- migration_wave6_paper_severance.sql
-- v0.13.0 Wave 6: Paper-plane structural severance.
--
-- Purpose:
--   Split paper identity/check-in handles from anonymous ballot handles.
--   No durable row, audit row, RPC argument set, or RPC return set may co-locate
--   member_id with ballots.ballot_id or candidate_id.
--
-- Run AFTER:
--   30. migration_wave5_governance_ledger.sql
--   31. migration_wave5_eligibility_schema.sql
--   32. migration_wave5_eligibility_enforcement.sql
--   33. migration_wave5_eligibility_adjudication.sql
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================================
-- 1. election_settings.paper_ballot_layout
-- Purpose: immutable paper artifact layout choice once voting opens.
-- Enforcement choice: trigger, not RPC guard, because direct table writes and
-- future admin RPCs must be covered by the same DB-level invariant.
-- ============================================================================

ALTER TABLE election_settings
  ADD COLUMN IF NOT EXISTS paper_ballot_layout TEXT NOT NULL DEFAULT 'SEPARATE_SLIP';

ALTER TABLE election_settings
  DROP CONSTRAINT IF EXISTS election_settings_paper_ballot_layout_chk;

ALTER TABLE election_settings
  ADD CONSTRAINT election_settings_paper_ballot_layout_chk
  CHECK (paper_ballot_layout IN ('SEPARATE_SLIP', 'SINGLE_SHEET'));

COMMENT ON COLUMN election_settings.paper_ballot_layout IS
  'Paper layout: SEPARATE_SLIP default, or SINGLE_SHEET opt-in; immutable once VOTING opens.';

CREATE OR REPLACE FUNCTION private.enforce_paper_ballot_layout_immutable()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
BEGIN
  IF NEW.paper_ballot_layout IS DISTINCT FROM OLD.paper_ballot_layout
     AND (
       OLD.current_phase::TEXT IN ('VOTING', 'VOTING_CLOSED', 'COMPLETED')
       OR NEW.current_phase::TEXT IN ('VOTING', 'VOTING_CLOSED', 'COMPLETED')
     ) THEN
    RAISE EXCEPTION 'paper_ballot_layout is immutable once voting opens';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_paper_ballot_layout_immutable ON election_settings;
CREATE TRIGGER trg_paper_ballot_layout_immutable
BEFORE UPDATE OF paper_ballot_layout, current_phase ON election_settings
FOR EACH ROW
EXECUTE FUNCTION private.enforce_paper_ballot_layout_immutable();

-- ============================================================================
-- 2. tokens reservation columns
-- Purpose: reserve/consume the single VOTING entitlement at CHECK-IN.
-- ============================================================================

ALTER TABLE tokens
  ADD COLUMN IF NOT EXISTS reserved_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS reservation_released_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS reserved_channel VARCHAR(20);

CREATE INDEX IF NOT EXISTS idx_tokens_wave6_reserved_channel
  ON tokens(reserved_channel, reserved_at)
  WHERE reserved_at IS NOT NULL;

-- ============================================================================
-- 3. anonymous_paper_blanks
-- Purpose: member-blind anonymous ballot-id pool for anti-stuffing.
-- ============================================================================

CREATE TABLE IF NOT EXISTS anonymous_paper_blanks (
  ballot_id TEXT PRIMARY KEY,
  status TEXT NOT NULL DEFAULT 'AVAILABLE'
    CHECK (status IN ('AVAILABLE', 'CAST', 'VOIDED')),
  generated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  generated_date DATE NOT NULL DEFAULT CURRENT_DATE,
  cast_at TIMESTAMPTZ,
  voided_at TIMESTAMPTZ,
  void_reason TEXT
);

COMMENT ON TABLE anonymous_paper_blanks IS
  'Anonymous paper ballot pool: ballot_id only, no member_id, no short_code, no token_id.';

CREATE INDEX IF NOT EXISTS idx_anonymous_paper_blanks_status
  ON anonymous_paper_blanks(status);

CREATE INDEX IF NOT EXISTS idx_anonymous_paper_blanks_generated_date
  ON anonymous_paper_blanks(generated_date);

ALTER TABLE anonymous_paper_blanks ENABLE ROW LEVEL SECURITY;
GRANT ALL ON anonymous_paper_blanks TO service_role;

-- ============================================================================
-- 4. Split audit tables
-- Purpose: participation audit carries identity only; ballot audit carries vote
-- handles only. Neither table can hold both sides.
-- ============================================================================

CREATE TABLE IF NOT EXISTS participation_audit (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  action TEXT NOT NULL,
  member_id UUID NOT NULL REFERENCES members(id) ON DELETE RESTRICT,
  token_id UUID REFERENCES tokens(id) ON DELETE SET NULL,
  channel VARCHAR(10) NOT NULL CHECK (channel IN ('DIGITAL', 'PAPER')),
  event_date DATE NOT NULL DEFAULT CURRENT_DATE,
  admin_id UUID REFERENCES admin_sessions(id) ON DELETE RESTRICT,
  source_vote_audit_log_id UUID UNIQUE,
  details JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT participation_audit_no_vote_handles_chk
  CHECK (
    NOT (COALESCE(details, '{}'::jsonb) ? 'ballot_id')
    AND NOT (COALESCE(details, '{}'::jsonb) ? 'candidate_id')
    AND NOT (COALESCE(details, '{}'::jsonb) ? 'receipt_code')
    AND NOT (COALESCE(details, '{}'::jsonb) ? 'short_code')
    AND NOT (COALESCE(details, '{}'::jsonb) ? 'batch_id')
  )
);

COMMENT ON TABLE participation_audit IS
  'Identity-side paper/digital participation audit: member + channel + coarse date only.';

CREATE INDEX IF NOT EXISTS idx_participation_audit_member_date
  ON participation_audit(member_id, event_date);

CREATE INDEX IF NOT EXISTS idx_participation_audit_channel_date
  ON participation_audit(channel, event_date);

ALTER TABLE participation_audit ENABLE ROW LEVEL SECURITY;
GRANT ALL ON participation_audit TO service_role;

CREATE TABLE IF NOT EXISTS ballot_audit_log (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  action TEXT NOT NULL,
  ballot_id TEXT,
  channel VARCHAR(10) NOT NULL CHECK (channel IN ('DIGITAL', 'PAPER')),
  event_date DATE NOT NULL DEFAULT CURRENT_DATE,
  old_candidate_id UUID REFERENCES candidates(id),
  new_candidate_id UUID REFERENCES candidates(id),
  admin_id UUID REFERENCES admin_sessions(id) ON DELETE RESTRICT,
  source_vote_audit_log_id UUID UNIQUE,
  details JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT ballot_audit_log_no_identity_handles_chk
  CHECK (
    NOT (COALESCE(details, '{}'::jsonb) ? 'member_id')
    AND NOT (COALESCE(details, '{}'::jsonb) ? 'token_id')
    AND NOT (COALESCE(details, '{}'::jsonb) ? 'short_code')
    AND NOT (COALESCE(details, '{}'::jsonb) ? 'batch_id')
  )
);

COMMENT ON TABLE ballot_audit_log IS
  'Anonymous ballot-side audit: ballot/candidate changes only; no member/token/short_code.';

CREATE INDEX IF NOT EXISTS idx_ballot_audit_log_ballot
  ON ballot_audit_log(ballot_id);

CREATE INDEX IF NOT EXISTS idx_ballot_audit_log_event_date
  ON ballot_audit_log(event_date);

ALTER TABLE ballot_audit_log ENABLE ROW LEVEL SECURITY;
GRANT ALL ON ballot_audit_log TO service_role;

-- ============================================================================
-- 5. Drop old paper RPCs/wrappers before replacing the paper table shape.
-- Purpose: remove dependencies on paper_ballots.ballot_id/candidate_id.
-- ============================================================================

DROP FUNCTION IF EXISTS public.issue_paper_ballot(UUID);
DROP FUNCTION IF EXISTS public.issue_paper_ballot(UUID, UUID);
DROP FUNCTION IF EXISTS private.issue_paper_ballot(UUID);
DROP FUNCTION IF EXISTS private.issue_paper_ballot(UUID, UUID);

DROP FUNCTION IF EXISTS public.issue_preprinted_paper_ballot(TEXT, UUID);
DROP FUNCTION IF EXISTS public.issue_preprinted_paper_ballot(TEXT, UUID, UUID);
DROP FUNCTION IF EXISTS private.issue_preprinted_paper_ballot(TEXT, UUID);
DROP FUNCTION IF EXISTS private.issue_preprinted_paper_ballot(TEXT, UUID, UUID);

DROP FUNCTION IF EXISTS public.generate_blank_paper_ballot_batch(INT);
DROP FUNCTION IF EXISTS public.generate_blank_paper_ballot_batch(INT, UUID);
DROP FUNCTION IF EXISTS private.generate_blank_paper_ballot_batch(INT);
DROP FUNCTION IF EXISTS private.generate_blank_paper_ballot_batch(INT, UUID);

DROP FUNCTION IF EXISTS public.submit_paper_vote(TEXT, UUID);
DROP FUNCTION IF EXISTS public.submit_paper_vote(TEXT, UUID, UUID);
DROP FUNCTION IF EXISTS private.submit_paper_vote(TEXT, UUID);
DROP FUNCTION IF EXISTS private.submit_paper_vote(TEXT, UUID, UUID);

DROP FUNCTION IF EXISTS public.submit_paper_invalid(TEXT, TEXT);
DROP FUNCTION IF EXISTS private.submit_paper_invalid(TEXT, TEXT);

DROP FUNCTION IF EXISTS public.spoil_paper_ballot(TEXT, TEXT);
DROP FUNCTION IF EXISTS public.spoil_paper_ballot(TEXT, TEXT, UUID);
DROP FUNCTION IF EXISTS private.spoil_paper_ballot(TEXT, TEXT);
DROP FUNCTION IF EXISTS private.spoil_paper_ballot(TEXT, TEXT, UUID);

DROP FUNCTION IF EXISTS public.void_unused_paper_ballots(UUID, TEXT);
DROP FUNCTION IF EXISTS public.void_unused_paper_ballots(UUID, TEXT, UUID);
DROP FUNCTION IF EXISTS private.void_unused_paper_ballots(UUID, TEXT);
DROP FUNCTION IF EXISTS private.void_unused_paper_ballots(UUID, TEXT, UUID);

-- ============================================================================
-- 6. Repurpose paper_ballots as identity-plane table.
-- Purpose: keep table name for paper identity/status, but remove ballot_id and
-- candidate_id structurally.
-- ============================================================================

DO $$
BEGIN
  IF to_regclass('public.paper_ballots') IS NOT NULL
     AND EXISTS (
       SELECT 1
       FROM information_schema.columns
       WHERE table_schema = 'public'
         AND table_name = 'paper_ballots'
         AND column_name = 'ballot_id'
     ) THEN
    DROP TABLE IF EXISTS paper_ballots_wave6_legacy;
    ALTER TABLE paper_ballots RENAME TO paper_ballots_wave6_legacy;
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS paper_ballots (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  short_code VARCHAR(14) UNIQUE NOT NULL,
  member_id UUID REFERENCES members(id) ON DELETE RESTRICT,
  token_id UUID REFERENCES tokens(id) ON DELETE SET NULL,
  status paper_ballot_status NOT NULL DEFAULT 'AVAILABLE',
  checked_in_at TIMESTAMPTZ,
  checked_in_date DATE,
  checked_in_by UUID REFERENCES admin_sessions(id) ON DELETE RESTRICT,
  spoiled_at TIMESTAMPTZ,
  spoiled_by UUID REFERENCES admin_sessions(id) ON DELETE RESTRICT,
  voided_at TIMESTAMPTZ,
  voided_by UUID REFERENCES admin_sessions(id) ON DELETE RESTRICT,
  invalid_reason TEXT,
  void_reason TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE paper_ballots IS
  'Paper identity/check-in plane: short_code + member/token status only; never stores anonymous ballot_id or candidate_id.';

CREATE INDEX IF NOT EXISTS idx_paper_ballots_member
  ON paper_ballots(member_id);

CREATE INDEX IF NOT EXISTS idx_paper_ballots_token
  ON paper_ballots(token_id);

CREATE INDEX IF NOT EXISTS idx_paper_ballots_short_code
  ON paper_ballots(short_code);

CREATE INDEX IF NOT EXISTS idx_paper_ballots_status
  ON paper_ballots(status);

CREATE UNIQUE INDEX IF NOT EXISTS idx_paper_ballots_one_checked_in_member
  ON paper_ballots(member_id)
  WHERE member_id IS NOT NULL
    AND status IN ('ISSUED_TO_VOTER', 'VOTED');

CREATE UNIQUE INDEX IF NOT EXISTS idx_paper_ballots_one_checked_in_token
  ON paper_ballots(token_id)
  WHERE token_id IS NOT NULL
    AND status IN ('ISSUED_TO_VOTER', 'VOTED');

ALTER TABLE paper_ballots ENABLE ROW LEVEL SECURITY;
GRANT ALL ON paper_ballots TO service_role;

-- Migrate legacy paper participation history into the clean identity table.
INSERT INTO paper_ballots (
  short_code,
  member_id,
  token_id,
  status,
  checked_in_at,
  checked_in_date,
  spoiled_at,
  voided_at,
  invalid_reason,
  void_reason,
  created_at
)
SELECT
  l.short_code,
  l.member_id,
  t.id AS token_id,
  CASE
    WHEN l.status::TEXT = 'AVAILABLE' THEN 'AVAILABLE'::paper_ballot_status
    WHEN l.status::TEXT IN ('ISSUED', 'ISSUED_TO_VOTER') THEN 'ISSUED_TO_VOTER'::paper_ballot_status
    WHEN l.status::TEXT = 'VOTED' THEN 'VOTED'::paper_ballot_status
    WHEN l.status::TEXT IN ('SPOILED', 'MISSING') THEN 'SPOILED'::paper_ballot_status
    WHEN l.status::TEXT = 'VOIDED_UNUSED' THEN 'VOIDED_UNUSED'::paper_ballot_status
    ELSE 'SPOILED'::paper_ballot_status
  END AS status,
  COALESCE(l.issued_to_voter_at, l.issued_at, l.created_at) AS checked_in_at,
  COALESCE(l.issued_to_voter_at, l.issued_at, l.created_at)::DATE AS checked_in_date,
  l.spoiled_at,
  l.voided_at,
  l.invalid_reason,
  l.void_reason,
  l.created_at
FROM paper_ballots_wave6_legacy l
LEFT JOIN LATERAL (
  SELECT tok.id
  FROM tokens tok
  WHERE tok.member_id = l.member_id
    AND tok.type = 'VOTING'
    AND tok.voided_at IS NULL
  ORDER BY tok.created_at DESC, tok.id
  LIMIT 1
) t ON TRUE
WHERE to_regclass('public.paper_ballots_wave6_legacy') IS NOT NULL
  AND l.short_code IS NOT NULL
ON CONFLICT (short_code) DO NOTHING;

-- Preserve already-cast legacy anonymous paper ballots as CAST blanks only.
-- Do not carry over old uncast matched ballot IDs.
INSERT INTO anonymous_paper_blanks (
  ballot_id,
  status,
  generated_at,
  generated_date,
  cast_at
)
SELECT
  l.ballot_id,
  'CAST',
  COALESCE(l.created_at, now()),
  COALESCE(l.created_at, now())::DATE,
  COALESCE(l.voted_at, l.created_at, now())
FROM paper_ballots_wave6_legacy l
JOIN ballots b ON b.ballot_id = l.ballot_id
WHERE to_regclass('public.paper_ballots_wave6_legacy') IS NOT NULL
  AND l.ballot_id IS NOT NULL
  AND l.status::TEXT = 'VOTED'
ON CONFLICT (ballot_id) DO NOTHING;

-- Remove the legacy co-location table entirely.
DROP TABLE IF EXISTS paper_ballots_wave6_legacy CASCADE;

-- ============================================================================
-- 7. Retro-scrub legacy vote_audit_log.
-- Purpose: preserve participation and ballot audit history in split tables,
-- then strip member+ballot/candidate co-location from the legacy table.
-- ============================================================================

DROP TRIGGER IF EXISTS trg_vote_audit_log_immutable ON vote_audit_log;
DROP TRIGGER IF EXISTS trg_vote_audit_log_no_colocation ON vote_audit_log;

INSERT INTO participation_audit (
  action,
  member_id,
  channel,
  event_date,
  admin_id,
  source_vote_audit_log_id,
  details,
  created_at
)
SELECT
  v.action,
  v.member_id,
  CASE
    WHEN v.action ILIKE '%PAPER%' THEN 'PAPER'
    ELSE 'DIGITAL'
  END AS channel,
  COALESCE(v.created_at, now())::DATE,
  v.admin_id,
  v.id,
  '{}'::jsonb,
  COALESCE(v.created_at, now())
FROM vote_audit_log v
WHERE v.member_id IS NOT NULL
ON CONFLICT (source_vote_audit_log_id) DO NOTHING;

INSERT INTO ballot_audit_log (
  action,
  ballot_id,
  channel,
  event_date,
  new_candidate_id,
  admin_id,
  source_vote_audit_log_id,
  details,
  created_at
)
SELECT
  v.action,
  v.ballot_id,
  CASE
    WHEN v.action ILIKE '%PAPER%' THEN 'PAPER'
    ELSE 'DIGITAL'
  END AS channel,
  COALESCE(v.created_at, now())::DATE,
  v.candidate_id,
  v.admin_id,
  v.id,
  '{}'::jsonb,
  COALESCE(v.created_at, now())
FROM vote_audit_log v
WHERE v.ballot_id IS NOT NULL
   OR v.candidate_id IS NOT NULL
ON CONFLICT (source_vote_audit_log_id) DO NOTHING;

UPDATE vote_audit_log
SET
  ballot_id = NULL,
  candidate_id = NULL,
  details = COALESCE(details, '{}'::jsonb)
    - 'ballot_id'
    - 'candidate_id'
    - 'receipt_code'
    - 'short_code'
    - 'batch_id'
WHERE member_id IS NOT NULL;

UPDATE vote_audit_log
SET
  member_id = NULL,
  details = COALESCE(details, '{}'::jsonb)
    - 'member_id'
    - 'token_id'
    - 'short_code'
    - 'batch_id'
WHERE member_id IS NOT NULL
  AND (ballot_id IS NOT NULL OR candidate_id IS NOT NULL);

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
    )
  );

CREATE OR REPLACE FUNCTION private.reject_vote_audit_log_colocation()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
BEGIN
  IF NEW.member_id IS NOT NULL
     AND (
       NEW.ballot_id IS NOT NULL
       OR NEW.candidate_id IS NOT NULL
       OR COALESCE(NEW.details, '{}'::jsonb) ? 'ballot_id'
       OR COALESCE(NEW.details, '{}'::jsonb) ? 'candidate_id'
       OR COALESCE(NEW.details, '{}'::jsonb) ? 'receipt_code'
       OR COALESCE(NEW.details, '{}'::jsonb) ? 'short_code'
       OR COALESCE(NEW.details, '{}'::jsonb) ? 'batch_id'
     ) THEN
    RAISE EXCEPTION 'vote_audit_log may not co-locate member_id with ballot/candidate/receipt/short_code handles';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_vote_audit_log_no_colocation
BEFORE INSERT OR UPDATE ON vote_audit_log
FOR EACH ROW
EXECUTE FUNCTION private.reject_vote_audit_log_colocation();

-- Rebuild SEC-18 hash chain after intentional scrub if hash columns/functions exist.
DO $$
DECLARE
  r RECORD;
  v_prev_hash CHAR(64) := NULL;
  v_hash CHAR(64);
BEGIN
  IF EXISTS (
       SELECT 1 FROM information_schema.columns
       WHERE table_schema = 'public'
         AND table_name = 'vote_audit_log'
         AND column_name = 'record_hash'
     )
     AND to_regprocedure('public.compute_audit_log_hash(text,uuid,uuid,jsonb,character,timestamp with time zone)') IS NOT NULL
  THEN
    FOR r IN
      SELECT id, action, admin_id, member_id, details, created_at
      FROM vote_audit_log
      ORDER BY created_at, id
    LOOP
      v_hash := compute_audit_log_hash(
        r.action,
        r.admin_id,
        r.member_id,
        COALESCE(r.details, '{}'::jsonb),
        v_prev_hash,
        r.created_at
      );

      UPDATE vote_audit_log
      SET previous_hash = v_prev_hash,
          record_hash = v_hash
      WHERE id = r.id;

      v_prev_hash := v_hash;
    END LOOP;
  END IF;
END $$;

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

CREATE TRIGGER trg_vote_audit_log_immutable
BEFORE UPDATE OR DELETE ON vote_audit_log
FOR EACH ROW
EXECUTE FUNCTION private.reject_vote_audit_log_mutation();

-- ============================================================================
-- 8. Helpers
-- ============================================================================

CREATE OR REPLACE FUNCTION private.generate_opaque_paper_ballot_id()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_payload TEXT;
BEGIN
  v_payload := 'PAPER:' || encode(gen_random_bytes(32), 'hex');
  RETURN private.hmac_sign(v_payload);
END;
$$;

COMMENT ON FUNCTION private.generate_opaque_paper_ballot_id() IS
  'Generates opaque HMAC-signed PAPER ballot_id: PAPER:<32-byte-random-hex>.<sig>.';

-- ============================================================================
-- 9. CHECK-IN RPC
-- Purpose: identity moment; member + short_code only; no ballot_id/candidate.
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
BEGIN
  IF v_short_code IS NULL OR v_short_code = '' THEN
    RETURN QUERY SELECT FALSE, 'short_code is required.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::DATE, NULL::TEXT;
    RETURN;
  END IF;

  SELECT id, member_code, full_name, voting_eligible
  INTO v_member
  FROM members
  WHERE id = p_member_id
    AND is_active = TRUE
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
  WHERE short_code = v_short_code
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
-- 10. On-demand identity-slip issuance
-- Purpose: safe replacement for old issue_paper_ballot; returns identity data
-- only. It does NOT create or return an anonymous ballot_id.
-- ============================================================================

CREATE OR REPLACE FUNCTION private.issue_paper_ballot(
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
  v_short_code TEXT;
  v_attempts INTEGER := 0;
  v_inserted BOOLEAN := FALSE;
BEGIN
  WHILE v_attempts < 10 AND NOT v_inserted LOOP
    v_short_code := private.generate_short_code();

    BEGIN
      INSERT INTO paper_ballots(short_code, status)
      VALUES (v_short_code, 'AVAILABLE');
      v_inserted := TRUE;
    EXCEPTION WHEN unique_violation THEN
      v_attempts := v_attempts + 1;
    END;
  END LOOP;

  IF NOT v_inserted THEN
    RETURN QUERY SELECT FALSE, 'Could not generate unique identity-slip short code.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::DATE, NULL::TEXT;
    RETURN;
  END IF;

  RETURN QUERY
  SELECT *
  FROM private.check_in_paper_voter(v_short_code, p_member_id, p_admin_id);
END;
$$;

-- ============================================================================
-- 11. Anonymous blank ballot pool generation
-- Purpose: anonymous moment; no member/short_code/token involved or returned.
-- ============================================================================

CREATE OR REPLACE FUNCTION private.generate_anonymous_blank_ballot_pool(
  p_count INT,
  p_admin_id UUID DEFAULT NULL
)
RETURNS TABLE (
  success BOOLEAN,
  message TEXT,
  generated_count INT,
  ballot_ids TEXT[]
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_ballot_id TEXT;
  v_ballot_ids TEXT[] := ARRAY[]::TEXT[];
  v_inserted INTEGER := 0;
  v_attempts INTEGER;
  i INTEGER;
BEGIN
  IF p_count IS NULL OR p_count < 1 OR p_count > 1000 THEN
    RETURN QUERY SELECT FALSE, 'Count must be between 1 and 1000.'::TEXT, 0, ARRAY[]::TEXT[];
    RETURN;
  END IF;

  FOR i IN 1..p_count LOOP
    v_attempts := 0;

    LOOP
      v_ballot_id := private.generate_opaque_paper_ballot_id();

      BEGIN
        INSERT INTO anonymous_paper_blanks(ballot_id, status)
        VALUES (v_ballot_id, 'AVAILABLE');

        INSERT INTO ballot_audit_log(action, ballot_id, channel, event_date, admin_id)
        VALUES ('ANONYMOUS_PAPER_BLANK_GENERATED', v_ballot_id, 'PAPER', CURRENT_DATE, p_admin_id);

        v_ballot_ids := array_append(v_ballot_ids, v_ballot_id);
        v_inserted := v_inserted + 1;
        EXIT;
      EXCEPTION WHEN unique_violation THEN
        v_attempts := v_attempts + 1;
        IF v_attempts >= 10 THEN
          RAISE EXCEPTION 'Could not generate unique anonymous paper ballot_id';
        END IF;
      END;
    END LOOP;
  END LOOP;

  RETURN QUERY SELECT TRUE, 'Anonymous paper ballot pool generated.'::TEXT, v_inserted, v_ballot_ids;
END;
$$;

-- ============================================================================
-- 12. Record paper vote
-- Purpose: anonymous record moment; ballot_id + candidate only; no member lookup.
-- ============================================================================

CREATE OR REPLACE FUNCTION private.submit_paper_vote(
  p_ballot_id TEXT,
  p_candidate_id UUID,
  p_admin_id UUID DEFAULT NULL
)
RETURNS TABLE (
  success BOOLEAN,
  message TEXT,
  receipt_code TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_payload TEXT;
  v_blank RECORD;
  v_candidate_exists BOOLEAN;
  v_receipt TEXT;
  v_attempts INTEGER := 0;
  v_insert_ok BOOLEAN := FALSE;
  v_updated INTEGER := 0;
BEGIN
  v_payload := private.hmac_verify(p_ballot_id);

  IF v_payload IS NULL OR v_payload NOT LIKE 'PAPER:%' THEN
    RETURN QUERY SELECT FALSE, 'Invalid paper ballot ID.'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  SELECT *
  INTO v_blank
  FROM anonymous_paper_blanks
  WHERE ballot_id = p_ballot_id
  FOR UPDATE;

  IF v_blank.ballot_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Paper ballot is not from the anonymous blank pool.'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  IF v_blank.status <> 'AVAILABLE' THEN
    RETURN QUERY SELECT FALSE, 'Paper ballot has already been cast or voided.'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM candidates
    WHERE id = p_candidate_id
      AND is_active = TRUE
  )
  INTO v_candidate_exists;

  IF v_candidate_exists IS NOT TRUE THEN
    RETURN QUERY SELECT FALSE, 'Candidate not found or inactive.'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  IF EXISTS (SELECT 1 FROM ballots WHERE ballot_id = p_ballot_id) THEN
    RETURN QUERY SELECT FALSE, 'Paper ballot already exists in anonymous ballots.'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  WHILE v_attempts < 10 AND NOT v_insert_ok LOOP
    v_receipt := 'PB-' || encode(gen_random_bytes(5), 'hex');

    BEGIN
      INSERT INTO ballots(ballot_id, candidate_id, receipt_code, channel, cast_date)
      VALUES (p_ballot_id, p_candidate_id, v_receipt, 'PAPER', CURRENT_DATE);

      v_insert_ok := TRUE;
    EXCEPTION WHEN unique_violation THEN
      v_attempts := v_attempts + 1;
    END;
  END LOOP;

  IF NOT v_insert_ok THEN
    RETURN QUERY SELECT FALSE, 'Could not generate unique paper receipt code.'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  UPDATE anonymous_paper_blanks
  SET status = 'CAST',
      cast_at = now()
  WHERE ballot_id = p_ballot_id
    AND status = 'AVAILABLE';

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  IF v_updated <> 1 THEN
    RAISE EXCEPTION 'Failed to mark anonymous paper blank as CAST';
  END IF;

  INSERT INTO ballot_audit_log(action, ballot_id, channel, event_date, new_candidate_id, admin_id)
  VALUES ('PAPER_BALLOT_CAST', p_ballot_id, 'PAPER', CURRENT_DATE, p_candidate_id, p_admin_id);

  RETURN QUERY SELECT TRUE, 'Paper vote recorded.'::TEXT, v_receipt;
END;
$$;

-- ============================================================================
-- 13. Correction RPC
-- Purpose: possession-only ballot correction; edits ballots by ballot_id only.
-- ============================================================================

CREATE OR REPLACE FUNCTION private.correct_paper_vote(
  p_ballot_id TEXT,
  p_new_candidate_id UUID,
  p_admin_id UUID DEFAULT NULL,
  p_reason TEXT DEFAULT NULL
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
  v_payload TEXT;
  v_ballot RECORD;
  v_candidate_exists BOOLEAN;
BEGIN
  v_payload := private.hmac_verify(p_ballot_id);

  IF v_payload IS NULL OR v_payload NOT LIKE 'PAPER:%' THEN
    RETURN QUERY SELECT FALSE, 'Invalid paper ballot ID.'::TEXT;
    RETURN;
  END IF;

  SELECT *
  INTO v_ballot
  FROM ballots
  WHERE ballot_id = p_ballot_id
    AND channel = 'PAPER'
  FOR UPDATE;

  IF v_ballot.id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Paper ballot not found.'::TEXT;
    RETURN;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM candidates
    WHERE id = p_new_candidate_id
      AND is_active = TRUE
  )
  INTO v_candidate_exists;

  IF v_candidate_exists IS NOT TRUE THEN
    RETURN QUERY SELECT FALSE, 'Candidate not found or inactive.'::TEXT;
    RETURN;
  END IF;

  UPDATE ballots
  SET candidate_id = p_new_candidate_id
  WHERE id = v_ballot.id;

  INSERT INTO ballot_audit_log(
    action,
    ballot_id,
    channel,
    event_date,
    old_candidate_id,
    new_candidate_id,
    admin_id,
    details
  )
  VALUES (
    'PAPER_BALLOT_CORRECTED',
    p_ballot_id,
    'PAPER',
    CURRENT_DATE,
    v_ballot.candidate_id,
    p_new_candidate_id,
    p_admin_id,
    jsonb_build_object('reason', COALESCE(p_reason, 'not specified'))
  );

  RETURN QUERY SELECT TRUE, 'Paper vote corrected.'::TEXT;
END;
$$;

-- ============================================================================
-- 14. Spoil before record: identity-slip keyed.
-- Purpose: releases only an unrecorded PAPER check-in reservation; no ballot_id.
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

  IF v_token.is_used IS TRUE AND v_token.channel_sent = 'PAPER' THEN
    UPDATE tokens
    SET is_used = FALSE,
        used_at = NULL,
        reserved_at = NULL,
        reserved_channel = NULL,
        reservation_released_at = now()
    WHERE id = v_token.id
      AND is_used = TRUE
      AND channel_sent = 'PAPER';
  ELSE
    RETURN QUERY SELECT FALSE, 'Reservation is not a releasable PAPER reservation.'::TEXT;
    RETURN;
  END IF;

  UPDATE paper_ballots
  SET status = 'SPOILED',
      spoiled_at = now(),
      spoiled_by = p_admin_id,
      invalid_reason = p_reason
  WHERE id = v_paper.id;

  INSERT INTO participation_audit(action, member_id, token_id, channel, event_date, admin_id)
  VALUES ('PAPER_CHECK_IN_SPOILED_PRE_RECORD', v_paper.member_id, v_paper.token_id, 'PAPER', CURRENT_DATE, p_admin_id);

  RETURN QUERY SELECT TRUE, 'Paper check-in spoiled and entitlement released.'::TEXT;
END;
$$;

-- ============================================================================
-- 15. Spoil/void anonymous blank by ballot_id.
-- Purpose: anonymous-pool voiding only; never releases a member token.
-- ============================================================================

CREATE OR REPLACE FUNCTION private.void_anonymous_paper_blank(
  p_ballot_id TEXT,
  p_reason TEXT DEFAULT 'Voided anonymous blank',
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
  v_payload TEXT;
  v_blank RECORD;
BEGIN
  v_payload := private.hmac_verify(p_ballot_id);

  IF v_payload IS NULL OR v_payload NOT LIKE 'PAPER:%' THEN
    RETURN QUERY SELECT FALSE, 'Invalid paper ballot ID.'::TEXT;
    RETURN;
  END IF;

  SELECT *
  INTO v_blank
  FROM anonymous_paper_blanks
  WHERE ballot_id = p_ballot_id
  FOR UPDATE;

  IF v_blank.ballot_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Anonymous paper blank not found.'::TEXT;
    RETURN;
  END IF;

  IF v_blank.status <> 'AVAILABLE' THEN
    RETURN QUERY SELECT FALSE, 'Only AVAILABLE anonymous blanks can be voided; cast ballots require correction.'::TEXT;
    RETURN;
  END IF;

  UPDATE anonymous_paper_blanks
  SET status = 'VOIDED',
      voided_at = now(),
      void_reason = p_reason
  WHERE ballot_id = p_ballot_id
    AND status = 'AVAILABLE';

  INSERT INTO ballot_audit_log(action, ballot_id, channel, event_date, admin_id, details)
  VALUES ('ANONYMOUS_PAPER_BLANK_VOIDED', p_ballot_id, 'PAPER', CURRENT_DATE, p_admin_id, jsonb_build_object('reason', p_reason));

  RETURN QUERY SELECT TRUE, 'Anonymous paper blank voided.'::TEXT;
END;
$$;

-- ============================================================================
-- 16. Void unused anonymous pool
-- Purpose: bulk-close uncast anonymous blanks; member-blind.
-- ============================================================================

CREATE OR REPLACE FUNCTION private.void_unused_anonymous_paper_blanks(
  p_admin_id UUID DEFAULT NULL,
  p_reason TEXT DEFAULT 'Election closed - voiding unused anonymous paper blanks'
)
RETURNS TABLE (
  voided_count INTEGER,
  message TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_count INTEGER := 0;
BEGIN
  UPDATE anonymous_paper_blanks
  SET status = 'VOIDED',
      voided_at = now(),
      void_reason = p_reason
  WHERE status = 'AVAILABLE';

  GET DIAGNOSTICS v_count = ROW_COUNT;

  INSERT INTO ballot_audit_log(action, channel, event_date, admin_id, details)
  VALUES ('ANONYMOUS_PAPER_POOL_VOID_UNUSED', 'PAPER', CURRENT_DATE, p_admin_id, jsonb_build_object('voided_count', v_count));

  RETURN QUERY SELECT v_count, 'Unused anonymous paper blanks voided.'::TEXT;
END;
$$;

-- ============================================================================
-- 17. Pool reconciliation
-- Purpose: aggregate-only paper reconciliation; no member-ballot joins.
-- ============================================================================

CREATE OR REPLACE FUNCTION private.paper_pool_reconciliation()
RETURNS TABLE (
  checked_in_count BIGINT,
  spoiled_check_in_count BIGINT,
  available_blank_count BIGINT,
  cast_blank_count BIGINT,
  voided_blank_count BIGINT,
  paper_ballot_count BIGINT
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, private
AS $$
  SELECT
    (SELECT count(*) FROM paper_ballots WHERE status = 'ISSUED_TO_VOTER') AS checked_in_count,
    (SELECT count(*) FROM paper_ballots WHERE status = 'SPOILED') AS spoiled_check_in_count,
    (SELECT count(*) FROM anonymous_paper_blanks WHERE status = 'AVAILABLE') AS available_blank_count,
    (SELECT count(*) FROM anonymous_paper_blanks WHERE status = 'CAST') AS cast_blank_count,
    (SELECT count(*) FROM anonymous_paper_blanks WHERE status = 'VOIDED') AS voided_blank_count,
    (SELECT count(*) FROM ballots WHERE channel = 'PAPER') AS paper_ballot_count;
$$;

-- ============================================================================
-- 18. Deprecated fail-closed compatibility functions
-- Purpose: old matched-pair paper APIs must not silently keep working.
-- ============================================================================

CREATE OR REPLACE FUNCTION private.issue_preprinted_paper_ballot(
  p_ballot_id TEXT,
  p_member_id UUID,
  p_admin_id UUID DEFAULT NULL
)
RETURNS TABLE (
  success BOOLEAN,
  message TEXT,
  ballot_id TEXT,
  short_code TEXT,
  qr_svg TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
BEGIN
  RETURN QUERY SELECT
    FALSE,
    'issue_preprinted_paper_ballot is superseded by check_in_paper_voter + anonymous blank pool.'::TEXT,
    NULL::TEXT,
    NULL::TEXT,
    NULL::TEXT;
END;
$$;

CREATE OR REPLACE FUNCTION private.generate_blank_paper_ballot_batch(
  p_count INT,
  p_admin_id UUID DEFAULT NULL
)
RETURNS TABLE (
  batch_id UUID,
  generated_count INT,
  message TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
BEGIN
  RAISE EXCEPTION 'generate_blank_paper_ballot_batch is superseded by generate_anonymous_blank_ballot_pool';
END;
$$;

CREATE OR REPLACE FUNCTION private.spoil_paper_ballot(
  p_ballot_id TEXT,
  p_reason TEXT,
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
BEGIN
  RETURN QUERY SELECT
    FALSE,
    'spoil_paper_ballot is superseded by spoil_paper_check_in or void_anonymous_paper_blank.'::TEXT;
END;
$$;

CREATE OR REPLACE FUNCTION private.submit_paper_invalid(
  p_ballot_id TEXT,
  p_reason TEXT
)
RETURNS TABLE (
  success BOOLEAN,
  message TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
BEGIN
  RETURN QUERY SELECT
    FALSE,
    'submit_paper_invalid is superseded by spoil_paper_check_in or void_anonymous_paper_blank.'::TEXT;
END;
$$;

CREATE OR REPLACE FUNCTION private.void_unused_paper_ballots(
  p_batch_id UUID DEFAULT NULL,
  p_reason TEXT DEFAULT 'Election closed - voiding unused anonymous paper blanks',
  p_admin_id UUID DEFAULT NULL
)
RETURNS TABLE (
  voided_count INT,
  message TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
BEGIN
  RETURN QUERY
  SELECT *
  FROM private.void_unused_anonymous_paper_blanks(p_admin_id, p_reason);
END;
$$;

-- ============================================================================
-- 19. Public PostgREST wrappers
-- Purpose: expose only service-role-callable wrappers for Next.js admin routes.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.check_in_paper_voter(
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
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, private
AS $$
  SELECT * FROM private.check_in_paper_voter(p_short_code, p_member_id, p_admin_id);
$$;

CREATE OR REPLACE FUNCTION public.issue_paper_ballot(
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
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, private
AS $$
  SELECT * FROM private.issue_paper_ballot(p_member_id, p_admin_id);
$$;

CREATE OR REPLACE FUNCTION public.generate_anonymous_blank_ballot_pool(
  p_count INT,
  p_admin_id UUID DEFAULT NULL
)
RETURNS TABLE (
  success BOOLEAN,
  message TEXT,
  generated_count INT,
  ballot_ids TEXT[]
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, private
AS $$
  SELECT * FROM private.generate_anonymous_blank_ballot_pool(p_count, p_admin_id);
$$;

CREATE OR REPLACE FUNCTION public.submit_paper_vote(
  p_ballot_id TEXT,
  p_candidate_id UUID,
  p_admin_id UUID DEFAULT NULL
)
RETURNS TABLE (
  success BOOLEAN,
  message TEXT,
  receipt_code TEXT
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, private
AS $$
  SELECT * FROM private.submit_paper_vote(p_ballot_id, p_candidate_id, p_admin_id);
$$;

CREATE OR REPLACE FUNCTION public.correct_paper_vote(
  p_ballot_id TEXT,
  p_new_candidate_id UUID,
  p_admin_id UUID DEFAULT NULL,
  p_reason TEXT DEFAULT NULL
)
RETURNS TABLE (
  success BOOLEAN,
  message TEXT
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, private
AS $$
  SELECT * FROM private.correct_paper_vote(p_ballot_id, p_new_candidate_id, p_admin_id, p_reason);
$$;

CREATE OR REPLACE FUNCTION public.spoil_paper_check_in(
  p_short_code TEXT,
  p_reason TEXT DEFAULT 'Spoiled before record',
  p_admin_id UUID DEFAULT NULL
)
RETURNS TABLE (
  success BOOLEAN,
  message TEXT
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, private
AS $$
  SELECT * FROM private.spoil_paper_check_in(p_short_code, p_reason, p_admin_id);
$$;

CREATE OR REPLACE FUNCTION public.void_anonymous_paper_blank(
  p_ballot_id TEXT,
  p_reason TEXT DEFAULT 'Voided anonymous blank',
  p_admin_id UUID DEFAULT NULL
)
RETURNS TABLE (
  success BOOLEAN,
  message TEXT
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, private
AS $$
  SELECT * FROM private.void_anonymous_paper_blank(p_ballot_id, p_reason, p_admin_id);
$$;

CREATE OR REPLACE FUNCTION public.void_unused_anonymous_paper_blanks(
  p_admin_id UUID DEFAULT NULL,
  p_reason TEXT DEFAULT 'Election closed - voiding unused anonymous paper blanks'
)
RETURNS TABLE (
  voided_count INTEGER,
  message TEXT
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, private
AS $$
  SELECT * FROM private.void_unused_anonymous_paper_blanks(p_admin_id, p_reason);
$$;

CREATE OR REPLACE FUNCTION public.paper_pool_reconciliation()
RETURNS TABLE (
  checked_in_count BIGINT,
  spoiled_check_in_count BIGINT,
  available_blank_count BIGINT,
  cast_blank_count BIGINT,
  voided_blank_count BIGINT,
  paper_ballot_count BIGINT
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, private
AS $$
  SELECT * FROM private.paper_pool_reconciliation();
$$;

-- Deprecated public wrappers remain fail-closed / safe.
CREATE OR REPLACE FUNCTION public.issue_preprinted_paper_ballot(
  p_ballot_id TEXT,
  p_member_id UUID,
  p_admin_id UUID DEFAULT NULL
)
RETURNS TABLE (
  success BOOLEAN,
  message TEXT,
  ballot_id TEXT,
  short_code TEXT,
  qr_svg TEXT
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, private
AS $$
  SELECT * FROM private.issue_preprinted_paper_ballot(p_ballot_id, p_member_id, p_admin_id);
$$;

CREATE OR REPLACE FUNCTION public.generate_blank_paper_ballot_batch(
  p_count INT,
  p_admin_id UUID DEFAULT NULL
)
RETURNS TABLE (
  batch_id UUID,
  generated_count INT,
  message TEXT
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, private
AS $$
  SELECT * FROM private.generate_blank_paper_ballot_batch(p_count, p_admin_id);
$$;

CREATE OR REPLACE FUNCTION public.spoil_paper_ballot(
  p_ballot_id TEXT,
  p_reason TEXT,
  p_admin_id UUID DEFAULT NULL
)
RETURNS TABLE (
  success BOOLEAN,
  message TEXT
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, private
AS $$
  SELECT * FROM private.spoil_paper_ballot(p_ballot_id, p_reason, p_admin_id);
$$;

CREATE OR REPLACE FUNCTION public.submit_paper_invalid(
  p_ballot_id TEXT,
  p_reason TEXT
)
RETURNS TABLE (
  success BOOLEAN,
  message TEXT
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, private
AS $$
  SELECT * FROM private.submit_paper_invalid(p_ballot_id, p_reason);
$$;

CREATE OR REPLACE FUNCTION public.void_unused_paper_ballots(
  p_batch_id UUID DEFAULT NULL,
  p_reason TEXT DEFAULT 'Election closed - voiding unused anonymous paper blanks',
  p_admin_id UUID DEFAULT NULL
)
RETURNS TABLE (
  voided_count INT,
  message TEXT
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, private
AS $$
  SELECT * FROM private.void_unused_paper_ballots(p_batch_id, p_reason, p_admin_id);
$$;

-- ============================================================================
-- 20. Grants / revokes
-- Purpose: service-role-only RPC execution; no anon/auth direct invocation.
-- ============================================================================

REVOKE ALL ON anonymous_paper_blanks FROM PUBLIC, anon, authenticated;
REVOKE ALL ON paper_ballots FROM PUBLIC, anon, authenticated;
REVOKE ALL ON participation_audit FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ballot_audit_log FROM PUBLIC, anon, authenticated;

GRANT ALL ON anonymous_paper_blanks TO service_role;
GRANT ALL ON paper_ballots TO service_role;
GRANT ALL ON participation_audit TO service_role;
GRANT ALL ON ballot_audit_log TO service_role;

REVOKE EXECUTE ON FUNCTION private.enforce_paper_ballot_layout_immutable() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.generate_opaque_paper_ballot_id() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.check_in_paper_voter(TEXT, UUID, UUID) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.issue_paper_ballot(UUID, UUID) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.generate_anonymous_blank_ballot_pool(INT, UUID) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.submit_paper_vote(TEXT, UUID, UUID) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.correct_paper_vote(TEXT, UUID, UUID, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.spoil_paper_check_in(TEXT, TEXT, UUID) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.void_anonymous_paper_blank(TEXT, TEXT, UUID) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.void_unused_anonymous_paper_blanks(UUID, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.paper_pool_reconciliation() FROM PUBLIC, anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.check_in_paper_voter(TEXT, UUID, UUID) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.issue_paper_ballot(UUID, UUID) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.generate_anonymous_blank_ballot_pool(INT, UUID) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.submit_paper_vote(TEXT, UUID, UUID) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.correct_paper_vote(TEXT, UUID, UUID, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.spoil_paper_check_in(TEXT, TEXT, UUID) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.void_anonymous_paper_blank(TEXT, TEXT, UUID) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.void_unused_anonymous_paper_blanks(UUID, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.paper_pool_reconciliation() FROM PUBLIC, anon, authenticated;

REVOKE EXECUTE ON FUNCTION private.issue_preprinted_paper_ballot(TEXT, UUID, UUID) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.generate_blank_paper_ballot_batch(INT, UUID) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.spoil_paper_ballot(TEXT, TEXT, UUID) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.submit_paper_invalid(TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.void_unused_paper_ballots(UUID, TEXT, UUID) FROM PUBLIC, anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.issue_preprinted_paper_ballot(TEXT, UUID, UUID) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.generate_blank_paper_ballot_batch(INT, UUID) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.spoil_paper_ballot(TEXT, TEXT, UUID) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.submit_paper_invalid(TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.void_unused_paper_ballots(UUID, TEXT, UUID) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION private.check_in_paper_voter(TEXT, UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION private.issue_paper_ballot(UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION private.generate_anonymous_blank_ballot_pool(INT, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION private.submit_paper_vote(TEXT, UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION private.correct_paper_vote(TEXT, UUID, UUID, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION private.spoil_paper_check_in(TEXT, TEXT, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION private.void_anonymous_paper_blank(TEXT, TEXT, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION private.void_unused_anonymous_paper_blanks(UUID, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION private.paper_pool_reconciliation() TO service_role;

GRANT EXECUTE ON FUNCTION public.check_in_paper_voter(TEXT, UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.issue_paper_ballot(UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.generate_anonymous_blank_ballot_pool(INT, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.submit_paper_vote(TEXT, UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.correct_paper_vote(TEXT, UUID, UUID, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.spoil_paper_check_in(TEXT, TEXT, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.void_anonymous_paper_blank(TEXT, TEXT, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.void_unused_anonymous_paper_blanks(UUID, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.paper_pool_reconciliation() TO service_role;

GRANT EXECUTE ON FUNCTION public.issue_preprinted_paper_ballot(TEXT, UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.generate_blank_paper_ballot_batch(INT, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.spoil_paper_ballot(TEXT, TEXT, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.submit_paper_invalid(TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.void_unused_paper_ballots(UUID, TEXT, UUID) TO service_role;

-- ============================================================================
-- END migration_wave6_paper_severance.sql
-- ============================================================================
