-- Add expires_at column to tokens table for token expiry
ALTER TABLE tokens ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ;

-- Index for efficient cleanup of expired tokens
CREATE INDEX IF NOT EXISTS idx_tokens_expires_at ON tokens(expires_at) WHERE expires_at IS NOT NULL;

-- Grant service_role access
GRANT ALL ON tokens TO service_role;
