-- MIGRATION FIX:
--   (1) "function gen_random_bytes(integer) does not exist" — pgcrypto lives in
--       the `extensions` schema on Supabase Cloud, so include it in search_path.
--   (2) "value too long for type character varying(128)" — ballot_id needs TEXT
--       and receipt_code needs VARCHAR(32).
--
-- This migration is intentionally defensive: it no-ops on databases where the
-- target columns already have the correct type, and skips gracefully if a table
-- or column is missing (instead of aborting the whole script).

-- 0. Ensure pgcrypto exists (no-op if already present)
CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA extensions;

-- 1. Widen ballot_id / receipt_code columns.
--    Each block is guarded so the migration succeeds regardless of starting state.

DO $migrate$
BEGIN
  -- ballots.ballot_id -> TEXT
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'ballots'
      AND column_name  = 'ballot_id'
      AND data_type    <> 'text'
  ) THEN
    ALTER TABLE public.ballots ALTER COLUMN ballot_id TYPE TEXT;
  END IF;

  -- ballots.receipt_code -> VARCHAR(32)
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'ballots'
      AND column_name  = 'receipt_code'
      AND (character_maximum_length IS NULL OR character_maximum_length < 32)
  ) THEN
    ALTER TABLE public.ballots ALTER COLUMN receipt_code TYPE VARCHAR(32);
  END IF;

  -- paper_ballots.ballot_id -> TEXT
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'paper_ballots'
      AND column_name  = 'ballot_id'
      AND data_type    <> 'text'
  ) THEN
    ALTER TABLE public.paper_ballots ALTER COLUMN ballot_id TYPE TEXT;
  END IF;

  -- vote_audit_log.ballot_id -> TEXT
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'vote_audit_log'
      AND column_name  = 'ballot_id'
      AND data_type    <> 'text'
  ) THEN
    ALTER TABLE public.vote_audit_log ALTER COLUMN ballot_id TYPE TEXT;
  END IF;
END
$migrate$;

-- 2. Update search_path on private-schema functions so gen_random_bytes resolves.
--    These ALTER FUNCTION calls are themselves idempotent in PostgreSQL.

DO $fixpaths$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc p
             JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'private' AND p.proname = 'issue_paper_ballot') THEN
    ALTER FUNCTION private.issue_paper_ballot(UUID)
      SET search_path = public, private, extensions;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_proc p
             JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'private' AND p.proname = 'submit_paper_vote') THEN
    ALTER FUNCTION private.submit_paper_vote(TEXT, UUID)
      SET search_path = public, private, extensions;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_proc p
             JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'private' AND p.proname = 'submit_paper_invalid') THEN
    ALTER FUNCTION private.submit_paper_invalid(TEXT, TEXT)
      SET search_path = public, private, extensions;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_proc p
             JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'private' AND p.proname = 'submit_anonymous_vote') THEN
    ALTER FUNCTION private.submit_anonymous_vote(VARCHAR, UUID)
      SET search_path = public, private, extensions;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_proc p
             JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'private' AND p.proname = 'hmac_sign') THEN
    ALTER FUNCTION private.hmac_sign(TEXT)
      SET search_path = public, private, extensions;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_proc p
             JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'private' AND p.proname = 'hmac_verify') THEN
    ALTER FUNCTION private.hmac_verify(TEXT)
      SET search_path = public, private, extensions;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_proc p
             JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'private' AND p.proname = 'generate_short_code') THEN
    ALTER FUNCTION private.generate_short_code()
      SET search_path = public, private, extensions;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_proc p
             JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'private' AND p.proname = 'generate_qr_svg') THEN
    ALTER FUNCTION private.generate_qr_svg(TEXT)
      SET search_path = public, private, extensions;
  END IF;
END
$fixpaths$;