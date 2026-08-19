-- ROLLBACK: Option E - Surplus Pre-printed Paper Ballots
-- Run this in Supabase SQL Editor to revert migration_option_e_paper_ballots.sql
-- WARNING: This will DELETE all Option E data (batches, pre-printed ballots, assignments, voids)
-- Run migration_paper_ballots.sql and migration_fix_paper_rpcs.sql first if not already applied.

-- 0. Ensure required extensions exist
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

--------------------------------------------------------------------------------
-- 1. DROP PUBLIC WRAPPER FUNCTIONS
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.generate_blank_paper_ballot_batch(INT, UUID);
DROP FUNCTION IF EXISTS public.issue_preprinted_paper_ballot(TEXT, UUID, UUID);
DROP FUNCTION IF EXISTS public.spoil_paper_ballot(TEXT, TEXT, UUID);
DROP FUNCTION IF EXISTS public.void_unused_paper_ballots(UUID, TEXT, UUID);

--------------------------------------------------------------------------------
-- 2. DROP PRIVATE RPC FUNCTIONS (Option E specific)
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS private.generate_blank_paper_ballot_batch(INT, UUID);
DROP FUNCTION IF EXISTS private.issue_preprinted_paper_ballot(TEXT, UUID, UUID);
DROP FUNCTION IF EXISTS private.spoil_paper_ballot(TEXT, TEXT, UUID);
DROP FUNCTION IF EXISTS private.void_unused_paper_ballots(UUID, TEXT, UUID);

-- Revert submit_anonymous_vote to pre-Option E version (from migration_paper_ballots.sql)
-- This drops the Option E override and restores the original
DROP FUNCTION IF EXISTS private.submit_anonymous_vote(VARCHAR, UUID);

-- Recreate original submit_anonymous_vote from migration_paper_ballots.sql
CREATE FUNCTION private.submit_anonymous_vote(
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
    RETURN QUERY SELECT FALSE, 'This token has already been used.'::TEXT, NULL::TEXT, NULL::TEXT;
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

-- Revert submit_paper_vote to pre-Option E version (only accepts 'ISSUED' status)
DROP FUNCTION IF EXISTS private.submit_paper_vote(TEXT, UUID);

CREATE FUNCTION private.submit_paper_vote(
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

  IF v_paper.status != 'ISSUED' THEN
    RETURN QUERY SELECT FALSE, 'Ballot cannot be processed (status: ' || v_paper.status || ').'::TEXT, NULL::TEXT;
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
-- 3. REVOKE GRANTS
--------------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION private.generate_blank_paper_ballot_batch(INT, UUID) FROM service_role;
REVOKE EXECUTE ON FUNCTION private.issue_preprinted_paper_ballot(TEXT, UUID, UUID) FROM service_role;
REVOKE EXECUTE ON FUNCTION private.spoil_paper_ballot(TEXT, TEXT, UUID) FROM service_role;
REVOKE EXECUTE ON FUNCTION private.void_unused_paper_ballots(UUID, TEXT, UUID) FROM service_role;
REVOKE EXECUTE ON FUNCTION private.submit_anonymous_vote(VARCHAR, UUID) FROM service_role;
REVOKE EXECUTE ON FUNCTION private.submit_paper_vote(TEXT, UUID) FROM service_role;

REVOKE EXECUTE ON FUNCTION public.generate_blank_paper_ballot_batch(INT, UUID) FROM service_role;
REVOKE EXECUTE ON FUNCTION public.issue_preprinted_paper_ballot(TEXT, UUID, UUID) FROM service_role;
REVOKE EXECUTE ON FUNCTION public.spoil_paper_ballot(TEXT, TEXT, UUID) FROM service_role;
REVOKE EXECUTE ON FUNCTION public.void_unused_paper_ballots(UUID, TEXT, UUID) FROM service_role;

-- Restore grants to anon/authenticated for original functions (if they existed)
-- Note: Original migration_paper_ballots.sql did not grant to anon/authenticated

--------------------------------------------------------------------------------
-- 4. DROP INDEXES
--------------------------------------------------------------------------------
DROP INDEX IF EXISTS idx_paper_ballots_batch;
DROP INDEX IF EXISTS idx_paper_ballots_status;
DROP INDEX IF EXISTS idx_paper_ballots_one_active;

-- Recreate original unique index (only on 'ISSUED', 'VOTED' - no ISSUED_TO_VOTER)
CREATE UNIQUE INDEX idx_paper_ballots_one_active
  ON paper_ballots (member_id)
  WHERE status IN ('ISSUED', 'VOTED');

--------------------------------------------------------------------------------
-- 5. DISABLE RLS AND DROP paper_ballot_batches TABLE
--------------------------------------------------------------------------------
ALTER TABLE paper_ballot_batches DISABLE ROW LEVEL SECURITY;
DROP TABLE IF EXISTS paper_ballot_batches;

--------------------------------------------------------------------------------
-- 6. REMOVE OPTION E COLUMNS FROM paper_ballots
--------------------------------------------------------------------------------
ALTER TABLE paper_ballots
  DROP COLUMN IF EXISTS batch_id,
  DROP COLUMN IF EXISTS issued_to_voter_at,
  DROP COLUMN IF EXISTS issued_by,
  DROP COLUMN IF EXISTS recorded_by,
  DROP COLUMN IF EXISTS spoiled_at,
  DROP COLUMN IF EXISTS spoiled_by,
  DROP COLUMN IF EXISTS voided_at,
  DROP COLUMN IF EXISTS voided_by,
  DROP COLUMN IF EXISTS void_reason;

--------------------------------------------------------------------------------
-- 7. RESTORE member_id NOT NULL CONSTRAINT
--------------------------------------------------------------------------------
-- First, handle any NULL member_ids created by Option E
-- Option: delete pre-printed ballots (AVAILABLE status) or assign them
-- Here we delete them since they are Option E artifacts
DELETE FROM paper_ballots WHERE member_id IS NULL;

-- Now restore NOT NULL
ALTER TABLE paper_ballots ALTER COLUMN member_id SET NOT NULL;

--------------------------------------------------------------------------------
-- 8. ENUM VALUES NOTE
--------------------------------------------------------------------------------
-- PostgreSQL does NOT support removing enum values (DROP VALUE).
-- The enum values 'AVAILABLE', 'ISSUED_TO_VOTER', 'VOIDED_UNUSED' will remain in paper_ballot_status.
-- They are harmless if unused. To fully remove them, you would need to:
--   1. Create a new enum without those values
--   2. Alter column to use new enum
--   3. Drop old enum
-- This is complex and not included in this rollback.
-- If you need a clean enum, run a separate migration to recreate it.

--------------------------------------------------------------------------------
-- 9. CLEANUP GRANTS ON TABLES (restore to pre-Option E state)
--------------------------------------------------------------------------------
REVOKE ALL ON paper_ballot_batches FROM service_role;
REVOKE ALL ON paper_ballots FROM service_role;

-- Note: Original migration_fix_service_role_grants.sql granted service_role on paper_ballots
-- Re-run that migration if you need those grants restored.

--------------------------------------------------------------------------------
-- ROLLBACK COMPLETE
-- Verify by checking:
--   \d paper_ballots
--   \d paper_ballot_batches (should not exist)
--   \df *paper* (should only show original functions)
--   \dT+ paper_ballot_status (enum values AVAILABLE/ISSUED_TO_VOTER/VOIDED_UNUSED remain but unused)