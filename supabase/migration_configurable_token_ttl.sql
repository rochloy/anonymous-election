-- Additive/non-destructive migration: adds configurable voting token TTL; no re-seed needed.

ALTER TABLE election_settings
  ADD COLUMN IF NOT EXISTS voting_token_ttl_hours INT NOT NULL DEFAULT 168;

ALTER TABLE election_settings
  DROP CONSTRAINT IF EXISTS election_settings_voting_token_ttl_hours_check;

ALTER TABLE election_settings
  ADD CONSTRAINT election_settings_voting_token_ttl_hours_check
  CHECK (voting_token_ttl_hours BETWEEN 1 AND 2160);
