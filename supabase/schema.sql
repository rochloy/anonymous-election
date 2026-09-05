-- BASE SCHEMA — idempotent DDL (safe to re-run on the SAME fresh DB without erroring).
-- CAVEAT: idempotent != convergent. This file is the CANONICAL run-order item #1 and is meant to
-- run FIRST on a clean database. Do NOT re-run it against an already-migrated DB: the
-- CREATE OR REPLACE FUNCTION blocks below would overwrite RPCs that later migrations redefine
-- (e.g. submit_anonymous_vote → reverts to the pre-opaque_ballot_ids leaky payload). The guards
-- here only prevent hard failures on partial re-runs; later migrations are what reshape a live DB.
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ELECTION SETTINGS & PHASES
DO $$ BEGIN
  CREATE TYPE election_phase AS ENUM (
    'SETUP', 'NOMINATION', 'NOMINATION_CLOSED', 'VOTING', 'VOTING_CLOSED', 'COMPLETED'
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS election_settings (
  id INT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  current_phase election_phase NOT NULL DEFAULT 'SETUP',
  nomination_start TIMESTAMPTZ,
  nomination_end TIMESTAMPTZ,
  voting_start TIMESTAMPTZ,
  voting_end TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

INSERT INTO election_settings (id, current_phase) VALUES (1, 'SETUP')
ON CONFLICT (id) DO NOTHING;

-- IDENTITY DOMAIN
CREATE TABLE IF NOT EXISTS members (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  member_code VARCHAR(20) UNIQUE NOT NULL,
  full_name VARCHAR(100) NOT NULL,
  email VARCHAR(255) UNIQUE,
  phone VARCHAR(50) UNIQUE,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

DO $$ BEGIN
  CREATE TYPE token_type AS ENUM ('NOMINATION', 'VOTING');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS tokens (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  member_id UUID NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  token_hash VARCHAR(64) UNIQUE NOT NULL,
  type token_type NOT NULL,
  is_used BOOLEAN DEFAULT FALSE,
  used_at TIMESTAMPTZ,
  channel_sent VARCHAR(20) DEFAULT 'EMAIL',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_tokens_hash ON tokens(token_hash);

-- ANONYMOUS DOMAIN
CREATE TABLE IF NOT EXISTS anonymous_nominations (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  nominee_name VARCHAR(100) NOT NULL,
  reason TEXT,
  submitted_date DATE DEFAULT CURRENT_DATE
);

CREATE TABLE IF NOT EXISTS candidates (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  full_name VARCHAR(100) NOT NULL,
  statement TEXT,
  photo_url TEXT,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- BALLOTS with HMAC-signed ballot_id for verification
CREATE TABLE IF NOT EXISTS ballots (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  ballot_id TEXT UNIQUE NOT NULL,  -- HMAC-signed: payload || '.' || signature
  candidate_id UUID NOT NULL REFERENCES candidates(id),
  receipt_code VARCHAR(32) UNIQUE NOT NULL,
  channel VARCHAR(10) NOT NULL DEFAULT 'DIGITAL',
  cast_date DATE DEFAULT CURRENT_DATE
);

CREATE INDEX IF NOT EXISTS idx_ballots_receipt ON ballots(receipt_code);
CREATE INDEX IF NOT EXISTS idx_ballots_ballot_id ON ballots(ballot_id);

-- PAPER BALLOT STATE TRACKING
DO $$ BEGIN
  CREATE TYPE paper_ballot_status AS ENUM ('ISSUED', 'VOTED', 'SPOILED', 'MISSING');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS paper_ballots (
  ballot_id TEXT PRIMARY KEY,  -- HMAC-signed, matches ballots.ballot_id
  member_id UUID NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  status paper_ballot_status NOT NULL DEFAULT 'ISSUED',
  issued_at TIMESTAMPTZ DEFAULT NOW(),
  voted_at TIMESTAMPTZ,
  candidate_id UUID REFERENCES candidates(id),
  invalid_reason TEXT,
  short_code VARCHAR(14) UNIQUE NOT NULL,  -- e.g., "ABCD-1234-EF" (12 chars + checksum)
  qr_svg TEXT NOT NULL,  -- QR code SVG for pre-printing
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- One active (ISSUED or VOTED) paper ballot per member
CREATE UNIQUE INDEX IF NOT EXISTS idx_paper_ballots_one_active
  ON paper_ballots (member_id)
  WHERE status IN ('ISSUED', 'VOTED');

CREATE INDEX IF NOT EXISTS idx_paper_ballots_member ON paper_ballots(member_id);
CREATE INDEX IF NOT EXISTS idx_paper_ballots_short_code ON paper_ballots(short_code);

-- VOTE AUDIT LOG
CREATE TABLE IF NOT EXISTS vote_audit_log (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  action VARCHAR(50) NOT NULL,  -- 'DIGITAL_VOTE', 'PAPER_ISSUE', 'PAPER_VOTE', 'PAPER_INVALID', 'ADMIN_ACTION'
  member_id UUID REFERENCES members(id),
  ballot_id TEXT,
  candidate_id UUID REFERENCES candidates(id),
  admin_id UUID REFERENCES members(id),  -- admin who performed action
  details JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_vote_audit_log_member ON vote_audit_log(member_id);
CREATE INDEX IF NOT EXISTS idx_vote_audit_log_ballot ON vote_audit_log(ballot_id);
CREATE INDEX IF NOT EXISTS idx_vote_audit_log_created ON vote_audit_log(created_at);

-- ROW LEVEL SECURITY
ALTER TABLE members ENABLE ROW LEVEL SECURITY;
ALTER TABLE tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE election_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE candidates ENABLE ROW LEVEL SECURITY;
ALTER TABLE ballots ENABLE ROW LEVEL SECURITY;
ALTER TABLE paper_ballots ENABLE ROW LEVEL SECURITY;
ALTER TABLE vote_audit_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public can view candidates" ON candidates;
CREATE POLICY "Public can view candidates" ON candidates FOR SELECT USING (is_active = true);
DROP POLICY IF EXISTS "Public can view settings" ON election_settings;
CREATE POLICY "Public can view settings" ON election_settings FOR SELECT USING (true);
DROP POLICY IF EXISTS "Public can view receipt codes" ON ballots;
CREATE POLICY "Public can view receipt codes" ON ballots FOR SELECT USING (
  (SELECT current_phase FROM election_settings WHERE id = 1) IN ('VOTING_CLOSED', 'COMPLETED')
);
-- paper_ballots: no public access (admin only via service_role)
-- vote_audit_log: no public access (admin only via service_role)

-- PRIVATE SCHEMA for SECURITY DEFINER functions (NOT exposed via PostgREST)
CREATE SCHEMA IF NOT EXISTS private;

-- HMAC KEY for ballot_id signing (stored in vault, referenced via current_setting)
-- In production: store in Supabase Vault, retrieve via current_setting('app.ballot_hmac_key')
-- For now: use a placeholder; admin must set via ALTER SYSTEM or vault

-- HMAC helper: sign(payload) -> payload || '.' || hex(hmac_sha256(key, payload))
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
  v_key := current_setting('app.ballot_hmac_key', true);
  IF v_key IS NULL OR v_key = '' THEN
    RAISE EXCEPTION 'HMAC key not configured. Set app.ballot_hmac_key via ALTER SYSTEM or Supabase Vault.';
  END IF;
  v_sig := hmac(v_key::bytea, p_payload::bytea, 'sha256');
  RETURN p_payload || '.' || encode(v_sig, 'hex');
END;
$$;

-- HMAC helper: verify(ballot_id) -> payload if valid, else NULL
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
    RAISE EXCEPTION 'HMAC key not configured.';
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

-- Generate short code with Luhn checksum (12 chars: 4-4-4)
CREATE OR REPLACE FUNCTION private.generate_short_code()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_chars TEXT := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';  -- no I, O, 0, 1
  v_code TEXT := '';
  v_sum INT := 0;
  v_digit INT;
  v_checksum INT;
  i INT;
BEGIN
  -- Generate 11 random chars
  FOR i IN 1..11 LOOP
    v_code := v_code || substr(v_chars, floor(random() * length(v_chars) + 1)::int, 1);
  END LOOP;

  -- Luhn checksum on alphanumeric (map A=10, B=11, ...)
  FOR i IN REVERSE 1..11 LOOP
    v_digit := ascii(substr(v_code, i, 1));
    IF v_digit BETWEEN 48 AND 57 THEN  -- 0-9
      v_digit := v_digit - 48;
    ELSE  -- A-Z
      v_digit := v_digit - 55;  -- A=10
    END IF;

    IF (11 - i) % 2 = 0 THEN  -- double every second from right
      v_digit := v_digit * 2;
      IF v_digit > 35 THEN v_digit := v_digit - 35; END IF;  -- mod 36
    END IF;
    v_sum := v_sum + v_digit;
  END LOOP;

  v_checksum := (36 - (v_sum % 36)) % 36;
  IF v_checksum < 10 THEN
    v_code := v_code || chr(v_checksum + 48);
  ELSE
    v_code := v_code || chr(v_checksum + 55);
  END IF;

  -- Format as XXXX-XXXX-XX
  RETURN substr(v_code, 1, 4) || '-' || substr(v_code, 5, 4) || '-' || substr(v_code, 9, 4);
END;
$$;

-- Generate QR code SVG for ballot_id
CREATE OR REPLACE FUNCTION private.generate_qr_svg(p_ballot_id TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_qr TEXT;
BEGIN
  -- Simple QR SVG placeholder (in production, use a proper QR library)
  v_qr := '<svg xmlns="http://www.w3.org/2000/svg" width="200" height="200" viewBox="0 0 200 200">'
    || '<rect width="200" height="200" fill="white"/>'
    || '<text x="100" y="100" font-family="monospace" font-size="8" text-anchor="middle" dominant-baseline="middle">'
    || p_ballot_id
    || '</text></svg>';
  RETURN v_qr;
END;
$$;

-- ATOMIC STORED PROCEDURE FOR ANONYMOUS DIGITAL VOTING
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

  -- Generate HMAC-signed ballot_id: payload = member_id || ':' || candidate_id || ':' || timestamp || ':' || random
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

-- ISSUE PAPER BALLOT: creates paper_ballots record, returns ballot_id + QR + short_code
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

  -- Check if member already voted digitally
  IF EXISTS (
    SELECT 1 FROM tokens t
    WHERE t.member_id = v_member.id AND t.type = 'VOTING' AND t.is_used = TRUE
  ) THEN
    RETURN QUERY SELECT FALSE, 'Member has already voted digitally.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Check if member already has an active paper ballot
  IF EXISTS (
    SELECT 1 FROM paper_ballots
    WHERE member_id = v_member.id AND status IN ('ISSUED', 'VOTED')
  ) THEN
    RETURN QUERY SELECT FALSE, 'Member already has an active paper ballot.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Generate HMAC-signed ballot_id: payload = 'PAPER:' || member_id || ':' || timestamp || ':' || random
  v_payload := 'PAPER:' || v_member.id || ':' || extract(epoch FROM NOW())::bigint || ':' || encode(gen_random_bytes(8), 'hex');
  v_ballot_id := private.hmac_sign(v_payload);

  -- Generate unique short code
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

-- SUBMIT PAPER VOTE: verifies HMAC, paper-wins logic, marks VOTED
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
  -- Verify HMAC and get payload
  v_payload := private.hmac_verify(p_ballot_id);
  IF v_payload IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Invalid ballot ID (HMAC verification failed).'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Verify payload format: 'PAPER:' || member_id || ':' || timestamp || ':' || random
  IF NOT v_payload LIKE 'PAPER:%' THEN
    RETURN QUERY SELECT FALSE, 'Invalid ballot ID format.'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Lock paper ballot row
  SELECT * INTO v_paper FROM paper_ballots WHERE ballot_id = p_ballot_id FOR UPDATE;
  IF v_paper.ballot_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Ballot not found.'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  IF v_paper.status != 'ISSUED' THEN
    RETURN QUERY SELECT FALSE, 'Ballot already used or invalid (status: ' || v_paper.status || ').'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- PAPER WINS: If member voted digitally, delete the digital ballot
  SELECT t.id INTO v_digital_token FROM tokens t
  WHERE t.member_id = v_paper.member_id AND t.type = 'VOTING' AND t.is_used = TRUE
  FOR UPDATE;

  IF FOUND THEN
    -- Paper wins: we record the paper vote. The tally query deduplicates by member (preferring PAPER).
    -- For strict paper-wins, we could delete the digital ballot here, but we can't perfectly identify it.
    -- The tally handles deduplication.
    NULL;
  END IF;

  -- Generate receipt code for paper vote
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

  -- Mark paper ballot as VOTED
  UPDATE paper_ballots
  SET status = 'VOTED', voted_at = NOW(), candidate_id = p_candidate_id
  WHERE ballot_id = p_ballot_id;

  RETURN QUERY SELECT TRUE, 'Paper vote recorded.'::TEXT, v_receipt;
END;
$$;

-- SUBMIT PAPER INVALID: marks ballot as SPOILED with reason
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
  -- Verify HMAC
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

REVOKE EXECUTE ON FUNCTION private.submit_anonymous_vote(VARCHAR, UUID) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.issue_paper_ballot(UUID) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.submit_paper_vote(TEXT, UUID) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.submit_paper_invalid(TEXT, TEXT) FROM anon, authenticated;

-- GRANT EXECUTE to service_role (for admin API routes)
GRANT EXECUTE ON FUNCTION private.submit_anonymous_vote(VARCHAR, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION private.issue_paper_ballot(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION private.submit_paper_vote(TEXT, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION private.submit_paper_invalid(TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION private.hmac_sign(TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION private.hmac_verify(TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION private.generate_short_code() TO service_role;
GRANT EXECUTE ON FUNCTION private.generate_qr_svg(TEXT) TO service_role;