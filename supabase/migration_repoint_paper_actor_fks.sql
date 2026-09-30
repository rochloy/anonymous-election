-- ============================================================================
-- migration_repoint_paper_actor_fks.sql
-- Fix: paper_ballot_batches.generated_by is FK'd to members(id), but the
-- actor is an admin whose identity is an admin_sessions.id. Passing an admin
-- session UUID FK-violates, so the column can never be legitimately written.
--
-- Scope note (live-DB verified 2026-09-30): the paper_ballots actor columns
-- (checked_in_by / spoiled_by / voided_by) were ALREADY repointed to
-- admin_sessions(id) ON DELETE RESTRICT by Wave 6 (migration_wave6_paper_severance.sql);
-- the pre-Wave-6 issued_by / recorded_by columns no longer exist. This
-- migration therefore repoints the ONE remaining wrong actor FK:
--   paper_ballot_batches.generated_by
--
-- Remediation (OpenSpec change: repoint-paper-actor-fks):
--   * Pre-check: generated_by MUST be entirely NULL (hard fail otherwise).
--   * Drop the existing FK dynamically (robust to constraint-name drift),
--     re-add as REFERENCES admin_sessions(id) ON DELETE RESTRICT — same
--     precedent as migration_fix_admin_id_fk.sql (vote_audit_log.admin_id)
--     and Wave 6 (paper_ballots.checked_in_by et al.).
--   * RESTRICT (not SET NULL): once attribution is written it must not vanish
--     with a purged session; session lifecycle stays revoke-not-delete.
--
-- Does NOT re-enable RPC writes to this column (separate decision).
-- Idempotent; safe to re-run. SETUP-phase maintenance only — do NOT apply
-- mid-election. Canonical run order: item 39 (after item 25).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. NULL pre-check + dynamic FK drop (one transaction-safe DO block)
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  r RECORD;
BEGIN
  -- Precondition: the repoint is only data-safe while the column is empty.
  IF EXISTS (SELECT 1 FROM paper_ballot_batches WHERE generated_by IS NOT NULL) THEN
    RAISE EXCEPTION 'paper_ballot_batches.generated_by is not empty — investigate before repointing (expected all NULL)';
  END IF;

  -- Drop every FK constraint on the target column, whatever it is named.
  FOR r IN
    SELECT cls.relname AS table_name, con.conname
    FROM pg_constraint con
    JOIN pg_class cls      ON cls.oid = con.conrelid
    JOIN pg_namespace nsp  ON nsp.oid = cls.relnamespace
    JOIN pg_attribute att  ON att.attrelid = con.conrelid AND att.attnum = ANY(con.conkey)
    WHERE con.contype = 'f'
      AND nsp.nspname = 'public'
      AND cls.relname = 'paper_ballot_batches'
      AND att.attname = 'generated_by'
  LOOP
    EXECUTE format('ALTER TABLE public.%I DROP CONSTRAINT %I', r.table_name, r.conname);
  END LOOP;
END $$;

-- ----------------------------------------------------------------------------
-- 2. Re-add FK: -> admin_sessions(id) ON DELETE RESTRICT
-- ----------------------------------------------------------------------------
ALTER TABLE paper_ballot_batches
  ADD CONSTRAINT paper_ballot_batches_generated_by_fkey
  FOREIGN KEY (generated_by) REFERENCES admin_sessions(id) ON DELETE RESTRICT;

COMMENT ON COLUMN paper_ballot_batches.generated_by IS
  'Admin session id -> admin_sessions(id) (NOT members). Unwritten until attribution writes are re-enabled. See migration_repoint_paper_actor_fks.sql.';
