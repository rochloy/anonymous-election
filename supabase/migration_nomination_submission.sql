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

-- Spec 2 dependency guarded now (spec §5 step 4): submit_nomination rejects
-- voided tokens, so the column must exist here. Spec 2 adds void_reason +
-- reissued_from_token_id + the single-active-token index; its ALTER TABLE tokens
-- MUST use ADD COLUMN IF NOT EXISTS for voided_at to avoid colliding with this.
ALTER TABLE tokens ADD COLUMN IF NOT EXISTS voided_at TIMESTAMPTZ NULL;

-- ============================================================================
-- Task 2: submit_nomination RPC (anonymous, in-transaction, canonicalized)
-- Mirrors submit_anonymous_vote: read phase -> lock token FOR UPDATE ->
-- insert anonymous rows only -> consume token. member_id is read ONLY to
-- validate the token; it is never inserted, returned, or logged.
-- ============================================================================
CREATE OR REPLACE FUNCTION private.submit_nomination(
  p_token_hash VARCHAR(64),
  p_nominees   JSONB
)
RETURNS TABLE (success BOOLEAN, message TEXT, inserted_count INT)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_phase election_phase; v_nom_start TIMESTAMPTZ; v_nom_end TIMESTAMPTZ;
  v_allow_write_ins BOOLEAN; v_max SMALLINT;
  v_token_id UUID; v_member_id UUID; v_is_used BOOLEAN;
  v_expires_at TIMESTAMPTZ; v_voided_at TIMESTAMPTZ;
  v_count INT; v_elem JSONB;
  v_nominee_member_id UUID; v_nominee_name TEXT; v_reason TEXT; v_norm TEXT;
  v_seen_members UUID[] := '{}'; v_seen_names TEXT[] := '{}'; v_inserted INT := 0;
BEGIN
  SELECT current_phase, nomination_start, nomination_end, allow_write_ins, max_nominees_per_member
    INTO v_phase, v_nom_start, v_nom_end, v_allow_write_ins, v_max
    FROM election_settings WHERE id = 1 FOR SHARE;   -- SEC-05: block admin phase-cutover UPDATE until this txn commits

  IF v_phase <> 'NOMINATION' THEN
    RETURN QUERY SELECT FALSE, 'Nomination phase is not open.'::TEXT, 0; RETURN; END IF;
  IF (v_nom_start IS NOT NULL AND NOW() < v_nom_start)
     OR (v_nom_end IS NOT NULL AND NOW() > v_nom_end) THEN
    RETURN QUERY SELECT FALSE, 'Nomination window is closed.'::TEXT, 0; RETURN; END IF;

  SELECT id, member_id, is_used, expires_at, voided_at
    INTO v_token_id, v_member_id, v_is_used, v_expires_at, v_voided_at
    FROM tokens WHERE token_hash = p_token_hash AND type = 'NOMINATION' FOR UPDATE;

  IF v_token_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Invalid or non-existent nomination token.'::TEXT, 0; RETURN; END IF;
  IF v_voided_at IS NOT NULL THEN
    RETURN QUERY SELECT FALSE, 'This nomination token has been voided.'::TEXT, 0; RETURN; END IF;
  IF v_expires_at IS NULL OR v_expires_at <= NOW() THEN
    RETURN QUERY SELECT FALSE, 'This nomination token has expired.'::TEXT, 0; RETURN; END IF;
  IF v_is_used THEN
    RETURN QUERY SELECT FALSE, 'This nomination token has already been used.'::TEXT, 0; RETURN; END IF;

  IF p_nominees IS NULL OR jsonb_typeof(p_nominees) <> 'array' THEN
    RETURN QUERY SELECT FALSE, 'Invalid nominees payload.'::TEXT, 0; RETURN; END IF;
  v_count := jsonb_array_length(p_nominees);
  IF v_count < 1 THEN
    RETURN QUERY SELECT FALSE, 'At least one nominee is required.'::TEXT, 0; RETURN; END IF;
  IF v_count > v_max THEN
    RETURN QUERY SELECT FALSE, format('At most %s nominee(s) allowed.', v_max)::TEXT, 0; RETURN; END IF;

  -- Validate ALL elements before inserting ANY (all-or-nothing).
  FOR v_elem IN SELECT * FROM jsonb_array_elements(p_nominees) LOOP
    v_nominee_member_id := NULLIF(v_elem->>'nominee_member_id','')::UUID;
    v_nominee_name := trim(coalesce(v_elem->>'nominee_name',''));
    v_reason := v_elem->>'reason';

    IF v_reason IS NOT NULL AND length(v_reason) > 2000 THEN
      RETURN QUERY SELECT FALSE, 'Reason exceeds 2000 characters.'::TEXT, 0; RETURN; END IF;

    IF v_nominee_member_id IS NOT NULL THEN
      SELECT full_name INTO v_nominee_name FROM members
        WHERE id = v_nominee_member_id AND is_active = TRUE;      -- canonicalize; ignore client name
      IF v_nominee_name IS NULL THEN
        RETURN QUERY SELECT FALSE, 'Nominee not found or inactive.'::TEXT, 0; RETURN; END IF;
      IF v_nominee_member_id = ANY(v_seen_members) THEN CONTINUE; END IF;
      v_seen_members := array_append(v_seen_members, v_nominee_member_id);
    ELSE
      IF NOT v_allow_write_ins THEN
        RETURN QUERY SELECT FALSE, 'Write-in nominees are not allowed.'::TEXT, 0; RETURN; END IF;
      IF v_nominee_name = '' THEN
        RETURN QUERY SELECT FALSE, 'Nominee name is required for write-ins.'::TEXT, 0; RETURN; END IF;
      IF length(v_nominee_name) > 100 THEN
        RETURN QUERY SELECT FALSE, 'Nominee name exceeds 100 characters.'::TEXT, 0; RETURN; END IF;
      v_norm := lower(v_nominee_name);
      IF v_norm = ANY(v_seen_names) THEN CONTINUE; END IF;
      v_seen_names := array_append(v_seen_names, v_norm);
    END IF;

    INSERT INTO anonymous_nominations (nominee_member_id, nominee_name, reason, source)
    VALUES (v_nominee_member_id, v_nominee_name, v_reason, 'DIGITAL');   -- NO nominator identity
    v_inserted := v_inserted + 1;
  END LOOP;

  UPDATE tokens SET is_used = TRUE, used_at = NOW() WHERE id = v_token_id;  -- consume
  RETURN QUERY SELECT TRUE, 'Nomination submitted.'::TEXT, v_inserted;
END;
$$;

REVOKE EXECUTE ON FUNCTION private.submit_nomination(VARCHAR, JSONB) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.submit_nomination(VARCHAR, JSONB) TO service_role;

-- ============================================================================
-- Task 3a: search_members_for_nomination (NON-consuming, token-gated roster search)
-- Read-only: validates token WITHOUT locking/consuming it. Returns minimal
-- fields (id + name) only, capped at 5, phase-gated to NOMINATION.
-- full_name cast to text: members.full_name is VARCHAR(100) but RETURNS TABLE
-- declares TEXT, and RETURN QUERY enforces exact type match.
-- ============================================================================
CREATE OR REPLACE FUNCTION private.search_members_for_nomination(
  p_token_hash VARCHAR(64), p_query TEXT
)
RETURNS TABLE (member_id UUID, full_name TEXT)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE v_phase election_phase; v_token_id UUID; v_is_used BOOLEAN;
        v_expires_at TIMESTAMPTZ; v_voided_at TIMESTAMPTZ;
BEGIN
  IF p_query IS NULL OR length(trim(p_query)) < 2 THEN RETURN; END IF;
  SELECT current_phase INTO v_phase FROM election_settings WHERE id=1;
  IF v_phase <> 'NOMINATION' THEN RETURN; END IF;

  SELECT id, is_used, expires_at, voided_at
    INTO v_token_id, v_is_used, v_expires_at, v_voided_at
    FROM tokens WHERE token_hash = p_token_hash AND type='NOMINATION';   -- NO row lock, NO update
  IF v_token_id IS NULL OR v_is_used OR v_voided_at IS NOT NULL
     OR v_expires_at IS NULL OR v_expires_at <= NOW() THEN RETURN; END IF;

  RETURN QUERY
    SELECT m.id, m.full_name::text FROM members m
    WHERE m.is_active = TRUE AND m.full_name % p_query          -- pg_trgm similarity operator
    ORDER BY similarity(m.full_name, p_query) DESC
    LIMIT 5;                                                    -- minimal fields only
END; $$;

REVOKE EXECUTE ON FUNCTION private.search_members_for_nomination(VARCHAR, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.search_members_for_nomination(VARCHAR, TEXT) TO service_role;

-- ============================================================================
-- Task 3b: admin_add_nomination (out-of-band, source=ADMIN)
-- Admin is TRUSTED. No token; phase-gated; canonicalizes member name; respects
-- allow_write_ins. source='ADMIN' distinguishes from DIGITAL submissions.
-- ============================================================================
CREATE OR REPLACE FUNCTION private.admin_add_nomination(
  p_nominee_member_id UUID, p_nominee_name TEXT, p_reason TEXT
)
RETURNS TABLE (success BOOLEAN, message TEXT)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE v_phase election_phase; v_allow BOOLEAN; v_name TEXT;
BEGIN
  SELECT current_phase, allow_write_ins INTO v_phase, v_allow FROM election_settings WHERE id=1;
  IF v_phase <> 'NOMINATION' THEN
    RETURN QUERY SELECT FALSE, 'Nomination phase is not open.'::TEXT; RETURN; END IF;
  IF p_reason IS NOT NULL AND length(p_reason) > 2000 THEN
    RETURN QUERY SELECT FALSE, 'Reason exceeds 2000 characters.'::TEXT; RETURN; END IF;

  IF p_nominee_member_id IS NOT NULL THEN
    SELECT full_name INTO v_name FROM members WHERE id=p_nominee_member_id AND is_active=TRUE;
    IF v_name IS NULL THEN
      RETURN QUERY SELECT FALSE, 'Nominee not found or inactive.'::TEXT; RETURN; END IF;
  ELSE
    IF NOT v_allow THEN
      RETURN QUERY SELECT FALSE, 'Write-in nominees are not allowed.'::TEXT; RETURN; END IF;
    v_name := trim(coalesce(p_nominee_name,''));
    IF v_name = '' THEN
      RETURN QUERY SELECT FALSE, 'Nominee name is required.'::TEXT; RETURN; END IF;
    IF length(v_name) > 100 THEN
      RETURN QUERY SELECT FALSE, 'Nominee name exceeds 100 characters.'::TEXT; RETURN; END IF;
  END IF;

  INSERT INTO anonymous_nominations (nominee_member_id, nominee_name, reason, source)
  VALUES (p_nominee_member_id, v_name, p_reason, 'ADMIN');
  RETURN QUERY SELECT TRUE, 'Nomination added.'::TEXT;
END; $$;

REVOKE EXECUTE ON FUNCTION private.admin_add_nomination(UUID, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.admin_add_nomination(UUID, TEXT, TEXT) TO service_role;
