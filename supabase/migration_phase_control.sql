-- MIGRATION: Phase Control Tokens for Three-Level Confirmation
-- Run this in Supabase SQL Editor AFTER migration_option_e_paper_ballots_part2.sql

-- 0. Ensure required extensions exist
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 1. Create phase_change_tokens table for email-based confirmation
CREATE TABLE IF NOT EXISTS phase_change_tokens (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  token_hash VARCHAR(64) UNIQUE NOT NULL,
  from_phase election_phase NOT NULL,
  to_phase election_phase NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  used BOOLEAN DEFAULT FALSE,
  used_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Index for token lookup
CREATE INDEX IF NOT EXISTS idx_phase_change_tokens_hash ON phase_change_tokens(token_hash);
CREATE INDEX IF NOT EXISTS idx_phase_change_tokens_expires ON phase_change_tokens(expires_at);

-- 2. Enable RLS
ALTER TABLE phase_change_tokens ENABLE ROW LEVEL SECURITY;

-- 3. Grant to service_role
GRANT ALL ON phase_change_tokens TO service_role;

-- 4. Add trigger to update updated_at on election_settings
CREATE OR REPLACE FUNCTION update_election_settings_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_update_election_settings_updated_at ON election_settings;
CREATE TRIGGER trigger_update_election_settings_updated_at
  BEFORE UPDATE ON election_settings
  FOR EACH ROW EXECUTE FUNCTION update_election_settings_updated_at();

-- 5. Add trigger to validate phase transitions at DB level
CREATE OR REPLACE FUNCTION validate_phase_transition()
RETURNS TRIGGER AS $$
BEGIN
  -- Prevent transition from COMPLETED (except admin reset to SETUP)
  IF OLD.current_phase = 'COMPLETED' AND NEW.current_phase != 'COMPLETED' AND NEW.current_phase != 'SETUP' THEN
    RAISE EXCEPTION 'Cannot transition from COMPLETED';
  END IF;
  -- Prevent reopening voting after close
  IF OLD.current_phase = 'VOTING_CLOSED' AND NEW.current_phase = 'VOTING' THEN
    RAISE EXCEPTION 'Cannot reopen voting after VOTING_CLOSED';
  END IF;
  -- Prevent skipping phases (optional - can be relaxed if needed)
  -- Valid sequence: SETUP → NOMINATION → NOMINATION_CLOSED → VOTING → VOTING_CLOSED → COMPLETED
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_validate_phase_transition ON election_settings;
CREATE TRIGGER trigger_validate_phase_transition
  BEFORE UPDATE ON election_settings
  FOR EACH ROW EXECUTE FUNCTION validate_phase_transition();

-- MIGRATION COMPLETE