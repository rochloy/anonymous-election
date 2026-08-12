-- MIGRATION: Add ballot_id column to ballots table
-- The hardened schema.sql defines ballots with a ballot_id column (HMAC-signed),
-- but the original DB was created from an older schema without it.
-- This migration adds the missing column so the submit_anonymous_vote and
-- submit_paper_vote RPCs can insert ballot_id values.
--
-- Run this in Supabase SQL Editor if you get error:
--   42703: column "ballot_id" of relation "ballots" does not exist

-- Add the ballot_id column (TEXT, unique, nullable for existing rows)
ALTER TABLE ballots ADD COLUMN IF NOT EXISTS ballot_id TEXT UNIQUE;

-- Create index for ballot_id lookups (verify page)
CREATE INDEX IF NOT EXISTS idx_ballots_ballot_id ON ballots(ballot_id);

-- Optional: backfill existing rows with a placeholder (they have no ballot_id)
-- Only needed if you have existing ballots without a ballot_id and want NOT NULL later.
-- For now, leave nullable so existing rows are valid.
