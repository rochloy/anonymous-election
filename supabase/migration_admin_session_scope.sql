-- Migration: add scope to admin_sessions (v0.5.0)
--
-- Supports the mobile-assign feature: sessions minted for the phone use a
-- shorter absolute TTL and are tagged scope='mobile'. The /admin/mobile-assign
-- page requires a mobile-scoped session, so a normal 30-min desktop session
-- cannot be reused on the phone to bypass the shorter mobile TTL.
--
-- Existing rows default to 'desktop' (unchanged behavior for the dashboard).

ALTER TABLE admin_sessions
  ADD COLUMN IF NOT EXISTS scope TEXT NOT NULL DEFAULT 'desktop';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'admin_sessions_scope_chk'
  ) THEN
    ALTER TABLE admin_sessions
      ADD CONSTRAINT admin_sessions_scope_chk CHECK (scope IN ('desktop', 'mobile'));
  END IF;
END $$;
