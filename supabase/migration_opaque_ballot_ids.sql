-- MIGRATION: Make newly generated ballot IDs opaque (Tier 1 anonymity)
--
-- Problem:
-- ballot_id = private.hmac_sign(payload), and hmac_sign returns
-- `payload || '.' || signature` -- the PAYLOAD HALF IS PUBLICLY VISIBLE (it is
-- only signed, not encrypted). ballot_ids are shown on the public verify page.
-- The existing payloads embed linkable identifiers in cleartext:
--   digital submit_anonymous_vote : '<member_id>:<candidate_id>:<epoch>:<rand>'
--   paper   issue_paper_ballot    : 'PAPER:<member_id>:<epoch>:<rand>'
--   paper   generate_blank_batch  : 'PAPER:BLANK:<batch_id>:<index>:<epoch>:<rand>'
-- => any member of the public who sees a ballot_id can deanonymize the voter
--    (and, for digital, read their candidate choice). This breaks Tier 1.
--
-- Fix:
-- Replace every generated payload with a pure-random opaque value carrying NO
-- member/candidate/batch identifiers and NO timestamp:
--   digital : 'DIGITAL:' || encode(gen_random_bytes(32),'hex')
--   paper   : 'PAPER:'   || encode(gen_random_bytes(32),'hex')
-- hmac_sign / hmac_verify are UNCHANGED. The 'PAPER:' prefix is kept because
-- downstream paper RPCs (submit_paper_vote, issue_preprinted, spoil) hmac_verify
-- the ballot_id; the 'DIGITAL:' prefix mirrors it for consistency. candidate_id
-- is dropped from the digital payload because ballots.candidate_id already stores
-- it (nothing recovers it from the ballot_id).
--
-- IRREVERSIBLE: existing plaintext ballot_ids cannot be retroactively anonymized.
-- This migration must run BEFORE any real votes, followed by a DB wipe + re-seed.
--
-- Run order: run LAST, after migration_enforce_token_expiry.sql (which defines
-- the authoritative submit_anonymous_vote redefined below). Idempotent
-- (CREATE OR REPLACE). Design reviewed by oracle (2026-09-03).

--------------------------------------------------------------------------------
-- private.issue_paper_ballot: remove member_id from payload
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.issue_paper_ballot(
  p_member_id UUID
)
RETURNS TABLE (success BOOLEAN, message TEXT, ballot_id TEXT, short_code TEXT, qr_svg TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_member RECORD;
  v_payload TEXT;
  v_ballot_id TEXT;
  v_short_code TEXT;
  v_qr_svg TEXT;
  v_attempts INT := 0;
  v_insert_ok BOOLEAN := FALSE;
BEGIN
  SELECT id, full_name INTO v_member FROM members WHERE id = p_member_id AND is_active = TRUE;
  IF v_member.id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Member not found or inactive.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM tokens t
    WHERE t.member_id = v_member.id AND t.type = 'VOTING' AND t.is_used = TRUE
  ) THEN
    RETURN QUERY SELECT FALSE, 'Member has already voted digitally.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM paper_ballots
    WHERE member_id = v_member.id AND status IN ('ISSUED', 'ISSUED_TO_VOTER', 'VOTED')
  ) THEN
    RETURN QUERY SELECT FALSE, 'Member already has an active or used paper ballot.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Opaque payload: pure random, no member/batch identifiers, no timestamp.
  -- The payload half of ballot_id is publicly visible, so it must carry no metadata.
  v_payload := 'PAPER:' || encode(gen_random_bytes(32), 'hex');
  v_ballot_id := private.hmac_sign(v_payload);

  WHILE v_attempts < 5 AND NOT v_insert_ok LOOP
    v_short_code := private.generate_short_code();
    v_qr_svg := private.generate_qr_svg(v_ballot_id);
    BEGIN
      INSERT INTO paper_ballots (ballot_id, member_id, status, short_code, qr_svg)
      VALUES (v_ballot_id, v_member.id, 'ISSUED', v_short_code, v_qr_svg);
      v_insert_ok := TRUE;
    EXCEPTION WHEN unique_violation THEN
      v_attempts := v_attempts + 1;
    END;
  END LOOP;

  IF NOT v_insert_ok THEN
    RETURN QUERY SELECT FALSE, 'Could not generate unique short code after 5 attempts.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  INSERT INTO vote_audit_log (action, member_id, ballot_id, details)
  VALUES ('PAPER_ISSUED', v_member.id, v_ballot_id, jsonb_build_object('short_code', v_short_code));

  RETURN QUERY SELECT TRUE, 'Paper ballot issued for ' || v_member.full_name || '.'::TEXT, v_ballot_id, v_short_code, v_qr_svg;
END;
$$;

--------------------------------------------------------------------------------
-- private.generate_blank_paper_ballot_batch: remove batch/index from payload
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.generate_blank_paper_ballot_batch(
  p_count INT,
  p_admin_id UUID DEFAULT NULL
)
RETURNS TABLE (
  batch_id UUID,
  generated_count INT,
  message TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_batch_id UUID;
  v_payload TEXT;
  v_ballot_id TEXT;
  v_short_code TEXT;
  v_qr_svg TEXT;
  v_attempts INT;
  v_insert_ok BOOLEAN;
  i INT;
BEGIN
  IF p_count IS NULL OR p_count <= 0 OR p_count > 1000 THEN
    RETURN QUERY SELECT NULL::UUID, 0, 'Batch size must be between 1 and 1000.'::TEXT;
    RETURN;
  END IF;

  INSERT INTO paper_ballot_batches (generated_count, generated_by)
  VALUES (p_count, p_admin_id)
  RETURNING id INTO v_batch_id;

  FOR i IN 1..p_count LOOP
    v_attempts := 0;
    v_insert_ok := FALSE;

    -- Opaque payload: pure random, no batch/index identifiers, no timestamp.
    v_payload := 'PAPER:' || encode(gen_random_bytes(32), 'hex');
    v_ballot_id := private.hmac_sign(v_payload);

    WHILE v_attempts < 5 AND NOT v_insert_ok LOOP
      v_short_code := private.generate_short_code();
      v_qr_svg := private.generate_qr_svg(v_ballot_id);
      BEGIN
        INSERT INTO paper_ballots (
          ballot_id, member_id, batch_id, status, short_code, qr_svg, created_at
        ) VALUES (
          v_ballot_id, NULL, v_batch_id, 'AVAILABLE', v_short_code, v_qr_svg, NOW()
        );
        v_insert_ok := TRUE;
      EXCEPTION WHEN unique_violation THEN
        v_attempts := v_attempts + 1;
      END;
    END LOOP;

    IF NOT v_insert_ok THEN
      RAISE EXCEPTION 'Could not generate unique short code for ballot % in batch %', i, v_batch_id;
    END IF;
  END LOOP;

  INSERT INTO vote_audit_log (action, admin_id, details)
  VALUES ('BATCH_GENERATED', p_admin_id, jsonb_build_object('batch_id', v_batch_id, 'count', p_count));

  RETURN QUERY SELECT v_batch_id, p_count, 'Successfully generated batch of ' || p_count || ' pre-printed blank ballots.'::TEXT;
END;
$$;

--------------------------------------------------------------------------------
-- private.submit_anonymous_vote: opaque DIGITAL ballot_id (Tier 1 fix)
--
-- Faithful CREATE OR REPLACE of the authoritative version
-- (migration_enforce_token_expiry.sql lines 26-108: Option E paper-ballot guard
-- + token-expiry enforcement). ONLY the ballot_id payload construction changes
-- (marked -- CHANGED); all phase/expiry/used guards, locks, and grants preserved.
--------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.submit_anonymous_vote(
  p_token_hash VARCHAR(64),
  p_candidate_id UUID
)
RETURNS TABLE (success BOOLEAN, message TEXT, receipt_code TEXT, ballot_id TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_token_id UUID;
  v_member_id UUID;
  v_is_used BOOLEAN;
  v_expires_at TIMESTAMPTZ;
  v_phase election_phase;
  v_voting_end TIMESTAMPTZ;
  v_receipt TEXT;
  v_ballot_id TEXT;
  v_payload TEXT;
  v_attempts INT := 0;
  v_insert_ok BOOLEAN := FALSE;
  v_paper_ballot RECORD;
BEGIN
  SELECT current_phase, voting_end INTO v_phase, v_voting_end FROM election_settings WHERE id = 1;

  IF v_phase != 'VOTING' OR (v_voting_end IS NOT NULL AND NOW() > v_voting_end) THEN
    RETURN QUERY SELECT FALSE, 'Voting phase is closed or expired.'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  SELECT id, member_id, is_used, expires_at
    INTO v_token_id, v_member_id, v_is_used, v_expires_at FROM tokens
  WHERE token_hash = p_token_hash AND type = 'VOTING' FOR UPDATE;

  IF v_token_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Invalid or non-existent voting token.'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  IF v_expires_at IS NULL OR v_expires_at <= NOW() THEN
    RETURN QUERY SELECT FALSE, 'This voting token has expired.'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  IF v_is_used THEN
    RETURN QUERY SELECT FALSE, 'This token has already been used or reserved for paper voting.'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- Check if member already has an active or voted paper ballot.
  SELECT * INTO v_paper_ballot FROM paper_ballots
  WHERE member_id = v_member_id AND status IN ('ISSUED', 'ISSUED_TO_VOTER', 'VOTED')
  FOR SHARE;

  IF FOUND THEN
    RETURN QUERY SELECT FALSE, 'A paper ballot has already been issued for this member.'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  -- CHANGED: opaque payload, no member_id/candidate_id/timestamp (payload half of
  -- ballot_id is public). candidate_id is already stored in ballots.candidate_id.
  v_payload := 'DIGITAL:' || encode(gen_random_bytes(32), 'hex');
  v_ballot_id := private.hmac_sign(v_payload);

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
    RETURN QUERY SELECT FALSE, 'Could not generate unique receipt code after 5 attempts.'::TEXT, NULL::TEXT, NULL::TEXT;
    RETURN;
  END IF;

  UPDATE tokens SET is_used = TRUE, used_at = NOW() WHERE id = v_token_id;

  RETURN QUERY SELECT TRUE, 'Vote cast successfully.'::TEXT, v_receipt, v_ballot_id;
END;
$$;

--------------------------------------------------------------------------------
-- Preserve grants (CREATE OR REPLACE keeps existing ACL; re-assert to be safe)
--------------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION private.submit_anonymous_vote(VARCHAR, UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.submit_anonymous_vote(VARCHAR, UUID) TO service_role;

REVOKE EXECUTE ON FUNCTION private.issue_paper_ballot(UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.issue_paper_ballot(UUID) TO service_role;

REVOKE EXECUTE ON FUNCTION private.generate_blank_paper_ballot_batch(INT, UUID) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.generate_blank_paper_ballot_batch(INT, UUID) TO service_role;
