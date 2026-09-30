-- ============================================================================
-- migration_repoint_paper_actor_fks_rollback.sql
-- ROLLBACK for migration_repoint_paper_actor_fks.sql — returns the five
-- paper-plane actor FKs to REFERENCES members(id) (original default
-- NO ACTION delete semantics).
--
-- AUTHORED FOR EMERGENCY USE ONLY — DO NOT RUN as part of any normal
-- apply/reseed sequence. Only run if the forward migration must be undone
-- AND no admin attribution rows have been written to these columns (the
-- NULL pre-check below enforces exactly that).
-- ============================================================================

DO $$
DECLARE
  r RECORD;
BEGIN
  IF EXISTS (
    SELECT 1 FROM paper_ballots
    WHERE issued_by IS NOT NULL OR recorded_by IS NOT NULL
       OR spoiled_by IS NOT NULL OR voided_by IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'paper_ballots actor columns contain data — rollback would orphan attribution; do not proceed';
  END IF;
  IF EXISTS (SELECT 1 FROM paper_ballot_batches WHERE generated_by IS NOT NULL) THEN
    RAISE EXCEPTION 'paper_ballot_batches.generated_by contains data — rollback would orphan attribution; do not proceed';
  END IF;

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

ALTER TABLE paper_ballots
  ADD CONSTRAINT paper_ballots_issued_by_fkey
  FOREIGN KEY (issued_by) REFERENCES members(id);

ALTER TABLE paper_ballots
  ADD CONSTRAINT paper_ballots_recorded_by_fkey
  FOREIGN KEY (recorded_by) REFERENCES members(id);

ALTER TABLE paper_ballots
  ADD CONSTRAINT paper_ballots_spoiled_by_fkey
  FOREIGN KEY (spoiled_by) REFERENCES members(id);

ALTER TABLE paper_ballots
  ADD CONSTRAINT paper_ballots_voided_by_fkey
  FOREIGN KEY (voided_by) REFERENCES members(id);

ALTER TABLE paper_ballot_batches
  ADD CONSTRAINT paper_ballot_batches_generated_by_fkey
  FOREIGN KEY (generated_by) REFERENCES members(id);
