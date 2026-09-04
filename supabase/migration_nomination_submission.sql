-- migration_nomination_submission.sql  (Spec 1) — run AFTER the CANONICAL sequence.
-- Idempotent (IF NOT EXISTS / OR REPLACE) so it re-applies cleanly at the Option-B wipe.
-- Extensions: Supabase installs pg_trgm into the `extensions` schema.
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- 1. anonymous_nominations: add nominee link + provenance
ALTER TABLE anonymous_nominations
  ADD COLUMN IF NOT EXISTS nominee_member_id UUID REFERENCES members(id) NULL,
  ADD COLUMN IF NOT EXISTS source TEXT NOT NULL DEFAULT 'DIGITAL'
    CHECK (source IN ('DIGITAL','ADMIN'));

-- trigram index for roster name search
CREATE INDEX IF NOT EXISTS idx_members_full_name_trgm
  ON members USING gin (full_name gin_trgm_ops);

-- 2. RLS lockdown (base schema never enabled RLS on this table)
ALTER TABLE anonymous_nominations ENABLE ROW LEVEL SECURITY;  -- no public policy
GRANT SELECT, INSERT ON anonymous_nominations TO service_role;

-- 3. Immutability trigger (append-only; TRUNCATE for wipes is unaffected)
CREATE OR REPLACE FUNCTION private.reject_nomination_mutation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'anonymous_nominations rows are immutable (append-only).';
END; $$;

DROP TRIGGER IF EXISTS trg_nominations_immutable ON anonymous_nominations;
CREATE TRIGGER trg_nominations_immutable
  BEFORE UPDATE OR DELETE ON anonymous_nominations
  FOR EACH ROW EXECUTE FUNCTION private.reject_nomination_mutation();

-- 4. election_settings config
ALTER TABLE election_settings
  ADD COLUMN IF NOT EXISTS allow_write_ins BOOLEAN NOT NULL DEFAULT TRUE,
  ADD COLUMN IF NOT EXISTS max_nominees_per_member SMALLINT NOT NULL DEFAULT 1
    CHECK (max_nominees_per_member BETWEEN 1 AND 3);

-- 5. Admin adjudication provenance (never links a nominator)
CREATE TABLE IF NOT EXISTS nomination_adjudications (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  admin_id UUID REFERENCES members(id),
  decision TEXT NOT NULL CHECK (decision IN ('PROMOTE','MERGE','DISCARD')),
  candidate_id UUID REFERENCES candidates(id),
  nominee_member_id UUID REFERENCES members(id),
  affected_nomination_ids UUID[] NOT NULL DEFAULT '{}',
  note TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE nomination_adjudications ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT ON nomination_adjudications TO service_role;

-- Idempotent promotion: at most one PROMOTE candidate per matched nominee
CREATE UNIQUE INDEX IF NOT EXISTS idx_adjudication_one_promote_per_nominee
  ON nomination_adjudications (nominee_member_id)
  WHERE decision = 'PROMOTE' AND nominee_member_id IS NOT NULL;
