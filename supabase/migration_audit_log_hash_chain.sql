-- Add hash chaining columns to vote_audit_log for tamper-evident audit trail
ALTER TABLE vote_audit_log 
ADD COLUMN IF NOT EXISTS record_hash CHAR(64),
ADD COLUMN IF NOT EXISTS previous_hash CHAR(64);

-- Index for efficient verification
CREATE INDEX IF NOT EXISTS idx_vote_audit_log_hash_chain ON vote_audit_log(record_hash, previous_hash);

-- Function to compute record hash
CREATE OR REPLACE FUNCTION compute_audit_log_hash(
    p_action TEXT,
    p_admin_id UUID,
    p_member_id UUID,
    p_details JSONB,
    p_previous_hash CHAR(64),
    p_created_at TIMESTAMPTZ
) RETURNS CHAR(64)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
    v_input TEXT;
    v_hash CHAR(64);
BEGIN
    v_input := p_action || '|' || COALESCE(p_admin_id::TEXT, '') || '|' || 
               COALESCE(p_member_id::TEXT, '') || '|' || 
               COALESCE(p_details::TEXT, '') || '|' || 
               COALESCE(p_previous_hash, '') || '|' || 
               p_created_at::TEXT;
    v_hash := encode(digest(v_input, 'sha256'), 'hex');
    RETURN v_hash;
END;
$$;

-- Function to insert audit log with hash chain
CREATE OR REPLACE FUNCTION insert_audit_log(
    p_action TEXT,
    p_admin_id UUID DEFAULT NULL,
    p_member_id UUID DEFAULT NULL,
    p_details JSONB DEFAULT '{}'::JSONB
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
    v_previous_hash CHAR(64);
    v_created_at TIMESTAMPTZ := now();
    v_record_hash CHAR(64);
BEGIN
    -- Get the previous record's hash
    SELECT record_hash INTO v_previous_hash
    FROM vote_audit_log
    ORDER BY created_at DESC
    LIMIT 1;

    -- Compute this record's hash
    v_record_hash := compute_audit_log_hash(p_action, p_admin_id, p_member_id, p_details, v_previous_hash, v_created_at);

    -- Insert the new record
    INSERT INTO vote_audit_log (action, admin_id, member_id, details, created_at, record_hash, previous_hash)
    VALUES (p_action, p_admin_id, p_member_id, p_details, v_created_at, v_record_hash, v_previous_hash);
END;
$$;

-- Grant execute permissions
GRANT EXECUTE ON FUNCTION compute_audit_log_hash TO service_role;
GRANT EXECUTE ON FUNCTION insert_audit_log TO service_role;

-- Grant permissions on new columns
GRANT ALL ON vote_audit_log TO service_role;
