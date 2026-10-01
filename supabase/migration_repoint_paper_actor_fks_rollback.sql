-- ============================================================================
-- migration_repoint_paper_actor_fks_rollback.sql
-- ROLLBACK for migration_repoint_paper_actor_fks.sql — returns
-- paper_ballot_batches.generated_by to REFERENCES members(id) (original
-- default NO ACTION delete semantics).
--
-- AUTHORED FOR EMERGENCY USE ONLY — DO NOT RUN as part of any normal
-- apply/reseed sequence. Only run if the forward migration must be undone
-- AND no admin attribution rows have been written to the column (the NULL
-- pre-check below enforces exactly that).
-- ============================================================================

DO $$
DECLARE
  r RECORD;
  fk_count INTEGER := 0;
  already_members_fk BOOLEAN := FALSE;
BEGIN
  FOR r IN
    SELECT cls.relname AS table_name, con.conname, refcls.relname AS referenced_table, refnsp.nspname AS referenced_schema
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
       AND r.referenced_table = 'members' THEN
      already_members_fk := TRUE;
    ELSE
      already_members_fk := FALSE;
    END IF;
  END LOOP;

  IF fk_count = 1 AND already_members_fk THEN
    RAISE NOTICE 'paper_ballot_batches.generated_by already references members(id); no-op';
    RETURN;
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
      AND cls.relname = 'paper_ballot_batches'
      AND att.attname = 'generated_by'
  LOOP
    EXECUTE format('ALTER TABLE public.%I DROP CONSTRAINT %I', r.table_name, r.conname);
  END LOOP;

  EXECUTE $sql$
    ALTER TABLE paper_ballot_batches
      ADD CONSTRAINT paper_ballot_batches_generated_by_fkey
      FOREIGN KEY (generated_by) REFERENCES members(id)
  $sql$;
END $$;
