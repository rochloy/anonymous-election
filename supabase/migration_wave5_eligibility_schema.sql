-- Wave 5 migration 31: configurable voter eligibility (general voting_eligible + reason codes).
ALTER TABLE election_settings
  ADD COLUMN IF NOT EXISTS age_requirement_enabled BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS minimum_voting_age SMALLINT,
  ADD COLUMN IF NOT EXISTS undetermined_eligibility_defaults_ineligible BOOLEAN NOT NULL DEFAULT TRUE;

ALTER TABLE election_settings
  ADD CONSTRAINT election_settings_minimum_voting_age_check
    CHECK (minimum_voting_age IS NULL OR minimum_voting_age BETWEEN 0 AND 130),
  ADD CONSTRAINT election_settings_age_requirement_config_check
    CHECK (age_requirement_enabled = FALSE OR minimum_voting_age IS NOT NULL);

ALTER TABLE members
  ADD COLUMN IF NOT EXISTS voting_eligible    BOOLEAN NOT NULL DEFAULT TRUE,
  ADD COLUMN IF NOT EXISTS eligibility_reason TEXT    NOT NULL DEFAULT 'ELIGIBLE',
  ADD COLUMN IF NOT EXISTS eligibility_source TEXT    NOT NULL DEFAULT 'SYSTEM_DEFAULT',
  ADD COLUMN IF NOT EXISTS is_age_eligible    BOOLEAN,
  ADD COLUMN IF NOT EXISTS has_voted          BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE members
  ADD CONSTRAINT members_eligibility_reason_check CHECK (eligibility_reason IN (
    'ELIGIBLE','AGE_UNDER_MIN','NOT_A_MEMBER','MANUAL_ADMIN_HOLD','UNDETERMINED',
    'INACTIVE_MEMBER','PURGED')),
  ADD CONSTRAINT members_eligibility_source_check CHECK (eligibility_source IN (
    'SYSTEM_DEFAULT','CSV_IMPORT','ADMIN_ADJUDICATION','SYSTEM_RECOMPUTE','PURGE')),
  ADD CONSTRAINT members_eligibility_consistency_check CHECK (
    (voting_eligible = TRUE  AND eligibility_reason  = 'ELIGIBLE') OR
    (voting_eligible = FALSE AND eligibility_reason <> 'ELIGIBLE'));

CREATE INDEX IF NOT EXISTS idx_members_voting_eligible ON members(voting_eligible);

CREATE TABLE IF NOT EXISTS eligibility_adjudications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id UUID NOT NULL REFERENCES members(id) ON DELETE RESTRICT,
  admin_id  UUID REFERENCES admin_sessions(id) ON DELETE RESTRICT,
  old_voting_eligible BOOLEAN NOT NULL, old_eligibility_reason TEXT NOT NULL,
  old_eligibility_source TEXT NOT NULL, old_is_age_eligible BOOLEAN,
  new_voting_eligible BOOLEAN NOT NULL, new_eligibility_reason TEXT NOT NULL,
  new_eligibility_source TEXT NOT NULL, new_is_age_eligible BOOLEAN,
  note TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION private.reject_adjudication_mutation() RETURNS trigger
  LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'eligibility_adjudications is append-only'; END; $$;
DROP TRIGGER IF EXISTS trg_adjudication_no_update ON eligibility_adjudications;
CREATE TRIGGER trg_adjudication_no_update BEFORE UPDATE OR DELETE
  ON eligibility_adjudications FOR EACH ROW
  EXECUTE FUNCTION private.reject_adjudication_mutation();

ALTER TABLE eligibility_adjudications ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT ON eligibility_adjudications TO service_role;
