-- MIGRATION: Add paper ballot support to existing schema (FIXED with fallback HMAC key)
-- Run this in Supabase SQL Editor AFTER the base schema already exists

-- 0. Ensure pgcrypto extension is enabled (required for gen_random_bytes)
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- 1. Create paper_ballot_status type if not exists
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'paper_ballot_status') THEN
    CREATE TYPE paper_ballot_status AS ENUM ('ISSUED', 'VOTED', 'SPOILED', 'MISSING');
  END IF;
END $$;

-- 2. Create paper_ballots table if not exists
CREATE TABLE IF NOT EXISTS paper_ballots (
  ballot_id TEXT PRIMARY KEY,
  member_id UUID NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  status paper_ballot_status NOT NULL DEFAULT 'ISSUED',
  issued_at TIMESTAMPTZ DEFAULT NOW(),
  voted_at TIMESTAMPTZ,
  candidate_id UUID REFERENCES candidates(id),
  invalid_reason TEXT,
  short_code VARCHAR(14) UNIQUE NOT NULL,
  qr_svg TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 3. Create indexes if not exist
CREATE UNIQUE INDEX IF NOT EXISTS idx_paper_ballots_one_active
  ON paper_ballots (member_id)
  WHERE status IN ('ISSUED', 'VOTED');

CREATE INDEX IF NOT EXISTS idx_paper_ballots_member ON paper_ballots(member_id);
CREATE INDEX IF NOT EXISTS idx_paper_ballots_short_code ON paper_ballots(short_code);

-- 4. Create vote_audit_log table if not exists
CREATE TABLE IF NOT EXISTS vote_audit_log (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  action VARCHAR(50) NOT NULL,
  member_id UUID REFERENCES members(id),
  ballot_id TEXT,
  candidate_id UUID REFERENCES candidates(id),
  admin_id UUID REFERENCES members(id),
  details JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_vote_audit_log_member ON vote_audit_log(member_id);
CREATE INDEX IF NOT EXISTS idx_vote_audit_log_ballot ON vote_audit_log(ballot_id);
CREATE INDEX IF NOT EXISTS idx_vote_audit_log_created ON vote_audit_log(created_at);

-- 5. Enable RLS on new tables
ALTER TABLE paper_ballots ENABLE ROW LEVEL SECURITY;
ALTER TABLE vote_audit_log ENABLE ROW LEVEL SECURITY;

-- 6. Create private schema if not exists
CREATE SCHEMA IF NOT EXISTS private;

-- 7. HMAC helper functions WITH FALLBACK KEY FOR TESTING
CREATE OR REPLACE FUNCTION private.hmac_sign(p_payload TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_key TEXT;
  v_sig BYTEA;
BEGIN
  -- Try to get from config, fallback to test key
  v_key := current_setting('app.ballot_hmac_key', true);
  IF v_key IS NULL OR v_key = '' THEN
    v_key := 'test-hmac-key-32-chars-minimum!!';  -- FALLBACK FOR TESTING
  END IF;
  v_sig := hmac(v_key::bytea, p_payload::bytea, 'sha256');
  RETURN p_payload || '.' || encode(v_sig, 'hex');
END;
$$;

CREATE OR REPLACE FUNCTION private.hmac_verify(p_ballot_id TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_key TEXT;
  v_payload TEXT;
  v_sig_hex TEXT;
  v_sig BYTEA;
  v_expected_sig BYTEA;
  v_dot_pos INT;
BEGIN
  v_key := current_setting('app.ballot_hmac_key', true);
  IF v_key IS NULL OR v_key = '' THEN
    v_key := 'test-hmac-key-32-chars-minimum!!';  -- FALLBACK FOR TESTING
  END IF;

  v_dot_pos := position('.' IN p_ballot_id);
  IF v_dot_pos = 0 THEN
    RETURN NULL;
  END IF;

  v_payload := substring(p_ballot_id FROM 1 FOR v_dot_pos - 1);
  v_sig_hex := substring(p_ballot_id FROM v_dot_pos + 1);
  v_sig := decode(v_sig_hex, 'hex');
  v_expected_sig := hmac(v_key::bytea, v_payload::bytea, 'sha256');

  IF v_sig = v_expected_sig THEN
    RETURN v_payload;
  ELSE
    RETURN NULL;
  END IF;
END;
$$;

-- 8. Generate short code with Luhn checksum
CREATE OR REPLACE FUNCTION private.generate_short_code()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_chars TEXT := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_code TEXT := '';
  v_sum INT := 0;
  v_digit INT;
  v_checksum INT;
  i INT;
BEGIN
  FOR i IN 1..11 LOOP
    v_code := v_code || substr(v_chars, floor(random() * length(v_chars) + 1)::int, 1);
  END LOOP;

  FOR i IN REVERSE 1..11 LOOP
    v_digit := ascii(substr(v_code, i, 1));
    IF v_digit BETWEEN 48 AND 57 THEN
      v_digit := v_digit - 48;
    ELSE
      v_digit := v_digit - 55;
    END IF;

    IF (11 - i) % 2 = 0 THEN
      v_digit := v_digit * 2;
      IF v_digit > 35 THEN v_digit := v_digit - 35; END IF;
    END IF;
    v_sum := v_sum + v_digit;
  END LOOP;

  v_checksum := (36 - (v_sum % 36)) % 36;
  IF v_checksum < 10 THEN
    v_code := v_code || chr(v_checksum + 48);
  ELSE
    v_code := v_code || chr(v_checksum + 55);
  END IF;

  RETURN substr(v_code, 1, 4) || '-' || substr(v_code, 5, 4) || '-' || substr(v_code, 9, 4);
END;
$$;

-- 9. Generate QR code SVG (placeholder)
CREATE OR REPLACE FUNCTION private.generate_qr_svg(p_ballot_id TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_qr TEXT;
BEGIN
  v_qr := '<svg xmlns="http://www.w3.org/2000/svg" width="200" height="200" viewBox="0 0 200 200">'
    || '<rect width="200" height="200" fill="white"/>'
    || '<text x="100" y="100" font-family="monospace" font-size="8" text-anchor="middle" dominant-baseline="middle">'
    || p_ballot_id
    || '</text></svg>';
  RETURN v_qr;
END;
$$;

-- 10. DROP and RECREATE submit_anonymous_vote with paper ballot check
DROP FUNCTION IF EXISTS private.submit_anonymous_vote(VARCHAR, UUID);

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
    RETURN QUERY SELECT FALSE, 'This token has already been used to vote.'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Check if member already has an active paper ballot (ISSUED or VOTED)
  SELECT * INTO v_paper_ballot FROM paper_ballots
  WHERE member_id = v_member_id AND status IN ('ISSUED', 'VOTED')
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

-- 11. Issue paper ballot
CREATE OR REPLACE FUNCTION private.issue_paper_ballot(
  p_member_id UUID
)
RETURNS TABLE (success BOOLEAN, message TEXT, ballot_id TEXT, short_code TEXT, qr_svg TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_member RECORD;
  v_payload TEXT;
  v_ballot_id TEXT;
  v_short_code TEXT;
  v_qr_svg TEXT;
  v_attempts INT := 0;
  v_insert_ok BOOLEAN := FALSE;
BEGIN
  SELECT id, full_name INTO v_member FROM members WHERE id = p_member_id AND is_active = TRUE;
  IF v_member.id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Member not found or inactive.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM tokens t
    WHERE t.member_id = v_member.id AND t.type = 'VOTING' AND t.is_used = TRUE
  ) THEN
    RETURN QUERY SELECT FALSE, 'Member has already voted digitally.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM paper_ballots
    WHERE member_id = v_member.id AND status IN ('ISSUED', 'VOTED')
  ) THEN
    RETURN QUERY SELECT FALSE, 'Member already has an active paper ballot.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  v_payload := 'PAPER:' || v_member.id || ':' || extract(epoch FROM NOW())::bigint || ':' || encode(gen_random_bytes(8), 'hex');
  v_ballot_id := private.hmac_sign(v_payload);

  WHILE v_attempts < 5 AND NOT v_insert_ok LOOP
    v_short_code := private.generate_short_code();
    v_qr_svg := private.generate_qr_svg(v_ballot_id);
    BEGIN
      INSERT INTO paper_ballots (ballot_id, member_id, status, short_code, qr_svg)
      VALUES (v_ballot_id, v_member.id, 'ISSUED', v_short_code, v_qr_svg);
      v_insert_ok := TRUE;
    EXCEPTION WHEN unique_violation THEN
      v_attempts := v_attempts + 1;
    END;
  END LOOP;

  IF NOT v_insert_ok THEN
    RETURN QUERY SELECT FALSE, 'Could not generate unique short code after 5 attempts.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  RETURN QUERY SELECT TRUE, 'Paper ballot issued for ' || v_member.full_name || '.'::TEXT, v_ballot_id, v_short_code, v_qr_svg;
END;
$$;

-- 12. Submit paper vote
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

  IF NOT v_payload LIKE 'PAPER:%' THEN
    RETURN QUERY SELECT FALSE, 'Invalid ballot ID format.'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  SELECT * INTO v_paper FROM paper_ballots WHERE ballot_id = p_ballot_id FOR UPDATE;
  IF v_paper.ballot_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Ballot not found.'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  IF v_paper.status != 'ISSUED' THEN
    RETURN QUERY SELECT FALSE, 'Ballot already used or invalid (status: ' || v_paper.status || ').'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  SELECT t.id INTO v_digital_token FROM tokens t
  WHERE t.member_id = v_paper.member_id AND t.type = 'VOTING' AND t.is_used = TRUE
  FOR UPDATE;

  IF FOUND THEN
    NULL; -- Paper wins; tally deduplicates
  END IF;

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

  UPDATE paper_ballots
  SET status = 'VOTED', voted_at = NOW(), candidate_id = p_candidate_id
  WHERE ballot_id = p_ballot_id;

  RETURN QUERY SELECT TRUE, 'Paper vote recorded.'::TEXT, v_receipt;
END;
$$;

-- 13. Submit paper invalid
CREATE OR REPLACE FUNCTION private.submit_paper_invalid(
  p_ballot_id TEXT,
  p_reason TEXT
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

  IF v_paper.status != 'ISSUED' THEN
    RETURN QUERY SELECT FALSE, 'Ballot already processed (status: ' || v_paper.status || ').'::TEXT;
    RETURN;
  END IF;

  UPDATE paper_ballots
  SET status = 'SPOILED', invalid_reason = p_reason
  WHERE ballot_id = p_ballot_id;

  RETURN QUERY SELECT TRUE, 'Ballot marked as invalid: ' || p_reason || '.'::TEXT;
END;
$$;

-- 14. Revoke from anon/authenticated, grant to service_role
REVOKE EXECUTE ON FUNCTION private.submit_anonymous_vote(VARCHAR, UUID) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.issue_paper_ballot(UUID) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.submit_paper_vote(TEXT, UUID) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.submit_paper_invalid(TEXT, TEXT) FROM anon, authenticated;

GRANT EXECUTE ON FUNCTION private.submit_anonymous_vote(VARCHAR, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION private.issue_paper_ballot(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION private.submit_paper_vote(TEXT, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION private.submit_paper_invalid(TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION private.hmac_sign(TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION private.hmac_verify(TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION private.generate_short_code() TO service_role;
GRANT EXECUTE ON FUNCTION private.generate_qr_svg(TEXT) TO service_role;