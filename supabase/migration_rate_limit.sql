-- Rate limiting function for distributed rate limiting
-- Uses a simple sliding window with atomic increments

CREATE OR REPLACE FUNCTION check_rate_limit(
    p_identifier TEXT,
    p_window_seconds INT DEFAULT 60,
    p_max_requests INT DEFAULT 10
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
    v_now TIMESTAMPTZ := now();
    v_window_start TIMESTAMPTZ := v_now - (p_window_seconds || ' seconds')::INTERVAL;
    v_count INT;
    v_allowed BOOLEAN;
BEGIN
    -- Clean up old entries
    DELETE FROM rate_limit_hits
    WHERE identifier = p_identifier
    AND created_at < v_window_start;

    -- Count current hits in window
    SELECT COUNT(*) INTO v_count
    FROM rate_limit_hits
    WHERE identifier = p_identifier
    AND created_at >= v_window_start;

    v_allowed := v_count < p_max_requests;

    IF v_allowed THEN
        -- Insert new hit
        INSERT INTO rate_limit_hits (identifier, created_at)
        VALUES (p_identifier, v_now);
    END IF;

    RETURN jsonb_build_object(
        'allowed', v_allowed,
        'remaining', GREATEST(0, p_max_requests - v_count - (CASE WHEN v_allowed THEN 1 ELSE 0 END)),
        'reset_at', (v_now + (p_window_seconds || ' seconds')::INTERVAL)::TEXT
    );
END;
$$;

-- Table to store rate limit hits
CREATE TABLE IF NOT EXISTS rate_limit_hits (
    id BIGSERIAL PRIMARY KEY,
    identifier TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Index for efficient cleanup and counting
CREATE INDEX IF NOT EXISTS idx_rate_limit_hits_identifier_created 
ON rate_limit_hits(identifier, created_at);

-- Grant service_role access
GRANT ALL ON rate_limit_hits TO service_role;
GRANT EXECUTE ON FUNCTION check_rate_limit TO service_role;
