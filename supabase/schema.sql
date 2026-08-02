CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ELECTION SETTINGS & PHASES
CREATE TYPE election_phase AS ENUM (
  'SETUP', 'NOMINATION', 'NOMINATION_CLOSED', 'VOTING', 'VOTING_CLOSED', 'COMPLETED'
);

CREATE TABLE election_settings (
  id INT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  current_phase election_phase NOT NULL DEFAULT 'SETUP',
  nomination_start TIMESTAMPTZ,
  nomination_end TIMESTAMPTZ,
  voting_start TIMESTAMPTZ,
  voting_end TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

INSERT INTO election_settings (id, current_phase) VALUES (1, 'SETUP');

-- IDENTITY DOMAIN
CREATE TABLE members (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  member_code VARCHAR(20) UNIQUE NOT NULL,
  full_name VARCHAR(100) NOT NULL,
  email VARCHAR(255) UNIQUE,
  phone VARCHAR(50) UNIQUE,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TYPE token_type AS ENUM ('NOMINATION', 'VOTING');

CREATE TABLE tokens (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  member_id UUID NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  token_hash VARCHAR(64) UNIQUE NOT NULL,
  type token_type NOT NULL,
  is_used BOOLEAN DEFAULT FALSE,
  used_at TIMESTAMPTZ,
  channel_sent VARCHAR(20) DEFAULT 'EMAIL',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_tokens_hash ON tokens(token_hash);

-- ANONYMOUS DOMAIN
CREATE TABLE anonymous_nominations (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  nominee_name VARCHAR(100) NOT NULL,
  reason TEXT,
  submitted_date DATE DEFAULT CURRENT_DATE
);

CREATE TABLE candidates (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  full_name VARCHAR(100) NOT NULL,
  statement TEXT,
  photo_url TEXT,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE ballots (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  candidate_id UUID NOT NULL REFERENCES candidates(id),
  receipt_code VARCHAR(12) UNIQUE NOT NULL,
  channel VARCHAR(10) NOT NULL DEFAULT 'DIGITAL',
  cast_date DATE DEFAULT CURRENT_DATE
);

CREATE INDEX idx_ballots_receipt ON ballots(receipt_code);

-- ROW LEVEL SECURITY
ALTER TABLE members ENABLE ROW LEVEL SECURITY;
ALTER TABLE tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE election_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE candidates ENABLE ROW LEVEL SECURITY;
ALTER TABLE ballots ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Public can view candidates" ON candidates FOR SELECT USING (is_active = true);
CREATE POLICY "Public can view settings" ON election_settings FOR SELECT USING (true);
CREATE POLICY "Public can view receipt codes" ON ballots FOR SELECT USING (
  (SELECT current_phase FROM election_settings WHERE id = 1) IN ('VOTING_CLOSED', 'COMPLETED')
);

-- PRIVATE SCHEMA for SECURITY DEFINER functions (NOT exposed via PostgREST)
CREATE SCHEMA IF NOT EXISTS private;

-- ATOMIC STORED PROCEDURE FOR ANONYMOUS VOTING
CREATE OR REPLACE FUNCTION private.submit_anonymous_vote(
  p_token_hash VARCHAR(64),
  p_candidate_id UUID
)
RETURNS TABLE (success BOOLEAN, message TEXT, receipt_code TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private
AS $$
DECLARE
  v_token_id UUID;
  v_is_used BOOLEAN;
  v_phase election_phase;
  v_voting_end TIMESTAMPTZ;
  v_receipt TEXT;
  v_attempts INT := 0;
  v_insert_ok BOOLEAN := FALSE;
BEGIN
  SELECT current_phase, voting_end INTO v_phase, v_voting_end FROM election_settings WHERE id = 1;

  IF v_phase != 'VOTING' OR (v_voting_end IS NOT NULL AND NOW() > v_voting_end) THEN
    RETURN QUERY SELECT FALSE, 'Voting phase is closed or expired.'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  SELECT id, is_used INTO v_token_id, v_is_used FROM tokens
  WHERE token_hash = p_token_hash AND type = 'VOTING' FOR UPDATE;

  IF v_token_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Invalid or non-existent voting token.'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  IF v_is_used THEN
    RETURN QUERY SELECT FALSE, 'This token has already been used to vote.'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  WHILE v_attempts < 5 AND NOT v_insert_ok LOOP
    v_receipt := 'VC-' || encode(gen_random_bytes(5), 'hex');
    BEGIN
      INSERT INTO ballots (candidate_id, receipt_code, channel, cast_date)
      VALUES (p_candidate_id, v_receipt, 'DIGITAL', CURRENT_DATE);
      v_insert_ok := TRUE;
    EXCEPTION WHEN unique_violation THEN
      v_attempts := v_attempts + 1;
    END;
  END LOOP;

  IF NOT v_insert_ok THEN
    RETURN QUERY SELECT FALSE, 'Could not generate unique receipt code after 5 attempts.'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  UPDATE tokens SET is_used = TRUE, used_at = NOW() WHERE id = v_token_id;

  RETURN QUERY SELECT TRUE, 'Vote cast successfully.'::TEXT, v_receipt;
END;
$$;

-- PAPER BALLOT RPC
CREATE OR REPLACE FUNCTION private.submit_paper_vote(
  p_member_code VARCHAR(20),
  p_candidate_id UUID
)
RETURNS TABLE (success BOOLEAN, message TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private
AS $$
DECLARE
  v_member RECORD;
  v_token RECORD;
  v_receipt TEXT;
  v_attempts INT := 0;
  v_insert_ok BOOLEAN := FALSE;
BEGIN
  SELECT id, full_name INTO v_member FROM members WHERE member_code = p_member_code AND is_active = TRUE;
  IF v_member.id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Member code not found.'::TEXT;
    RETURN;
  END IF;

  SELECT id, is_used INTO v_token FROM tokens
  WHERE member_id = v_member.id AND type = 'VOTING' FOR UPDATE;

  IF v_token.id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'No voting token found for this member.'::TEXT;
    RETURN;
  END IF;

  IF v_token.is_used THEN
    RETURN QUERY SELECT FALSE, ('Member ' || v_member.full_name || ' has already voted.')::TEXT;
    RETURN;
  END IF;

  WHILE v_attempts < 5 AND NOT v_insert_ok LOOP
    v_receipt := 'PB-' || encode(gen_random_bytes(5), 'hex');
    BEGIN
      INSERT INTO ballots (candidate_id, receipt_code, channel, cast_date)
      VALUES (p_candidate_id, v_receipt, 'PAPER', CURRENT_DATE);
      v_insert_ok := TRUE;
    EXCEPTION WHEN unique_violation THEN
      v_attempts := v_attempts + 1;
    END;
  END LOOP;

  IF NOT v_insert_ok THEN
    RETURN QUERY SELECT FALSE, 'Could not generate unique receipt code.'::TEXT;
    RETURN;
  END IF;

  UPDATE tokens SET is_used = TRUE, used_at = NOW(), channel_sent = 'PAPER' WHERE id = v_token.id;

  RETURN QUERY SELECT TRUE, ('Paper vote recorded for ' || v_member.full_name || '.')::TEXT;
END;
$$;

REVOKE EXECUTE ON FUNCTION private.submit_anonymous_vote(VARCHAR, UUID) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.submit_paper_vote(VARCHAR, UUID) FROM anon, authenticated;
