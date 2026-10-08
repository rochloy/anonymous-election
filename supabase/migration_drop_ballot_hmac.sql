-- migration_drop_ballot_hmac.sql
--
-- Option E (council verdict 2026-10-08, 2-1 with synthesis): REMOVE the ballot
-- HMAC layer entirely instead of re-provisioning its key.
--
-- Why this is safe -- the signature never gated anything:
--   * Every hmac_verify caller (correct_paper_vote, submit_paper_vote,
--     void_anonymous_paper_blank) follows the check with an exact-match lookup
--     in anonymous_paper_blanks, a server-only pool whose IDs are
--     256 CSPRNG bits the key does not influence. A forged ID is an ID that is
--     not in the pool, and is rejected there regardless of signature validity.
--   * f4_verify_ballot (the public verification surface) never checked the
--     signature at all.
--   * The digital writers signed IDs that nothing ever verified.
-- The anti-guessing control is the 256-bit random payload, which is retained.
--
-- Ballot ID format changes from  PAPER:<64hex>.<64hex-sig>  (~135 chars)
-- to                              PAPER:<64hex>            (~70 chars).
-- Applied pre-election: database is in SETUP phase, anonymous_paper_blanks is
-- empty, nothing has been printed. REQUIRES an app redeploy (lib/ballot.ts
-- shape regex) BEFORE VOTING opens.
--
-- Also fixes: generate_short_code used non-crypto random() (council finding).
-- The 32-char alphabet makes 256 % 32 == 0, so a single gen_random_bytes(1)
-- byte mod 32 is a perfectly uniform index.
--
-- The five modified RPC bodies below are extracted verbatim from the live
-- hosted schema and altered by exactly one sed rule each (verified by the
-- fail-closed post-conditions at the end of this file).
BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Paper ID generator: no signature, same opaque 256-bit payload.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.generate_opaque_paper_ballot_id() RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
    AS $$
BEGIN
  -- Opaque, unguessable, key-independent paper ballot ID. The v0.3.0
  -- opaque-payload design is unchanged; only the HMAC signature layer
  -- (which gated nothing -- see file header) is removed.
  RETURN 'PAPER:' || encode(gen_random_bytes(32), 'hex');
END;
$$;

-- ---------------------------------------------------------------------------
-- 2. Digital writer: cast_anonymous_digital_vote (verbatim, 1-line change).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.cast_anonymous_digital_vote(p_credential text, p_candidate_id uuid) RETURNS TABLE(o_success boolean, o_message text, o_receipt_code text, o_ballot_id text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
    AS $$
DECLARE
  v_credential_hash TEXT; v_cred_id UUID; v_cred_status VARCHAR(10); v_token_id UUID;
  v_res_id UUID; v_res_expires TIMESTAMPTZ; v_token_is_used BOOLEAN; v_token_voided TIMESTAMPTZ;
  v_phase election_phase; v_voting_end TIMESTAMPTZ; v_receipt TEXT; v_ballot_id TEXT; v_payload TEXT;
  v_attempts INT := 0; v_insert_ok BOOLEAN := FALSE;
BEGIN
  PERFORM private.sweep_expired_digital_reservations();

  SELECT current_phase, voting_end INTO v_phase, v_voting_end FROM election_settings WHERE id = 1;
  IF v_phase != 'VOTING' OR (v_voting_end IS NOT NULL AND NOW() > v_voting_end) THEN
    RETURN QUERY SELECT FALSE, 'Voting phase is closed or expired.'::TEXT, NULL::TEXT, NULL::TEXT; RETURN;
  END IF;

  v_credential_hash := encode(digest(p_credential, 'sha256'), 'hex');

  SELECT id, status INTO v_cred_id, v_cred_status FROM anonymous_digital_credentials
   WHERE credential_hash = v_credential_hash FOR UPDATE;
  IF v_cred_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Invalid voting credential.'::TEXT, NULL::TEXT, NULL::TEXT; RETURN;
  END IF;
  IF v_cred_status = 'CAST' THEN
    RETURN QUERY SELECT FALSE, 'This credential has already been used to cast a vote.'::TEXT, NULL::TEXT, NULL::TEXT; RETURN;
  END IF;

  SELECT id, token_id, expires_at INTO v_res_id, v_token_id, v_res_expires
    FROM digital_credential_reservations WHERE credential_hash = v_credential_hash FOR UPDATE;
  IF v_res_id IS NULL OR v_res_expires <= now() THEN
    RETURN QUERY SELECT FALSE, 'This credential has expired. Please request a new voting link.'::TEXT, NULL::TEXT, NULL::TEXT; RETURN;
  END IF;

  SELECT is_used, voided_at INTO v_token_is_used, v_token_voided FROM tokens WHERE id = v_token_id FOR UPDATE;
  IF NOT FOUND OR v_token_voided IS NOT NULL OR v_token_is_used IS TRUE THEN
    RETURN QUERY SELECT FALSE, 'Voting entitlement is no longer valid.'::TEXT, NULL::TEXT, NULL::TEXT; RETURN;
  END IF;

  v_payload := 'DIGITAL:' || encode(gen_random_bytes(32), 'hex');
  v_ballot_id := v_payload;

  WHILE v_attempts < 5 AND NOT v_insert_ok LOOP
    v_receipt := 'VC-' || encode(gen_random_bytes(5), 'hex');
    BEGIN
      INSERT INTO ballots (ballot_id, candidate_id, receipt_code, channel, cast_date)
      VALUES (v_ballot_id, p_candidate_id, v_receipt, 'DIGITAL', CURRENT_DATE);
      v_insert_ok := TRUE;
    EXCEPTION WHEN unique_violation THEN
      v_attempts := v_attempts + 1;
    END;
  END LOOP;

  IF NOT v_insert_ok THEN
    RETURN QUERY SELECT FALSE, 'Could not generate unique receipt code after 5 attempts.'::TEXT, NULL::TEXT, NULL::TEXT; RETURN;
  END IF;

  UPDATE anonymous_digital_credentials SET status = 'CAST', cast_at = now() WHERE id = v_cred_id;

  UPDATE tokens SET is_used = TRUE, used_at = now(), channel_sent = 'DIGITAL', reserved_channel = 'DIGITAL'
   WHERE id = v_token_id;

  DELETE FROM digital_credential_reservations WHERE id = v_res_id;

  RETURN QUERY SELECT TRUE, 'Vote cast successfully.'::TEXT, v_receipt, v_ballot_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 3. Digital writer: submit_anonymous_vote (verbatim, 1-line change).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.submit_anonymous_vote(p_token_hash character varying, p_candidate_id uuid) RETURNS TABLE(success boolean, message text, receipt_code text, ballot_id text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
    AS $$
DECLARE
  v_token_id UUID; v_member_id UUID; v_is_used BOOLEAN; v_expires_at TIMESTAMPTZ; v_voided_at TIMESTAMPTZ;
  v_phase election_phase; v_voting_end TIMESTAMPTZ; v_receipt TEXT; v_ballot_id TEXT; v_payload TEXT;
  v_attempts INT := 0; v_insert_ok BOOLEAN := FALSE; v_paper_ballot RECORD; v_voting_eligible BOOLEAN;
  v_digital_mode VARCHAR(16);
BEGIN
  SELECT current_phase, voting_end, COALESCE(digital_write_mode, 'LEGACY')
    INTO v_phase, v_voting_end, v_digital_mode FROM election_settings WHERE id = 1;

  IF v_digital_mode = 'TWO_PHASE' THEN
    RETURN QUERY SELECT FALSE, 'Digital voting now uses a two-step secure flow. Please reopen your voting link.'::TEXT, NULL::TEXT, NULL::TEXT; RETURN;
  END IF;

  IF v_phase != 'VOTING' OR (v_voting_end IS NOT NULL AND NOW() > v_voting_end) THEN
    RETURN QUERY SELECT FALSE, 'Voting phase is closed or expired.'::TEXT, NULL::TEXT, NULL::TEXT; RETURN;
  END IF;

  SELECT id, member_id, is_used, expires_at, voided_at INTO v_token_id, v_member_id, v_is_used, v_expires_at, v_voided_at
    FROM tokens WHERE token_hash = p_token_hash AND type = 'VOTING' FOR UPDATE;

  IF v_token_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Invalid or non-existent voting token.'::TEXT, NULL::TEXT, NULL::TEXT; RETURN;
  END IF;
  IF v_voided_at IS NOT NULL THEN
    RETURN QUERY SELECT FALSE, 'This voting token has been voided and reissued. Please use your most recent link.'::TEXT, NULL::TEXT, NULL::TEXT; RETURN;
  END IF;
  IF v_expires_at IS NULL OR v_expires_at <= NOW() THEN
    RETURN QUERY SELECT FALSE, 'This voting token has expired.'::TEXT, NULL::TEXT, NULL::TEXT; RETURN;
  END IF;
  IF v_is_used THEN
    RETURN QUERY SELECT FALSE, 'This token has already been used or reserved for paper voting.'::TEXT, NULL::TEXT, NULL::TEXT; RETURN;
  END IF;

  SELECT voting_eligible INTO v_voting_eligible FROM members WHERE id = v_member_id AND is_active = TRUE FOR SHARE;
  IF NOT FOUND OR v_voting_eligible IS NOT TRUE THEN
    RETURN QUERY SELECT FALSE, 'Member is not eligible to vote.'::TEXT, NULL::TEXT, NULL::TEXT; RETURN;
  END IF;

  SELECT * INTO v_paper_ballot FROM paper_ballots
  WHERE member_id = v_member_id AND status IN ('ISSUED', 'ISSUED_TO_VOTER', 'VOTED') FOR SHARE;
  IF FOUND THEN
    RETURN QUERY SELECT FALSE, 'A paper ballot has already been issued for this member.'::TEXT, NULL::TEXT, NULL::TEXT; RETURN;
  END IF;

  v_payload := 'DIGITAL:' || encode(gen_random_bytes(32), 'hex');
  v_ballot_id := v_payload;

  WHILE v_attempts < 5 AND NOT v_insert_ok LOOP
    v_receipt := 'VC-' || encode(gen_random_bytes(5), 'hex');
    BEGIN
      INSERT INTO ballots (ballot_id, candidate_id, receipt_code, channel, cast_date)
      VALUES (v_ballot_id, p_candidate_id, v_receipt, 'DIGITAL', CURRENT_DATE);
      v_insert_ok := TRUE;
    EXCEPTION WHEN unique_violation THEN
      v_attempts := v_attempts + 1;
    END;
  END LOOP;

  IF NOT v_insert_ok THEN
    RETURN QUERY SELECT FALSE, 'Could not generate unique receipt code after 5 attempts.'::TEXT, NULL::TEXT, NULL::TEXT; RETURN;
  END IF;

  UPDATE tokens SET is_used = TRUE, used_at = NOW() WHERE id = v_token_id;

  RETURN QUERY SELECT TRUE, 'Vote cast successfully.'::TEXT, v_receipt, v_ballot_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. Paper RPC: correct_paper_vote (verbatim, 2-line change).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.correct_paper_vote(p_ballot_id text, p_new_candidate_id uuid, p_admin_id uuid DEFAULT NULL::uuid, p_reason text DEFAULT NULL::text) RETURNS TABLE(success boolean, message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
    AS $$
DECLARE
  v_payload TEXT;
  v_ballot RECORD;
  v_candidate_exists BOOLEAN;
BEGIN
  v_payload := p_ballot_id;

  IF v_payload IS NULL OR v_payload !~ '^PAPER:[0-9a-f]{64}$' THEN
    RETURN QUERY SELECT FALSE, 'Invalid paper ballot ID.'::TEXT;
    RETURN;
  END IF;

  SELECT * INTO v_ballot FROM ballots WHERE ballot_id = p_ballot_id AND channel = 'PAPER' FOR UPDATE;

  IF v_ballot.id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Paper ballot not found.'::TEXT;
    RETURN;
  END IF;

  SELECT EXISTS (SELECT 1 FROM candidates WHERE id = p_new_candidate_id AND is_active = TRUE) INTO v_candidate_exists;

  IF v_candidate_exists IS NOT TRUE THEN
    RETURN QUERY SELECT FALSE, 'Candidate not found or inactive.'::TEXT;
    RETURN;
  END IF;

  UPDATE ballots SET candidate_id = p_new_candidate_id WHERE id = v_ballot.id;

  INSERT INTO ballot_audit_log(action, ballot_id, channel, event_date, old_candidate_id, new_candidate_id, admin_id, details)
  VALUES ('PAPER_BALLOT_CORRECTED', p_ballot_id, 'PAPER', CURRENT_DATE, v_ballot.candidate_id, p_new_candidate_id, p_admin_id,
    jsonb_build_object('reason', COALESCE(p_reason, 'not specified')));

  RETURN QUERY SELECT TRUE, 'Paper vote corrected.'::TEXT;
END;
$$;

-- ---------------------------------------------------------------------------
-- 5. Paper RPC: submit_paper_vote (verbatim, 2-line change).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.submit_paper_vote(p_ballot_id text, p_candidate_id uuid, p_admin_id uuid DEFAULT NULL::uuid) RETURNS TABLE(success boolean, message text, receipt_code text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
    AS $$
DECLARE
  v_payload TEXT;
  v_blank RECORD;
  v_candidate_exists BOOLEAN;
  v_receipt TEXT;
  v_attempts INTEGER := 0;
  v_insert_ok BOOLEAN := FALSE;
  v_updated INTEGER := 0;
BEGIN
  v_payload := p_ballot_id;

  IF v_payload IS NULL OR v_payload !~ '^PAPER:[0-9a-f]{64}$' THEN
    RETURN QUERY SELECT FALSE, 'Invalid paper ballot ID.'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  SELECT * INTO v_blank FROM anonymous_paper_blanks WHERE ballot_id = p_ballot_id FOR UPDATE;

  IF v_blank.ballot_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Paper ballot is not from the anonymous blank pool.'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  IF v_blank.status <> 'AVAILABLE' THEN
    RETURN QUERY SELECT FALSE, 'Paper ballot has already been cast or voided.'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  SELECT EXISTS (SELECT 1 FROM candidates WHERE id = p_candidate_id AND is_active = TRUE) INTO v_candidate_exists;

  IF v_candidate_exists IS NOT TRUE THEN
    RETURN QUERY SELECT FALSE, 'Candidate not found or inactive.'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  IF EXISTS (SELECT 1 FROM ballots WHERE ballot_id = p_ballot_id) THEN
    RETURN QUERY SELECT FALSE, 'Paper ballot already exists in anonymous ballots.'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  WHILE v_attempts < 10 AND NOT v_insert_ok LOOP
    v_receipt := 'PB-' || encode(gen_random_bytes(5), 'hex');
    BEGIN
      INSERT INTO ballots(ballot_id, candidate_id, receipt_code, channel, cast_date)
      VALUES (p_ballot_id, p_candidate_id, v_receipt, 'PAPER', CURRENT_DATE);
      v_insert_ok := TRUE;
    EXCEPTION WHEN unique_violation THEN
      v_attempts := v_attempts + 1;
    END;
  END LOOP;

  IF NOT v_insert_ok THEN
    RETURN QUERY SELECT FALSE, 'Could not generate unique paper receipt code.'::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  UPDATE anonymous_paper_blanks SET status = 'CAST', cast_at = now()
  WHERE ballot_id = p_ballot_id AND status = 'AVAILABLE';

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  IF v_updated <> 1 THEN
    RAISE EXCEPTION 'Failed to mark anonymous paper blank as CAST';
  END IF;

  INSERT INTO ballot_audit_log(action, ballot_id, channel, event_date, new_candidate_id, admin_id)
  VALUES ('PAPER_BALLOT_CAST', p_ballot_id, 'PAPER', CURRENT_DATE, p_candidate_id, p_admin_id);

  RETURN QUERY SELECT TRUE, 'Paper vote recorded.'::TEXT, v_receipt;
END;
$$;

-- ---------------------------------------------------------------------------
-- 6. Paper RPC: void_anonymous_paper_blank (verbatim, 2-line change).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.void_anonymous_paper_blank(p_ballot_id text, p_reason text DEFAULT 'Voided anonymous blank'::text, p_admin_id uuid DEFAULT NULL::uuid) RETURNS TABLE(success boolean, message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
    AS $$
DECLARE
  v_payload TEXT;
  v_blank RECORD;
BEGIN
  v_payload := p_ballot_id;

  IF v_payload IS NULL OR v_payload !~ '^PAPER:[0-9a-f]{64}$' THEN
    RETURN QUERY SELECT FALSE, 'Invalid paper ballot ID.'::TEXT;
    RETURN;
  END IF;

  SELECT * INTO v_blank FROM anonymous_paper_blanks WHERE ballot_id = p_ballot_id FOR UPDATE;

  IF v_blank.ballot_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Anonymous paper blank not found.'::TEXT;
    RETURN;
  END IF;

  IF v_blank.status <> 'AVAILABLE' THEN
    RETURN QUERY SELECT FALSE, 'Only AVAILABLE anonymous blanks can be voided; cast ballots require correction.'::TEXT;
    RETURN;
  END IF;

  UPDATE anonymous_paper_blanks SET status = 'VOIDED', voided_at = now(), void_reason = p_reason
  WHERE ballot_id = p_ballot_id AND status = 'AVAILABLE';

  INSERT INTO ballot_audit_log(action, ballot_id, channel, event_date, admin_id, details)
  VALUES ('ANONYMOUS_PAPER_BLANK_VOIDED', p_ballot_id, 'PAPER', CURRENT_DATE, p_admin_id, jsonb_build_object('reason', p_reason));

  RETURN QUERY SELECT TRUE, 'Anonymous paper blank voided.'::TEXT;
END;
$$;

-- ---------------------------------------------------------------------------
-- 7. Identity-slip short_code: CSPRNG instead of random() (verbatim, 1-line change).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.generate_short_code() RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
    AS $$
DECLARE
  v_chars TEXT := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_code TEXT := '';
  v_sum INT := 0;
  v_digit INT;
  v_checksum INT;
  i INT;
BEGIN
  FOR i IN 1..11 LOOP
    v_code := v_code || substr(v_chars, (get_byte(gen_random_bytes(1), 0) % length(v_chars)) + 1, 1);
  END LOOP;

  FOR i IN REVERSE 1..11 LOOP
    v_digit := ascii(substr(v_code, i, 1));
    IF v_digit BETWEEN 48 AND 57 THEN
      v_digit := v_digit - 48;
    ELSE
      v_digit := v_digit - 55;
    END IF;

    IF (11 - i) % 2 = 0 THEN
      v_digit := v_digit * 2;
      IF v_digit > 35 THEN v_digit := v_digit - 35; END IF;
    END IF;
    v_sum := v_sum + v_digit;
  END LOOP;

  v_checksum := (36 - (v_sum % 36)) % 36;
  IF v_checksum < 10 THEN
    v_code := v_code || chr(v_checksum + 48);
  ELSE
    v_code := v_code || chr(v_checksum + 55);
  END IF;

  RETURN substr(v_code, 1, 4) || '-' || substr(v_code, 5, 4) || '-' || substr(v_code, 9, 4);
END;
$$;

-- ---------------------------------------------------------------------------
-- 8. Drop the HMAC helpers. Nothing references them anymore (post-condition 1).
-- Their ACL entries disappear with them.
-- ---------------------------------------------------------------------------
DROP FUNCTION private.hmac_sign(text);
DROP FUNCTION private.hmac_verify(text);

-- ---------------------------------------------------------------------------
-- Fail-closed post-conditions. Any violation aborts the transaction.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_offenders TEXT;
  v_id        TEXT;
  v_code      TEXT;
  v_def       TEXT;
BEGIN
  -- (1) No function in private/public still references the HMAC helpers.
  SELECT string_agg(n.nspname || '.' || p.proname
                    || '(' || pg_get_function_identity_arguments(p.oid) || ')', ', ')
    INTO v_offenders
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname IN ('private', 'public')
    AND p.prokind IN ('f', 'p')   -- pg_get_functiondef errors on aggregates/window fns
    AND pg_get_functiondef(p.oid) ~ 'private\.hmac_(sign|verify)';
  IF v_offenders IS NOT NULL THEN
    RAISE EXCEPTION 'ABORT: functions still reference the HMAC helpers: %', v_offenders;
  END IF;

  -- (2) The helpers themselves are gone.
  IF to_regprocedure('private.hmac_sign(text)') IS NOT NULL
     OR to_regprocedure('private.hmac_verify(text)') IS NOT NULL THEN
    RAISE EXCEPTION 'ABORT: an HMAC helper function still exists.';
  END IF;

  -- (3) Paper IDs: new shape, exactly 70 chars, key-independent.
  v_id := private.generate_opaque_paper_ballot_id();
  IF v_id IS NULL OR v_id !~ '^PAPER:[0-9a-f]{64}$' OR length(v_id) <> 70 THEN
    RAISE EXCEPTION 'ABORT: generate_opaque_paper_ballot_id emitted an unexpected shape: %', v_id;
  END IF;

  -- (4) The three paper RPCs enforce the new shape inline.
  v_def := pg_get_functiondef('private.correct_paper_vote(text,uuid,uuid,text)'::regprocedure);
  IF position('!~ ''^PAPER:[0-9a-f]{64}$''' IN v_def) = 0 THEN
    RAISE EXCEPTION 'ABORT: correct_paper_vote is missing the inline shape check.';
  END IF;
  v_def := pg_get_functiondef('private.submit_paper_vote(text,uuid,uuid)'::regprocedure);
  IF position('!~ ''^PAPER:[0-9a-f]{64}$''' IN v_def) = 0 THEN
    RAISE EXCEPTION 'ABORT: submit_paper_vote is missing the inline shape check.';
  END IF;
  v_def := pg_get_functiondef('private.void_anonymous_paper_blank(text,text,uuid)'::regprocedure);
  IF position('!~ ''^PAPER:[0-9a-f]{64}$''' IN v_def) = 0 THEN
    RAISE EXCEPTION 'ABORT: void_anonymous_paper_blank is missing the inline shape check.';
  END IF;

  -- (5) The digital writers no longer sign.
  IF pg_get_functiondef('private.cast_anonymous_digital_vote(text,uuid)'::regprocedure)
       NOT LIKE '%v_ballot_id := v_payload;%' THEN
    RAISE EXCEPTION 'ABORT: cast_anonymous_digital_vote still derives v_ballot_id from a signature.';
  END IF;
  IF pg_get_functiondef('private.submit_anonymous_vote(character varying,uuid)'::regprocedure)
       NOT LIKE '%v_ballot_id := v_payload;%' THEN
    RAISE EXCEPTION 'ABORT: submit_anonymous_vote still derives v_ballot_id from a signature.';
  END IF;

  -- (6) short_code: CSPRNG source, no PRNG left, shape preserved.
  v_def := pg_get_functiondef('private.generate_short_code()'::regprocedure);
  IF v_def NOT LIKE '%gen_random_bytes%' THEN
    RAISE EXCEPTION 'ABORT: generate_short_code is not using gen_random_bytes.';
  END IF;
  IF v_def LIKE '%random(%' THEN
    RAISE EXCEPTION 'ABORT: generate_short_code still uses random().';
  END IF;
  v_code := private.generate_short_code();
  IF v_code IS NULL OR v_code !~ '^[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{3}[0-9A-Z]$' THEN
    RAISE EXCEPTION 'ABORT: generate_short_code emitted an unexpected shape: %', v_code;
  END IF;

  RAISE NOTICE 'OK: HMAC layer removed; ballot IDs are key-independent; short_code uses CSPRNG.';
END
$$;

COMMIT;
