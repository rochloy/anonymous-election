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
-- Re-running is a no-op once already repointed (even after attribution data
-- exists), and the whole migration is one DO block so any failure rolls back
-- completely. SETUP-phase maintenance only — do NOT apply
-- mid-election. Canonical run order: item 39 (after item 25).
-- ============================================================================

DO $$
DECLARE
  r RECORD;
  fk_count INTEGER := 0;
  already_repointed BOOLEAN := FALSE;
BEGIN
  -- Discover every FK constraint on the target column and detect if already repointed.
  FOR r IN
    SELECT cls.relname AS table_name, con.conname, refcls.relname AS referenced_table, refnsp.nspname AS referenced_schema, con.confdeltype
    FROM pg_constraint con
    JOIN pg_class cls         ON cls.oid = con.conrelid
    JOIN pg_namespace nsp     ON nsp.oid = cls.relnamespace
    JOIN pg_attribute att     ON att.attrelid = con.conrelid AND att.attnum = ANY(con.conkey)
    JOIN pg_class refcls      ON refcls.oid = con.confrelid
    JOIN pg_namespace refnsp  ON refnsp.oid = refcls.relnamespace
    WHERE con.contype = 'f'
      AND nsp.nspname = 'public'
      AND cls.relname = 'paper_ballot_batches'
      AND att.attname = 'generated_by'
  LOOP
    fk_count := fk_count + 1;
    IF fk_count = 1
       AND r.referenced_schema = 'public'
       AND r.referenced_table = 'admin_sessions'
       AND r.confdeltype = 'r' THEN
      already_repointed := TRUE;
    ELSE
      already_repointed := FALSE;
    END IF;
  END LOOP;

  IF fk_count = 1 AND already_repointed THEN
    RAISE NOTICE 'paper_ballot_batches.generated_by already references admin_sessions(id) ON DELETE RESTRICT; no-op';
    RETURN;
  END IF;

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

  EXECUTE $sql$
    ALTER TABLE paper_ballot_batches
      ADD CONSTRAINT paper_ballot_batches_generated_by_fkey
      FOREIGN KEY (generated_by) REFERENCES admin_sessions(id) ON DELETE RESTRICT
  $sql$;

  EXECUTE $sql$
    COMMENT ON COLUMN paper_ballot_batches.generated_by IS
      'Admin session id -> admin_sessions(id) (NOT members). Unwritten until attribution writes are re-enabled. See migration_repoint_paper_actor_fks.sql.'
  $sql$;
END $$;
