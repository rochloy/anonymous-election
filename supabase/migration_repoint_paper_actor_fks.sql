-- ============================================================================
-- migration_repoint_paper_actor_fks.sql
-- Fix: the paper-plane actor columns were FK'd to members(id), but the actor
-- is an admin whose identity is an admin_sessions.id. Passing an admin session
-- UUID FK-violated, so migration_paper_assign_phase_gate.sql had to STOP
-- writing paper_ballots.issued_by. Columns affected:
--   paper_ballots.issued_by / recorded_by / spoiled_by / voided_by
--   paper_ballot_batches.generated_by
--
-- Remediation (OpenSpec change: repoint-paper-actor-fks):
--   * Pre-check: all five columns MUST be entirely NULL (hard fail otherwise).
--   * Drop every existing FK on those columns (discovered dynamically, robust
--     to constraint-name drift), re-add as REFERENCES admin_sessions(id)
--     ON DELETE RESTRICT — same precedent as migration_fix_admin_id_fk.sql
--     (vote_audit_log.admin_id) and Wave 6 (anonymous_paper_blanks).
--   * RESTRICT (not SET NULL): once attribution is written it must not vanish
--     with a purged session; session lifecycle stays revoke-not-delete.
--
-- Does NOT re-enable RPC writes to these columns (separate decision).
-- Idempotent; safe to re-run. SETUP-phase maintenance only — do NOT apply
-- mid-election. Canonical run order: item 39 (seed.sql remains LAST).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. NULL pre-check + dynamic FK drop (one transaction-safe DO block)
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  r RECORD;
BEGIN
  -- Precondition: the repoint is only data-safe while these columns are empty.
  IF EXISTS (
    SELECT 1 FROM paper_ballots
    WHERE issued_by IS NOT NULL OR recorded_by IS NOT NULL
       OR spoiled_by IS NOT NULL OR voided_by IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'paper_ballots actor columns are not empty — investigate before repointing (expected all NULL)';
  END IF;
  IF EXISTS (SELECT 1 FROM paper_ballot_batches WHERE generated_by IS NOT NULL) THEN
    RAISE EXCEPTION 'paper_ballot_batches.generated_by is not empty — investigate before repointing (expected all NULL)';
  END IF;

  -- Drop every FK constraint on the target columns, whatever it is named.
  FOR r IN
    SELECT cls.relname AS table_name, con.conname
    FROM pg_constraint con
    JOIN pg_class cls      ON cls.oid = con.conrelid
    JOIN pg_namespace nsp  ON nsp.oid = cls.relnamespace
    JOIN pg_attribute att  ON att.attrelid = con.conrelid AND att.attnum = ANY(con.conkey)
    WHERE con.contype = 'f'
      AND nsp.nspname = 'public'
      AND (
        (cls.relname = 'paper_ballots'
           AND att.attname IN ('issued_by','recorded_by','spoiled_by','voided_by'))
        OR (cls.relname = 'paper_ballot_batches' AND att.attname = 'generated_by')
      )
  LOOP
    EXECUTE format('ALTER TABLE public.%I DROP CONSTRAINT %I', r.table_name, r.conname);
  END LOOP;
END $$;

-- ----------------------------------------------------------------------------
-- 2. Re-add FKs: -> admin_sessions(id) ON DELETE RESTRICT
-- ----------------------------------------------------------------------------
ALTER TABLE paper_ballots
  ADD CONSTRAINT paper_ballots_issued_by_fkey
  FOREIGN KEY (issued_by) REFERENCES admin_sessions(id) ON DELETE RESTRICT;

ALTER TABLE paper_ballots
  ADD CONSTRAINT paper_ballots_recorded_by_fkey
  FOREIGN KEY (recorded_by) REFERENCES admin_sessions(id) ON DELETE RESTRICT;

ALTER TABLE paper_ballots
  ADD CONSTRAINT paper_ballots_spoiled_by_fkey
  FOREIGN KEY (spoiled_by) REFERENCES admin_sessions(id) ON DELETE RESTRICT;

ALTER TABLE paper_ballots
  ADD CONSTRAINT paper_ballots_voided_by_fkey
  FOREIGN KEY (voided_by) REFERENCES admin_sessions(id) ON DELETE RESTRICT;

ALTER TABLE paper_ballot_batches
  ADD CONSTRAINT paper_ballot_batches_generated_by_fkey
  FOREIGN KEY (generated_by) REFERENCES admin_sessions(id) ON DELETE RESTRICT;

COMMENT ON COLUMN paper_ballots.issued_by IS
  'Admin session id -> admin_sessions(id) (NOT members). Unwritten until attribution writes are re-enabled. See migration_repoint_paper_actor_fks.sql.';
COMMENT ON COLUMN paper_ballots.recorded_by IS
  'Admin session id -> admin_sessions(id) (NOT members). Unwritten until attribution writes are re-enabled. See migration_repoint_paper_actor_fks.sql.';
COMMENT ON COLUMN paper_ballots.spoiled_by IS
  'Admin session id -> admin_sessions(id) (NOT members). Unwritten until attribution writes are re-enabled. See migration_repoint_paper_actor_fks.sql.';
COMMENT ON COLUMN paper_ballots.voided_by IS
  'Admin session id -> admin_sessions(id) (NOT members). Unwritten until attribution writes are re-enabled. See migration_repoint_paper_actor_fks.sql.';
COMMENT ON COLUMN paper_ballot_batches.generated_by IS
  'Admin session id -> admin_sessions(id) (NOT members). Unwritten until attribution writes are re-enabled. See migration_repoint_paper_actor_fks.sql.';
