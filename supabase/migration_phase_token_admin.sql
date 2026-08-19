-- Add admin_session_id to phase_change_tokens for binding tokens to admin sessions
ALTER TABLE phase_change_tokens ADD COLUMN IF NOT EXISTS admin_session_id UUID REFERENCES admin_sessions(id);

-- Index for efficient lookup
CREATE INDEX IF NOT EXISTS idx_phase_change_tokens_admin_session ON phase_change_tokens(admin_session_id);

-- Grant service_role access
GRANT ALL ON phase_change_tokens TO service_role;
