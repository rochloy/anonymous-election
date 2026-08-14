-- MIGRATION: Option E - Surplus Pre-printed Paper Ballots with Scan-to-Assign
-- Run this in Supabase SQL Editor AFTER migration_paper_ballots.sql and migration_fix_paper_rpcs.sql
--
-- Features added:
-- 1. Pre-printed blank paper ballots generated in batches before election (status: AVAILABLE, member_id: NULL)
-- 2. Scan-to-assign at handout: issue_preprinted_paper_ballot links blank ballot to voter (status: ISSUED_TO_VOTER)
-- 3. Vote recording: submit_paper_vote accepts ISSUED or ISSUED_TO_VOTER ballots
-- 4. Post-election voiding: void_unused_paper_ballots mass-voids remaining AVAILABLE ballots
-- 5. Audit trail & batch tracking table: paper_ballot_batches

-- 0. Ensure required extensions exist
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 1. Expand paper_ballot_status enum values
ALTER TYPE paper_ballot_status ADD VALUE IF NOT EXISTS 'AVAILABLE';
ALTER TYPE paper_ballot_status ADD VALUE IF NOT EXISTS 'ISSUED_TO_VOTER';
ALTER TYPE paper_ballot_status ADD VALUE IF NOT EXISTS 'VOIDED_UNUSED';

-- 2. Create paper_ballot_batches table
CREATE TABLE IF NOT EXISTS paper_ballot_batches (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  generated_count INT NOT NULL,
  generated_by UUID REFERENCES members(id),
  generated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  voided_at TIMESTAMPTZ,
  notes TEXT
);

-- 3. Alter paper_ballots table to support Option E
-- Make member_id NULLABLE (for unassigned pre-printed blank ballots)
ALTER TABLE paper_ballots ALTER COLUMN member_id DROP NOT NULL;

-- Add Option E metadata columns if they do not exist
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'paper_ballots' AND column_name = 'batch_id') THEN
    ALTER TABLE paper_ballots ADD COLUMN batch_id UUID REFERENCES paper_ballot_batches(id);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'paper_ballots' AND column_name = 'issued_to_voter_at') THEN
    ALTER TABLE paper_ballots ADD COLUMN issued_to_voter_at TIMESTAMPTZ;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'paper_ballots' AND column_name = 'issued_by') THEN
    ALTER TABLE paper_ballots ADD COLUMN issued_by UUID REFERENCES members(id);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'paper_ballots' AND column_name = 'recorded_by') THEN
    ALTER TABLE paper_ballots ADD COLUMN recorded_by UUID REFERENCES members(id);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'paper_ballots' AND column_name = 'spoiled_at') THEN
    ALTER TABLE paper_ballots ADD COLUMN spoiled_at TIMESTAMPTZ;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'paper_ballots' AND column_name = 'spoiled_by') THEN
    ALTER TABLE paper_ballots ADD COLUMN spoiled_by UUID REFERENCES members(id);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'paper_ballots' AND column_name = 'voided_at') THEN
    ALTER TABLE paper_ballots ADD COLUMN voided_at TIMESTAMPTZ;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'paper_ballots' AND column_name = 'voided_by') THEN
    ALTER TABLE paper_ballots ADD COLUMN voided_by UUID REFERENCES members(id);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'paper_ballots' AND column_name = 'void_reason') THEN
    ALTER TABLE paper_ballots ADD COLUMN void_reason TEXT;
  END IF;
END $$;

-- 4. Create indexes for Option E
CREATE INDEX IF NOT EXISTS idx_paper_ballots_batch ON paper_ballots(batch_id);
CREATE INDEX IF NOT EXISTS idx_paper_ballots_status ON paper_ballots(status);

-- Partial index to ensure a member has at most ONE active/voted paper ballot
DROP INDEX IF EXISTS idx_paper_ballots_one_active;
CREATE UNIQUE INDEX idx_paper_ballots_one_active
  ON paper_ballots (member_id)
  WHERE status IN ('ISSUED', 'ISSUED_TO_VOTER', 'VOTED');

-- 5. Enable RLS on paper_ballot_batches
ALTER TABLE paper_ballot_batches ENABLE ROW LEVEL SECURITY;

-- Grant table access to service_role
GRANT ALL ON paper_ballot_batches TO service_role;
GRANT ALL ON paper_ballots TO service_role;

--------------------------------------------------------------------------------
-- PRIVATE RPC 1: generate_blank_paper_ballot_batch
-- Pre-prints N unassigned blank ballots with unique HMAC signatures, short codes, and QR codes
--------------------------------------------------------------------------------
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
DECLARE
  v_batch_id UUID;
  v_payload TEXT;
  v_ballot_id TEXT;
  v_short_code TEXT;
  v_qr_svg TEXT;
  v_attempts INT;
  v_insert_ok BOOLEAN;
  i INT;
BEGIN
  IF p_count IS NULL OR p_count <= 0 OR p_count > 1000 THEN
    RETURN QUERY SELECT NULL::UUID, 0, 'Batch size must be between 1 and 1000.'::TEXT;
    RETURN;
  END IF;

  -- Create batch header
  INSERT INTO paper_ballot_batches (generated_count, generated_by)
  VALUES (p_count, p_admin_id)
  RETURNING id INTO v_batch_id;

  -- Generate pre-printed blank ballots
  FOR i IN 1..p_count LOOP
    v_attempts := 0;
    v_insert_ok := FALSE;

    v_payload := 'PAPER:BLANK:' || v_batch_id || ':' || i || ':' || extract(epoch FROM NOW())::bigint || ':' || encode(gen_random_bytes(8), 'hex');
    v_ballot_id := private.hmac_sign(v_payload);

    WHILE v_attempts < 5 AND NOT v_insert_ok LOOP
      v_short_code := private.generate_short_code();
      v_qr_svg := private.generate_qr_svg(v_ballot_id);
      BEGIN
        INSERT INTO paper_ballots (
          ballot_id, member_id, batch_id, status, short_code, qr_svg, created_at
        ) VALUES (
          v_ballot_id, NULL, v_batch_id, 'AVAILABLE', v_short_code, v_qr_svg, NOW()
        );
        v_insert_ok := TRUE;
      EXCEPTION WHEN unique_violation THEN
        v_attempts := v_attempts + 1;
      END;
    END LOOP;

    IF NOT v_insert_ok THEN
      RAISE EXCEPTION 'Could not generate unique short code for ballot % in batch %', i, v_batch_id;
    END IF;
  END LOOP;

  -- Audit log
  INSERT INTO vote_audit_log (action, admin_id, details)
  VALUES ('BATCH_GENERATED', p_admin_id, jsonb_build_object('batch_id', v_batch_id, 'count', p_count));

  RETURN QUERY SELECT v_batch_id, p_count, 'Successfully generated batch of ' || p_count || ' pre-printed blank ballots.'::TEXT;
END;
$$;

--------------------------------------------------------------------------------
-- PRIVATE RPC 2: issue_preprinted_paper_ballot
-- First scan at handout: links an AVAILABLE blank pre-printed ballot to a member
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.issue_preprinted_paper_ballot(
  p_ballot_id TEXT,
  p_member_id UUID,
  p_admin_id UUID DEFAULT NULL
)
RETURNS TABLE (success BOOLEAN, message TEXT, ballot_id TEXT, short_code TEXT, qr_svg TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_member RECORD;
  v_ballot RECORD;
  v_payload TEXT;
BEGIN
  -- Verify HMAC signature
  v_payload := private.hmac_verify(p_ballot_id);
  IF v_payload IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Invalid ballot ID (HMAC signature verification failed).'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Verify member exists and is active
  SELECT id, full_name INTO v_member FROM members WHERE id = p_member_id AND is_active = TRUE;
  IF v_member.id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Member not found or inactive.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Check if member has already voted digitally
  IF EXISTS (
    SELECT 1 FROM tokens t
    WHERE t.member_id = v_member.id AND t.type = 'VOTING' AND t.is_used = TRUE
  ) THEN
    RETURN QUERY SELECT FALSE, 'Member has already voted digitally.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Check if member already has an active or voted paper ballot
  IF EXISTS (
    SELECT 1 FROM paper_ballots
    WHERE member_id = v_member.id AND status IN ('ISSUED', 'ISSUED_TO_VOTER', 'VOTED')
  ) THEN
    RETURN QUERY SELECT FALSE, 'Member already has an active or used paper ballot.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Lock and verify ballot is AVAILABLE
  SELECT * INTO v_ballot FROM paper_ballots WHERE ballot_id = p_ballot_id FOR UPDATE;
  IF v_ballot.ballot_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Ballot not found in system.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  IF v_ballot.status != 'AVAILABLE' THEN
    RETURN QUERY SELECT FALSE, 'Ballot is not available for assignment (status: ' || v_ballot.status || ').'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Assign ballot to member and update status
  UPDATE paper_ballots
  SET member_id = v_member.id,
      status = 'ISSUED_TO_VOTER',
      issued_to_voter_at = NOW(),
      issued_by = p_admin_id
  WHERE ballot_id = p_ballot_id;

  -- Reserve the member's voting entitlement at handout to prevent a later digital vote.
  UPDATE tokens
  SET is_used = TRUE, used_at = NOW(), channel_sent = 'PAPER'
  WHERE member_id = v_member.id AND type = 'VOTING' AND is_used = FALSE;

  -- Audit log
  INSERT INTO vote_audit_log (action, member_id, ballot_id, admin_id, details)
  VALUES ('PAPER_ISSUED_OPTION_E', v_member.id, p_ballot_id, p_admin_id, jsonb_build_object('short_code', v_ballot.short_code, 'batch_id', v_ballot.batch_id));

  RETURN QUERY SELECT TRUE, 'Paper ballot ' || v_ballot.short_code || ' assigned to ' || v_member.full_name || '.'::TEXT, p_ballot_id, v_ballot.short_code, v_ballot.qr_svg;
END;
$$;

--------------------------------------------------------------------------------
-- PRIVATE RPC 2b: submit_anonymous_vote (Updated to block Option E paper handout)
-- Digital voting must reject members who already have an active/voted paper ballot.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.submit_anonymous_vote(
  p_token_hash VARCHAR(64),
  p_candidate_id UUID
)
RETURNS TABLE (success BOOLEAN, message TEXT, receipt_code TEXT, ballot_id TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_token_id UUID;
  v_member_id UUID;
  v_is_used BOOLEAN;
  v_phase election_phase;
  v_voting_end TIMESTAMPTZ;
  v_receipt TEXT;
  v_ballot_id TEXT;
  v_payload TEXT;
  v_attempts INT := 0;
  v_insert_ok BOOLEAN := FALSE;
  v_paper_ballot RECORD;
BEGIN
  SELECT current_phase, voting_end INTO v_phase, v_voting_end FROM election_settings WHERE id = 1;

  IF v_phase != 'VOTING' OR (v_voting_end IS NOT NULL AND NOW() > v_voting_end) THEN
    RETURN QUERY SELECT FALSE, 'Voting phase is closed or expired.'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  SELECT id, member_id, is_used INTO v_token_id, v_member_id, v_is_used FROM tokens
  WHERE token_hash = p_token_hash AND type = 'VOTING' FOR UPDATE;

  IF v_token_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Invalid or non-existent voting token.'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  IF v_is_used THEN
    RETURN QUERY SELECT FALSE, 'This token has already been used or reserved for paper voting.'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Check if member already has an active or voted paper ballot.
  SELECT * INTO v_paper_ballot FROM paper_ballots
  WHERE member_id = v_member_id AND status IN ('ISSUED', 'ISSUED_TO_VOTER', 'VOTED')
  FOR SHARE;

  IF FOUND THEN
    RETURN QUERY SELECT FALSE, 'A paper ballot has already been issued for this member.'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  v_payload := v_member_id || ':' || p_candidate_id || ':' || extract(epoch FROM NOW())::bigint || ':' || encode(gen_random_bytes(8), 'hex');
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
$$;

--------------------------------------------------------------------------------
-- PRIVATE RPC 3: submit_paper_vote (Updated to support Option E ISSUED_TO_VOTER)
-- Second scan at vote recording: processes vote for ISSUED or ISSUED_TO_VOTER ballot
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.submit_paper_vote(
  p_ballot_id TEXT,
  p_candidate_id UUID
)
RETURNS TABLE (success BOOLEAN, message TEXT, receipt_code TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_paper RECORD;
  v_payload TEXT;
  v_receipt TEXT;
  v_attempts INT := 0;
  v_insert_ok BOOLEAN := FALSE;
  v_digital_token RECORD;
BEGIN
  v_payload := private.hmac_verify(p_ballot_id);
  IF v_payload IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Invalid ballot ID (HMAC verification failed).'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  SELECT * INTO v_paper FROM paper_ballots WHERE ballot_id = p_ballot_id FOR UPDATE;
  IF v_paper.ballot_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Ballot not found.'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Option E requirement: ballot must be issued to a voter before it can be voted
  IF v_paper.status NOT IN ('ISSUED', 'ISSUED_TO_VOTER') THEN
    RETURN QUERY SELECT FALSE, 'Ballot cannot be processed (status: ' || v_paper.status || ').'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  IF v_paper.member_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Unassigned ballot cannot be voted. Issue ballot to voter first.'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Check if member already voted digitally
  SELECT t.id INTO v_digital_token FROM tokens t
  WHERE t.member_id = v_paper.member_id AND t.type = 'VOTING' AND t.is_used = TRUE
  FOR UPDATE;

  IF FOUND THEN
    NULL; -- Paper ballot wins; tally deduplicates
  END IF;

  -- Generate receipt code and insert into ballots
  WHILE v_attempts < 5 AND NOT v_insert_ok LOOP
    v_receipt := 'PB-' || encode(gen_random_bytes(5), 'hex');
    BEGIN
      INSERT INTO ballots (ballot_id, candidate_id, receipt_code, channel, cast_date)
      VALUES (p_ballot_id, p_candidate_id, v_receipt, 'PAPER', CURRENT_DATE);
      v_insert_ok := TRUE;
    EXCEPTION WHEN unique_violation THEN
      v_attempts := v_attempts + 1;
    END;
  END LOOP;

  IF NOT v_insert_ok THEN
    RETURN QUERY SELECT FALSE, 'Could not generate unique receipt code.'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Update paper ballot status
  UPDATE paper_ballots
  SET status = 'VOTED', voted_at = NOW(), candidate_id = p_candidate_id
  WHERE ballot_id = p_ballot_id;

  -- Mark digital token as used to prevent subsequent online voting
  UPDATE tokens
  SET is_used = TRUE, used_at = NOW(), channel_sent = 'PAPER'
  WHERE member_id = v_paper.member_id AND type = 'VOTING' AND is_used = FALSE;

  -- Audit log
  INSERT INTO vote_audit_log (action, member_id, ballot_id, candidate_id, details)
  VALUES ('PAPER_VOTED', v_paper.member_id, p_ballot_id, p_candidate_id, jsonb_build_object('receipt_code', v_receipt));

  RETURN QUERY SELECT TRUE, 'Paper vote recorded.'::TEXT, v_receipt;
END;
$$;

--------------------------------------------------------------------------------
-- PRIVATE RPC 4: spoil_paper_ballot
-- Spoil a ballot (damaged, mis-marked, or rejected)
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.spoil_paper_ballot(
  p_ballot_id TEXT,
  p_reason TEXT,
  p_admin_id UUID DEFAULT NULL
)
RETURNS TABLE (success BOOLEAN, message TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_paper RECORD;
  v_payload TEXT;
BEGIN
  v_payload := private.hmac_verify(p_ballot_id);
  IF v_payload IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Invalid ballot ID (HMAC verification failed).'::TEXT;
    RETURN;
  END IF;

  SELECT * INTO v_paper FROM paper_ballots WHERE ballot_id = p_ballot_id FOR UPDATE;
  IF v_paper.ballot_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Ballot not found.'::TEXT;
    RETURN;
  END IF;

  IF v_paper.status NOT IN ('ISSUED', 'ISSUED_TO_VOTER', 'AVAILABLE') THEN
    RETURN QUERY SELECT FALSE, 'Ballot cannot be spoiled from status: ' || v_paper.status || '.'::TEXT;
    RETURN;
  END IF;

  UPDATE paper_ballots
  SET status = 'SPOILED', invalid_reason = p_reason, spoiled_at = NOW(), spoiled_by = p_admin_id
  WHERE ballot_id = p_ballot_id;

  -- Audit log
  INSERT INTO vote_audit_log (action, member_id, ballot_id, admin_id, details)
  VALUES ('PAPER_SPOILED', v_paper.member_id, p_ballot_id, p_admin_id, jsonb_build_object('reason', p_reason));

  RETURN QUERY SELECT TRUE, 'Ballot marked as spoiled: ' || p_reason || '.'::TEXT;
END;
$$;

--------------------------------------------------------------------------------
-- PRIVATE RPC 5: void_unused_paper_ballots
-- Post-election closure: mass-void all remaining unassigned AVAILABLE paper ballots
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.void_unused_paper_ballots(
  p_batch_id UUID DEFAULT NULL,
  p_reason TEXT DEFAULT 'Election closed - voiding remaining surplus ballots',
  p_admin_id UUID DEFAULT NULL
)
RETURNS TABLE (voided_count INT, message TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_count INT;
BEGIN
  IF p_batch_id IS NOT NULL THEN
    UPDATE paper_ballots
    SET status = 'VOIDED_UNUSED',
        voided_at = NOW(),
        voided_by = p_admin_id,
        void_reason = p_reason
    WHERE status = 'AVAILABLE' AND batch_id = p_batch_id;

    GET DIAGNOSTICS v_count = ROW_COUNT;

    UPDATE paper_ballot_batches
    SET voided_at = NOW()
    WHERE id = p_batch_id;
  ELSE
    UPDATE paper_ballots
    SET status = 'VOIDED_UNUSED',
        voided_at = NOW(),
        voided_by = p_admin_id,
        void_reason = p_reason
    WHERE status = 'AVAILABLE';

    GET DIAGNOSTICS v_count = ROW_COUNT;

    UPDATE paper_ballot_batches
    SET voided_at = NOW()
    WHERE voided_at IS NULL;
  END IF;

  -- Audit log
  INSERT INTO vote_audit_log (action, admin_id, details)
  VALUES ('BATCH_VOIDED', p_admin_id, jsonb_build_object('batch_id', p_batch_id, 'voided_count', v_count, 'reason', p_reason));

  RETURN QUERY SELECT v_count, 'Successfully voided ' || v_count || ' unused paper ballots.'::TEXT;
END;
$$;

--------------------------------------------------------------------------------
-- PUBLIC WRAPPERS FOR POSTGREST
--------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.generate_blank_paper_ballot_batch(p_count INT, p_admin_id UUID DEFAULT NULL)
RETURNS TABLE (batch_id UUID, generated_count INT, message TEXT)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, private
AS $$
  SELECT * FROM private.generate_blank_paper_ballot_batch(p_count, p_admin_id);
$$;

CREATE OR REPLACE FUNCTION public.issue_preprinted_paper_ballot(p_ballot_id TEXT, p_member_id UUID, p_admin_id UUID DEFAULT NULL)
RETURNS TABLE (success BOOLEAN, message TEXT, ballot_id TEXT, short_code TEXT, qr_svg TEXT)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, private
AS $$
  SELECT * FROM private.issue_preprinted_paper_ballot(p_ballot_id, p_member_id, p_admin_id);
$$;

CREATE OR REPLACE FUNCTION public.spoil_paper_ballot(p_ballot_id TEXT, p_reason TEXT, p_admin_id UUID DEFAULT NULL)
RETURNS TABLE (success BOOLEAN, message TEXT)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, private
AS $$
  SELECT * FROM private.spoil_paper_ballot(p_ballot_id, p_reason, p_admin_id);
$$;

CREATE OR REPLACE FUNCTION public.void_unused_paper_ballots(p_batch_id UUID DEFAULT NULL, p_reason TEXT DEFAULT 'Election closed - voiding remaining surplus ballots', p_admin_id UUID DEFAULT NULL)
RETURNS TABLE (voided_count INT, message TEXT)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, private
AS $$
  SELECT * FROM private.void_unused_paper_ballots(p_batch_id, p_reason, p_admin_id);
$$;

--------------------------------------------------------------------------------
-- GRANTS & PERMISSIONS
--------------------------------------------------------------------------------

-- Revoke execute from anon/authenticated
REVOKE EXECUTE ON FUNCTION private.generate_blank_paper_ballot_batch(INT, UUID) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.issue_preprinted_paper_ballot(TEXT, UUID, UUID) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.submit_anonymous_vote(VARCHAR, UUID) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.spoil_paper_ballot(TEXT, TEXT, UUID) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.void_unused_paper_ballots(UUID, TEXT, UUID) FROM anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.generate_blank_paper_ballot_batch(INT, UUID) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.issue_preprinted_paper_ballot(TEXT, UUID, UUID) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.spoil_paper_ballot(TEXT, TEXT, UUID) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.void_unused_paper_ballots(UUID, TEXT, UUID) FROM anon, authenticated;

-- Grant execute to service_role
GRANT EXECUTE ON FUNCTION private.generate_blank_paper_ballot_batch(INT, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION private.issue_preprinted_paper_ballot(TEXT, UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION private.submit_anonymous_vote(VARCHAR, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION private.spoil_paper_ballot(TEXT, TEXT, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION private.void_unused_paper_ballots(UUID, TEXT, UUID) TO service_role;

GRANT EXECUTE ON FUNCTION public.generate_blank_paper_ballot_batch(INT, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.issue_preprinted_paper_ballot(TEXT, UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.spoil_paper_ballot(TEXT, TEXT, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.void_unused_paper_ballots(UUID, TEXT, UUID) TO service_role;
