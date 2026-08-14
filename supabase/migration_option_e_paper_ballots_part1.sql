-- MIGRATION PART 1: Option E - Schema Changes & Enum Additions
-- Run this FIRST in Supabase SQL Editor
-- After: migration_fix_service_role_grants.sql
-- Before: migration_option_e_paper_ballots_part2.sql

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

-- 4. Create basic indexes for Option E (no enum references)
CREATE INDEX IF NOT EXISTS idx_paper_ballots_batch ON paper_ballots(batch_id);
CREATE INDEX IF NOT EXISTS idx_paper_ballots_status ON paper_ballots(status);

-- 5. Enable RLS on paper_ballot_batches
ALTER TABLE paper_ballot_batches ENABLE ROW LEVEL SECURITY;

-- Grant table access to service_role
GRANT ALL ON paper_ballot_batches TO service_role;
GRANT ALL ON paper_ballots TO service_role;

-- PART 1 COMPLETE
-- Now run migration_option_e_paper_ballots_part2.sql