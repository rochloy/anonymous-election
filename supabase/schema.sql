-- supabase/schema.sql — Stage 2 consolidated baseline
--
-- Point-in-time snapshot of the live database's APPLICATION schemas
-- (public, private, governance) at canonical migration item 50, generated
-- 2026-10-08 via schema-only pg_dump. This REPLACES the day-one file that F15
-- mechanically disarmed (it was ~41 migrations stale and rebuilt an insecure
-- database); a supported fresh-rebuild path exists again.
--
-- How to rebuild a fresh Supabase project:
--   1. Run this file in the SQL Editor (or psql as the project's postgres
--      role) against an EMPTY database. It is self-contained: it creates the
--      extensions schema, the required extensions (uuid-ossp, pg_trgm, pgcrypto), and
--      the f4_public_reader role. Supabase stock roles (anon, authenticated,
--      service_role, supabase_admin) are assumed to exist.
--   2. Apply any migrations numbered ABOVE the snapshot item (none yet at
--      item 50; check docs/TECHNICAL_GUIDE.md "Database Migrations" for the
--      canonical run order).
--   3. Optionally seed test data (supabase/seed.sql) or import real members.
--   4. Verify: npm run test:db-security (or scripts/test-db-security.sh
--      hosted) — the standing 14-check suite is this baseline's acceptance
--      test.
--
-- Deliberately stripped from the raw dump: the 12 platform-owned
-- `ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin` statements. Supabase
-- provisioning owns them; they already exist on any target project and cannot
-- be altered by the postgres role. The postgres-owned default privileges ARE
-- included (they encode the post-Fix-1 least-privilege posture).
--
-- The dump body below is verbatim pg_dump output except for exactly two
-- mechanical edits (verified by the build script):
--   * `CREATE SCHEMA public;` -> `CREATE SCHEMA IF NOT EXISTS public;`
--     (public always pre-exists on a Supabase project)

-- ---------------------------------------------------------------------------
-- Self-contained pre-requisites (idempotent).
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_trgm SCHEMA public;
CREATE EXTENSION IF NOT EXISTS pgcrypto SCHEMA extensions;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'f4_public_reader') THEN
    CREATE ROLE f4_public_reader NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
  END IF;
END
$$;
-- The dump's ALTER FUNCTION ... OWNER TO f4_public_reader statements require
-- the new owner to hold CREATE on schema public. Granted here, revoked in the
-- epilogue to match the live least-privilege posture.
GRANT CREATE ON SCHEMA public TO f4_public_reader;
-- ALTER FUNCTION ... OWNER TO also requires the executor to be able to SET
-- ROLE to the new owner. postgres holds ADMIN on the role it just created
-- (auto-grant), so grant itself the SET option for the duration; revoked in
-- the epilogue to match the live membership posture.
GRANT f4_public_reader TO postgres WITH SET OPTION;

-- ---------------------------------------------------------------------------
-- Verbatim pg_dump body (application schemas, snapshot at item 50).
-- ---------------------------------------------------------------------------

--
-- PostgreSQL database dump
--

\restrict vgWAUjqTlImCgHiiCGjkd7AyrBh68aHSVIQiOKmu4sukQwSjD2Xw8bRWpK8Jm0u

-- Dumped from database version 17.6
-- Dumped by pg_dump version 17.6

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: governance; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA governance;


ALTER SCHEMA governance OWNER TO postgres;

--
-- Name: private; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA private;


ALTER SCHEMA private OWNER TO postgres;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: pg_database_owner
--

CREATE SCHEMA IF NOT EXISTS public;


ALTER SCHEMA public OWNER TO pg_database_owner;

--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: pg_database_owner
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: election_phase; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.election_phase AS ENUM (
    'SETUP',
    'NOMINATION',
    'NOMINATION_CLOSED',
    'VOTING',
    'VOTING_CLOSED',
    'COMPLETED'
);


ALTER TYPE public.election_phase OWNER TO postgres;

--
-- Name: paper_ballot_status; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.paper_ballot_status AS ENUM (
    'ISSUED',
    'VOTED',
    'SPOILED',
    'MISSING',
    'AVAILABLE',
    'ISSUED_TO_VOTER',
    'VOIDED_UNUSED'
);


ALTER TYPE public.paper_ballot_status OWNER TO postgres;

--
-- Name: token_type; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.token_type AS ENUM (
    'NOMINATION',
    'VOTING'
);


ALTER TYPE public.token_type OWNER TO postgres;

--
-- Name: reject_mutation(); Type: FUNCTION; Schema: governance; Owner: postgres
--

CREATE FUNCTION governance.reject_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'governance.processing_activity_ledger is append-only (no UPDATE/DELETE)';
END;
$$;


ALTER FUNCTION governance.reject_mutation() OWNER TO postgres;

--
-- Name: reject_truncate(); Type: FUNCTION; Schema: governance; Owner: postgres
--

CREATE FUNCTION governance.reject_truncate() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'governance.processing_activity_ledger must never be truncated';
END;
$$;


ALTER FUNCTION governance.reject_truncate() OWNER TO postgres;

--
-- Name: adjudicate_eligibility(uuid, uuid, boolean, text, text); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.adjudicate_eligibility(p_admin_session_id uuid, p_member_id uuid, p_new_voting_eligible boolean, p_new_eligibility_reason text, p_note text DEFAULT NULL::text) RETURNS TABLE(success boolean, message text, member_id uuid)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $$
DECLARE
  v_old RECORD;
BEGIN
  SELECT id, voting_eligible, eligibility_reason, eligibility_source, is_age_eligible
    INTO v_old FROM members WHERE id = p_member_id FOR UPDATE;
  IF v_old.id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Member not found.'::TEXT, p_member_id; RETURN;
  END IF;

  IF (p_new_voting_eligible = TRUE  AND p_new_eligibility_reason <> 'ELIGIBLE')
  OR (p_new_voting_eligible = FALSE AND p_new_eligibility_reason  = 'ELIGIBLE') THEN
    RETURN QUERY SELECT FALSE,
      'Inconsistent adjudication: eligible=TRUE requires reason ELIGIBLE; eligible=FALSE requires a non-ELIGIBLE reason.'::TEXT,
      p_member_id;
    RETURN;
  END IF;

  IF v_old.voting_eligible = p_new_voting_eligible
     AND v_old.eligibility_reason = p_new_eligibility_reason THEN
    RETURN QUERY SELECT FALSE, 'No change: member already in that eligibility state.'::TEXT, p_member_id;
    RETURN;
  END IF;

  UPDATE members
     SET voting_eligible   = p_new_voting_eligible,
         eligibility_reason = p_new_eligibility_reason,
         eligibility_source = 'ADMIN_ADJUDICATION'
   WHERE id = p_member_id;

  INSERT INTO eligibility_adjudications(
    member_id, admin_id,
    old_voting_eligible, old_eligibility_reason, old_eligibility_source, old_is_age_eligible,
    new_voting_eligible, new_eligibility_reason, new_eligibility_source, new_is_age_eligible,
    note)
  VALUES (
    p_member_id, p_admin_session_id,
    v_old.voting_eligible, v_old.eligibility_reason, v_old.eligibility_source, v_old.is_age_eligible,
    p_new_voting_eligible, p_new_eligibility_reason, 'ADMIN_ADJUDICATION', v_old.is_age_eligible,
    p_note);

  RETURN QUERY SELECT TRUE, 'Eligibility adjudicated.'::TEXT, p_member_id;
END;
$$;


ALTER FUNCTION private.adjudicate_eligibility(p_admin_session_id uuid, p_member_id uuid, p_new_voting_eligible boolean, p_new_eligibility_reason text, p_note text) OWNER TO postgres;

--
-- Name: adjudicate_nomination(text, uuid, uuid[], uuid, text, text, uuid, text); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.adjudicate_nomination(p_decision text, p_admin_session_id uuid, p_affected_nomination_ids uuid[], p_nominee_member_id uuid DEFAULT NULL::uuid, p_nominee_name text DEFAULT NULL::text, p_candidate_statement text DEFAULT NULL::text, p_candidate_id uuid DEFAULT NULL::uuid, p_note text DEFAULT NULL::text) RETURNS TABLE(success boolean, message text, candidate_id uuid)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
    AS $$
DECLARE
  v_phase          election_phase;
  v_name           TEXT;
  v_candidate_id   UUID := NULL;
  v_input_count    INT;
  v_distinct_count INT;
  v_null_count     INT;
  v_exists_count   INT;
BEGIN
  IF p_decision NOT IN ('PROMOTE','MERGE','DISCARD') THEN
    RETURN QUERY SELECT FALSE, 'Invalid decision.'::TEXT, NULL::UUID; RETURN;
  END IF;
  IF p_admin_session_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Admin session required.'::TEXT, NULL::UUID; RETURN;
  END IF;
  IF p_affected_nomination_ids IS NULL OR array_length(p_affected_nomination_ids, 1) IS NULL THEN
    RETURN QUERY SELECT FALSE, 'affectedNominationIds is required.'::TEXT, NULL::UUID; RETURN;
  END IF;

  SELECT
    COUNT(*),
    COUNT(*) FILTER (WHERE id IS NULL),
    COUNT(DISTINCT id)
  INTO v_input_count, v_null_count, v_distinct_count
  FROM unnest(p_affected_nomination_ids) AS t(id);

  IF v_null_count > 0 THEN
    RETURN QUERY SELECT FALSE, 'affectedNominationIds cannot contain null.'::TEXT, NULL::UUID; RETURN;
  END IF;

  IF v_input_count <> v_distinct_count THEN
    RETURN QUERY SELECT FALSE, 'affectedNominationIds cannot contain duplicates.'::TEXT, NULL::UUID; RETURN;
  END IF;

  SELECT current_phase INTO v_phase FROM election_settings WHERE id = 1;
  IF v_phase <> 'NOMINATION_CLOSED' THEN
    RETURN QUERY SELECT FALSE, 'Adjudication is only allowed during NOMINATION_CLOSED.'::TEXT, NULL::UUID; RETURN;
  END IF;

  -- Lock target nomination rows deterministically (UUID ASC), no SKIP LOCKED.
  WITH input_ids AS (
    SELECT id
    FROM unnest(p_affected_nomination_ids) AS t(id)
  )
  SELECT COUNT(*) INTO v_exists_count
  FROM (
    SELECT an.id
    FROM anonymous_nominations an
    JOIN input_ids i ON i.id = an.id
    ORDER BY an.id ASC
    FOR UPDATE
  ) locked;

  IF v_exists_count <> v_input_count THEN
    RETURN QUERY SELECT FALSE, 'One or more affected nominations do not exist.'::TEXT, NULL::UUID; RETURN;
  END IF;

  -- Separate overlap check against ALL prior decisions (historical rows included).
  IF EXISTS (
    SELECT 1
    FROM nomination_adjudications na
    WHERE na.affected_nomination_ids && p_affected_nomination_ids
  ) THEN
    RETURN QUERY SELECT FALSE, 'One or more nominations were already adjudicated.'::TEXT, NULL::UUID; RETURN;
  END IF;

  IF p_decision = 'PROMOTE' THEN
    IF p_nominee_member_id IS NOT NULL THEN
      SELECT full_name INTO v_name FROM members WHERE id = p_nominee_member_id;
      IF v_name IS NULL THEN
        RETURN QUERY SELECT FALSE, 'Nominee member not found.'::TEXT, NULL::UUID; RETURN;
      END IF;
    ELSE
      v_name := trim(coalesce(p_nominee_name, ''));
      IF v_name = '' THEN
        RETURN QUERY SELECT FALSE, 'Nominee name is required for promote.'::TEXT, NULL::UUID; RETURN;
      END IF;
    END IF;

    INSERT INTO candidates (full_name, statement, is_active)
    VALUES (v_name, p_candidate_statement, TRUE)
    RETURNING id INTO v_candidate_id;

  ELSIF p_decision = 'MERGE' THEN
    IF p_candidate_id IS NULL THEN
      RETURN QUERY SELECT FALSE, 'candidateId is required for merge.'::TEXT, NULL::UUID; RETURN;
    END IF;
    v_candidate_id := p_candidate_id;
  END IF;

  INSERT INTO nomination_adjudications
    (admin_id, decision, candidate_id, nominee_member_id, affected_nomination_ids, note)
  VALUES
    (p_admin_session_id, p_decision, v_candidate_id, p_nominee_member_id, p_affected_nomination_ids, p_note);

  PERFORM insert_audit_log(
    'ADMIN_ACTION',
    p_admin_session_id,
    NULL,
    jsonb_build_object(
      'op',                    'adjudicate_nomination',
      'decision',              p_decision,
      'nomineeMemberId',       p_nominee_member_id,
      'candidateId',           v_candidate_id,
      'affectedNominationIds', to_jsonb(p_affected_nomination_ids)
    )
  );

  RETURN QUERY SELECT TRUE, 'Adjudicated.'::TEXT, v_candidate_id;
END;
$$;


ALTER FUNCTION private.adjudicate_nomination(p_decision text, p_admin_session_id uuid, p_affected_nomination_ids uuid[], p_nominee_member_id uuid, p_nominee_name text, p_candidate_statement text, p_candidate_id uuid, p_note text) OWNER TO postgres;

--
-- Name: admin_add_nomination(uuid, text, text); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.admin_add_nomination(p_nominee_member_id uuid, p_nominee_name text, p_reason text) RETURNS TABLE(success boolean, message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
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


ALTER FUNCTION private.admin_add_nomination(p_nominee_member_id uuid, p_nominee_name text, p_reason text) OWNER TO postgres;

--
-- Name: append_governance_event(text, uuid, text, text, text, text, text, text[], text[], text, jsonb); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.append_governance_event(p_event_type text, p_actor_admin_id uuid, p_actor_label text, p_controller_name text, p_organization_ref text, p_processing_purpose text, p_lawful_basis text, p_data_categories text[], p_data_subject_categories text[], p_retention_policy text, p_event_summary jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'governance', 'extensions'
    AS $$
DECLARE
  v_prev CHAR(64);
  v_hash CHAR(64);
  v_id UUID;
BEGIN
  SELECT record_hash INTO v_prev FROM governance.processing_activity_ledger
    ORDER BY occurred_at DESC, id DESC LIMIT 1;
  v_hash := encode(digest(
    coalesce(v_prev,'') || p_event_type || now()::text || coalesce(p_event_summary::text,''),
    'sha256'), 'hex');
  INSERT INTO governance.processing_activity_ledger(
    event_type, actor_admin_id, actor_label, controller_name, organization_ref,
    processing_purpose, lawful_basis, data_categories, data_subject_categories,
    retention_policy, event_summary, previous_hash, record_hash)
  VALUES (p_event_type, p_actor_admin_id, p_actor_label, p_controller_name, p_organization_ref,
    p_processing_purpose, p_lawful_basis, p_data_categories, p_data_subject_categories,
    p_retention_policy, coalesce(p_event_summary,'{}'::jsonb), v_prev, v_hash)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;


ALTER FUNCTION private.append_governance_event(p_event_type text, p_actor_admin_id uuid, p_actor_label text, p_controller_name text, p_organization_ref text, p_processing_purpose text, p_lawful_basis text, p_data_categories text[], p_data_subject_categories text[], p_retention_policy text, p_event_summary jsonb) OWNER TO postgres;

--
-- Name: assert_electorate_editable(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.assert_electorate_editable() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
    AS $$
DECLARE
  v_phase election_phase;
BEGIN
  SELECT current_phase INTO v_phase FROM election_settings WHERE id = 1;
  IF v_phase NOT IN ('SETUP', 'NOMINATION', 'NOMINATION_CLOSED') THEN
    RAISE EXCEPTION 'Member edits are only allowed during SETUP, NOMINATION, or NOMINATION_CLOSED phases.';
  END IF;
END;
$$;


ALTER FUNCTION private.assert_electorate_editable() OWNER TO postgres;

--
-- Name: assert_member_creation_allowed(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.assert_member_creation_allowed() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
    AS $$
DECLARE
  v_phase election_phase;
  v_allow_during_voting BOOLEAN;
BEGIN
  SELECT current_phase, allow_adding_member_during_voting
  INTO v_phase, v_allow_during_voting
  FROM election_settings
  WHERE id = 1;

  IF v_phase IN ('SETUP', 'NOMINATION', 'NOMINATION_CLOSED') THEN
    RETURN;
  END IF;

  IF v_phase = 'VOTING' AND v_allow_during_voting IS TRUE THEN
    RETURN;
  END IF;

  RAISE EXCEPTION 'Member creation is only allowed during SETUP, NOMINATION, or NOMINATION_CLOSED phases, or during VOTING when allow_adding_member_during_voting is enabled.';
END;
$$;


ALTER FUNCTION private.assert_member_creation_allowed() OWNER TO postgres;

--
-- Name: cast_anonymous_digital_vote(text, uuid); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.cast_anonymous_digital_vote(p_credential text, p_candidate_id uuid) RETURNS TABLE(o_success boolean, o_message text, o_receipt_code text, o_ballot_id text)
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


ALTER FUNCTION private.cast_anonymous_digital_vote(p_credential text, p_candidate_id uuid) OWNER TO postgres;

--
-- Name: check_in_paper_voter(text, uuid, uuid); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.check_in_paper_voter(p_short_code text, p_member_id uuid, p_admin_id uuid DEFAULT NULL::uuid) RETURNS TABLE(success boolean, message text, member_name text, member_code text, short_code text, participation_date date, status text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
    AS $$
DECLARE
  v_short_code TEXT := upper(trim(p_short_code));
  v_member RECORD;
  v_paper RECORD;
  v_token RECORD;
  v_token_count INTEGER := 0;
  v_updated INTEGER := 0;
  v_has_digital_res BOOLEAN := FALSE;
  v_entitlement RECORD;
BEGIN
  IF v_short_code IS NULL OR v_short_code = '' THEN
    RETURN QUERY SELECT FALSE, 'short_code is required.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::DATE, NULL::TEXT;
    RETURN;
  END IF;

  SELECT m.id, m.member_code, m.full_name, m.voting_eligible
  INTO v_member
  FROM members m
  WHERE m.id = p_member_id
    AND m.is_active = TRUE
  FOR SHARE;

  IF v_member.id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Member not found or inactive.'::TEXT, NULL::TEXT, NULL::TEXT, v_short_code, NULL::DATE, NULL::TEXT;
    RETURN;
  END IF;

  IF v_member.voting_eligible IS NOT TRUE THEN
    RETURN QUERY SELECT FALSE, 'Member is not eligible to vote.'::TEXT, v_member.full_name::TEXT, v_member.member_code::TEXT, v_short_code, NULL::DATE, NULL::TEXT;
    RETURN;
  END IF;

  SELECT *
  INTO v_paper
  FROM paper_ballots
  WHERE paper_ballots.short_code = v_short_code
  FOR UPDATE;

  IF v_paper.id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Identity slip short code not found.'::TEXT, v_member.full_name::TEXT, v_member.member_code::TEXT, v_short_code, NULL::DATE, NULL::TEXT;
    RETURN;
  END IF;

  IF v_paper.status <> 'AVAILABLE' THEN
    RETURN QUERY SELECT FALSE, 'Identity slip is not available for check-in.'::TEXT, v_member.full_name::TEXT, v_member.member_code::TEXT, v_short_code, v_paper.checked_in_date, v_paper.status::TEXT;
    RETURN;
  END IF;

  IF v_paper.member_id IS NOT NULL AND v_paper.member_id <> p_member_id THEN
    RETURN QUERY SELECT FALSE, 'Identity slip belongs to a different member.'::TEXT, v_member.full_name::TEXT, v_member.member_code::TEXT, v_short_code, NULL::DATE, NULL::TEXT;
    RETURN;
  END IF;

  FOR v_token IN
    SELECT id, is_used, channel_sent, reserved_channel
    FROM tokens
    WHERE member_id = p_member_id
      AND type = 'VOTING'
      AND voided_at IS NULL
    ORDER BY created_at DESC, id
    FOR UPDATE
  LOOP
    v_token_count := v_token_count + 1;
    IF v_token_count > 1 THEN
      RETURN QUERY SELECT FALSE, 'Integrity error: multiple active voting tokens found for member.'::TEXT, v_member.full_name::TEXT, v_member.member_code::TEXT, v_short_code, NULL::DATE, NULL::TEXT;
      RETURN;
    END IF;
  END LOOP;

  IF v_token_count = 0 THEN
    SELECT * INTO v_entitlement
    FROM private.ensure_voting_entitlement(p_member_id, p_admin_id, NULL, 'NONE');

    IF v_entitlement.success IS NOT TRUE THEN
      RETURN QUERY SELECT FALSE, COALESCE(v_entitlement.message, 'No active voting entitlement found.')::TEXT, v_member.full_name::TEXT, v_member.member_code::TEXT, v_short_code, NULL::DATE, NULL::TEXT;
      RETURN;
    END IF;

    SELECT id, is_used, channel_sent, reserved_channel
    INTO v_token
    FROM tokens
    WHERE id = v_entitlement.token_id
      AND voided_at IS NULL
    FOR UPDATE;

    IF v_token.id IS NULL THEN
      RETURN QUERY SELECT FALSE, 'Could not resolve voting entitlement token.'::TEXT, v_member.full_name::TEXT, v_member.member_code::TEXT, v_short_code, NULL::DATE, NULL::TEXT;
      RETURN;
    END IF;
  END IF;

  IF v_token.is_used IS TRUE THEN
    RETURN QUERY SELECT FALSE, 'Voting entitlement already consumed.'::TEXT, v_member.full_name::TEXT, v_member.member_code::TEXT, v_short_code, NULL::DATE, NULL::TEXT;
    RETURN;
  END IF;

  SELECT TRUE INTO v_has_digital_res
    FROM digital_credential_reservations
   WHERE token_id = v_token.id AND expires_at > now()
   LIMIT 1;
  IF v_has_digital_res IS TRUE THEN
    RETURN QUERY SELECT FALSE, 'Member has an active digital voting credential; release or wait for it to expire before paper check-in.'::TEXT, v_member.full_name::TEXT, v_member.member_code::TEXT, v_short_code, NULL::DATE, NULL::TEXT;
    RETURN;
  END IF;

  UPDATE tokens
  SET is_used = TRUE,
      used_at = now(),
      channel_sent = 'PAPER',
      reserved_at = now(),
      reserved_channel = 'PAPER',
      reservation_released_at = NULL
  WHERE id = v_token.id
    AND is_used = FALSE
    AND voided_at IS NULL;

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  IF v_updated <> 1 THEN
    RETURN QUERY SELECT FALSE, 'Could not consume paper voting entitlement.'::TEXT, v_member.full_name::TEXT, v_member.member_code::TEXT, v_short_code, NULL::DATE, NULL::TEXT;
    RETURN;
  END IF;

  UPDATE paper_ballots
  SET member_id = p_member_id,
      token_id = v_token.id,
      status = 'ISSUED_TO_VOTER',
      checked_in_at = now(),
      checked_in_date = CURRENT_DATE,
      checked_in_by = p_admin_id
  WHERE id = v_paper.id;

  INSERT INTO participation_audit(action, member_id, token_id, channel, event_date, admin_id)
  VALUES ('PAPER_CHECK_IN', p_member_id, v_token.id, 'PAPER', CURRENT_DATE, p_admin_id);

  RETURN QUERY SELECT TRUE, 'Paper voter checked in.'::TEXT, v_member.full_name::TEXT, v_member.member_code::TEXT, v_short_code, CURRENT_DATE, 'ISSUED_TO_VOTER'::TEXT;
END;
$$;


ALTER FUNCTION private.check_in_paper_voter(p_short_code text, p_member_id uuid, p_admin_id uuid) OWNER TO postgres;

--
-- Name: cleanup_rate_limit_hits(integer); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.cleanup_rate_limit_hits(p_older_than_seconds integer DEFAULT 3600) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
    AS $$
DECLARE v_deleted INT;
BEGIN
  DELETE FROM rate_limit_hits
    WHERE created_at < now() - (p_older_than_seconds || ' seconds')::INTERVAL;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END; $$;


ALTER FUNCTION private.cleanup_rate_limit_hits(p_older_than_seconds integer) OWNER TO postgres;

--
-- Name: correct_paper_vote(text, uuid, uuid, text); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.correct_paper_vote(p_ballot_id text, p_new_candidate_id uuid, p_admin_id uuid DEFAULT NULL::uuid, p_reason text DEFAULT NULL::text) RETURNS TABLE(success boolean, message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
    AS $_$
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
$_$;


ALTER FUNCTION private.correct_paper_vote(p_ballot_id text, p_new_candidate_id uuid, p_admin_id uuid, p_reason text) OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: members; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.members (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    member_code character varying(20) NOT NULL,
    full_name character varying(100) NOT NULL,
    email character varying(255),
    phone character varying(50),
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    voting_eligible boolean DEFAULT true NOT NULL,
    eligibility_reason text DEFAULT 'ELIGIBLE'::text NOT NULL,
    eligibility_source text DEFAULT 'SYSTEM_DEFAULT'::text NOT NULL,
    is_age_eligible boolean,
    has_voted boolean DEFAULT false NOT NULL,
    CONSTRAINT members_eligibility_consistency_check CHECK ((((voting_eligible = true) AND (eligibility_reason = 'ELIGIBLE'::text)) OR ((voting_eligible = false) AND (eligibility_reason <> 'ELIGIBLE'::text)))),
    CONSTRAINT members_eligibility_reason_check CHECK ((eligibility_reason = ANY (ARRAY['ELIGIBLE'::text, 'AGE_UNDER_MIN'::text, 'NOT_A_MEMBER'::text, 'MANUAL_ADMIN_HOLD'::text, 'UNDETERMINED'::text, 'INACTIVE_MEMBER'::text, 'PURGED'::text]))),
    CONSTRAINT members_eligibility_source_check CHECK ((eligibility_source = ANY (ARRAY['SYSTEM_DEFAULT'::text, 'CSV_IMPORT'::text, 'ADMIN_ADJUDICATION'::text, 'SYSTEM_RECOMPUTE'::text, 'PURGE'::text])))
);


ALTER TABLE public.members OWNER TO postgres;

--
-- Name: create_member(text, text, text, text); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.create_member(p_full_name text, p_email text DEFAULT NULL::text, p_phone text DEFAULT NULL::text, p_member_code text DEFAULT NULL::text) RETURNS public.members
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
    AS $$
DECLARE
  v_member members;
  v_member_code TEXT;
BEGIN
  PERFORM private.assert_member_creation_allowed();

  IF trim(coalesce(p_full_name, '')) = '' THEN
    RAISE EXCEPTION 'full_name is required';
  END IF;

  v_member_code := NULLIF(trim(coalesce(p_member_code, '')), '');
  IF v_member_code IS NULL THEN
    v_member_code := 'M-' || encode(gen_random_bytes(4), 'hex');
  END IF;

  INSERT INTO members (member_code, full_name, email, phone, is_active)
  VALUES (
    v_member_code,
    trim(p_full_name),
    NULLIF(trim(coalesce(p_email, '')), ''),
    NULLIF(trim(coalesce(p_phone, '')), ''),
    TRUE
  )
  RETURNING * INTO v_member;

  RETURN v_member;
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'MEMBER_UNIQUE_CONFLICT: member_code/email/phone already exists' USING ERRCODE = '23505';
END;
$$;


ALTER FUNCTION private.create_member(p_full_name text, p_email text, p_phone text, p_member_code text) OWNER TO postgres;

--
-- Name: enforce_paper_ballot_layout_immutable(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.enforce_paper_ballot_layout_immutable() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
    AS $$
BEGIN
  IF NEW.paper_ballot_layout IS DISTINCT FROM OLD.paper_ballot_layout
     AND (
       OLD.current_phase::TEXT IN ('VOTING', 'VOTING_CLOSED', 'COMPLETED')
       OR NEW.current_phase::TEXT IN ('VOTING', 'VOTING_CLOSED', 'COMPLETED')
     ) THEN
    RAISE EXCEPTION 'paper_ballot_layout is immutable once voting opens';
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION private.enforce_paper_ballot_layout_immutable() OWNER TO postgres;

--
-- Name: enforce_token_eligibility(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.enforce_token_eligibility() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $$
DECLARE v_ok BOOLEAN;
BEGIN
  IF NEW.type = 'VOTING' THEN
    SELECT (is_active AND voting_eligible) INTO v_ok FROM members WHERE id = NEW.member_id;
    IF v_ok IS NOT TRUE THEN
      RAISE EXCEPTION 'Cannot issue VOTING token: member % is not eligible', NEW.member_id
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION private.enforce_token_eligibility() OWNER TO postgres;

--
-- Name: ensure_voting_entitlement(uuid, uuid, character varying, character varying); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.ensure_voting_entitlement(p_member_id uuid, p_admin_id uuid DEFAULT NULL::uuid, p_token_hash character varying DEFAULT NULL::character varying, p_channel_sent character varying DEFAULT 'NONE'::character varying) RETURNS TABLE(success boolean, code text, message text, token_id uuid, created boolean, expires_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
    AS $$
DECLARE
  v_member RECORD;
  v_token RECORD;
  v_token_count INTEGER := 0;
  v_ttl_hours INTEGER := 168;
  v_hash VARCHAR(64);
BEGIN
  SELECT id, is_active, voting_eligible
  INTO v_member
  FROM members
  WHERE id = p_member_id
  FOR UPDATE;

  IF v_member.id IS NULL OR v_member.is_active IS NOT TRUE OR v_member.voting_eligible IS NOT TRUE THEN
    RETURN QUERY SELECT FALSE, 'VOTER_INELIGIBLE'::TEXT, 'Member is not eligible to vote.'::TEXT, NULL::UUID, FALSE, NULL::TIMESTAMPTZ;
    RETURN;
  END IF;

  FOR v_token IN
    SELECT id, is_used, tokens.expires_at
    FROM tokens
    WHERE member_id = p_member_id
      AND type = 'VOTING'
      AND voided_at IS NULL
    ORDER BY created_at DESC, id
    FOR UPDATE
  LOOP
    v_token_count := v_token_count + 1;
  END LOOP;

  IF v_token_count > 1 THEN
    RETURN QUERY SELECT FALSE, 'INTEGRITY_ERROR'::TEXT, 'Integrity error: multiple non-voided voting entitlements found for member.'::TEXT, NULL::UUID, FALSE, NULL::TIMESTAMPTZ;
    RETURN;
  END IF;

  IF v_token_count = 1 THEN
    IF v_token.is_used IS TRUE THEN
      RETURN QUERY SELECT FALSE, 'ENTITLEMENT_CONSUMED'::TEXT, 'Voting entitlement already consumed.'::TEXT, v_token.id, FALSE, v_token.expires_at;
      RETURN;
    END IF;

    RETURN QUERY SELECT TRUE, 'ENTITLEMENT_EXISTS'::TEXT, 'Voting entitlement already exists.'::TEXT, v_token.id, FALSE, v_token.expires_at;
    RETURN;
  END IF;

  IF p_channel_sent NOT IN ('NONE', 'EMAIL') THEN
    RETURN QUERY SELECT FALSE, 'INTEGRITY_ERROR'::TEXT, 'Invalid entitlement channel. Allowed: NONE, EMAIL.'::TEXT, NULL::UUID, FALSE, NULL::TIMESTAMPTZ;
    RETURN;
  END IF;

  SELECT COALESCE(voting_token_ttl_hours, 168)
  INTO v_ttl_hours
  FROM election_settings
  WHERE id = 1;

  v_hash := COALESCE(p_token_hash, encode(digest(gen_random_bytes(32), 'sha256'), 'hex'));

  INSERT INTO tokens (
    member_id,
    token_hash,
    type,
    is_used,
    channel_sent,
    expires_at
  )
  VALUES (
    p_member_id,
    v_hash,
    'VOTING',
    FALSE,
    p_channel_sent,
    now() + (v_ttl_hours * interval '1 hour')
  )
  RETURNING id, tokens.expires_at
  INTO token_id, expires_at;

  RETURN QUERY SELECT TRUE, 'ENTITLEMENT_CREATED'::TEXT, 'Voting entitlement created.'::TEXT, token_id, TRUE, expires_at;
END;
$$;


ALTER FUNCTION private.ensure_voting_entitlement(p_member_id uuid, p_admin_id uuid, p_token_hash character varying, p_channel_sent character varying) OWNER TO postgres;

--
-- Name: generate_anonymous_blank_ballot_pool(integer, uuid); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.generate_anonymous_blank_ballot_pool(p_count integer, p_admin_id uuid DEFAULT NULL::uuid) RETURNS TABLE(success boolean, message text, generated_count integer, ballot_ids text[])
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
    AS $$
DECLARE
  v_ballot_id TEXT;
  v_ballot_ids TEXT[] := ARRAY[]::TEXT[];
  v_inserted INTEGER := 0;
  v_attempts INTEGER;
  i INTEGER;
BEGIN
  IF p_count IS NULL OR p_count < 1 OR p_count > 1000 THEN
    RETURN QUERY SELECT FALSE, 'Count must be between 1 and 1000.'::TEXT, 0, ARRAY[]::TEXT[];
    RETURN;
  END IF;

  FOR i IN 1..p_count LOOP
    v_attempts := 0;
    LOOP
      v_ballot_id := private.generate_opaque_paper_ballot_id();
      BEGIN
        INSERT INTO anonymous_paper_blanks(ballot_id, status) VALUES (v_ballot_id, 'AVAILABLE');
        INSERT INTO ballot_audit_log(action, ballot_id, channel, event_date, admin_id)
        VALUES ('ANONYMOUS_PAPER_BLANK_GENERATED', v_ballot_id, 'PAPER', CURRENT_DATE, p_admin_id);
        v_ballot_ids := array_append(v_ballot_ids, v_ballot_id);
        v_inserted := v_inserted + 1;
        EXIT;
      EXCEPTION WHEN unique_violation THEN
        v_attempts := v_attempts + 1;
        IF v_attempts >= 10 THEN
          RAISE EXCEPTION 'Could not generate unique anonymous paper ballot_id';
        END IF;
      END;
    END LOOP;
  END LOOP;

  RETURN QUERY SELECT TRUE, 'Anonymous paper ballot pool generated.'::TEXT, v_inserted, v_ballot_ids;
END;
$$;


ALTER FUNCTION private.generate_anonymous_blank_ballot_pool(p_count integer, p_admin_id uuid) OWNER TO postgres;

--
-- Name: generate_blank_paper_ballot_batch(integer, uuid); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.generate_blank_paper_ballot_batch(p_count integer, p_admin_id uuid DEFAULT NULL::uuid) RETURNS TABLE(batch_id uuid, generated_count integer, message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
    AS $$
BEGIN
  RAISE EXCEPTION 'generate_blank_paper_ballot_batch is superseded by generate_anonymous_blank_ballot_pool';
END;
$$;


ALTER FUNCTION private.generate_blank_paper_ballot_batch(p_count integer, p_admin_id uuid) OWNER TO postgres;

--
-- Name: generate_opaque_paper_ballot_id(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.generate_opaque_paper_ballot_id() RETURNS text
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


ALTER FUNCTION private.generate_opaque_paper_ballot_id() OWNER TO postgres;

--
-- Name: generate_qr_svg(text); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.generate_qr_svg(p_ballot_id text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
    AS $$
DECLARE
  v_qr TEXT;
BEGIN
  v_qr := '<svg xmlns="http://www.w3.org/2000/svg" width="200" height="200" viewBox="0 0 200 200">'
    || '<rect width="200" height="200" fill="white"/>'
    || '<text x="100" y="100" font-family="monospace" font-size="8" text-anchor="middle" dominant-baseline="middle">'
    || p_ballot_id
    || '</text></svg>';
  RETURN v_qr;
END;
$$;


ALTER FUNCTION private.generate_qr_svg(p_ballot_id text) OWNER TO postgres;

--
-- Name: generate_short_code(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.generate_short_code() RETURNS text
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


ALTER FUNCTION private.generate_short_code() OWNER TO postgres;

--
-- Name: get_pending_unmatched_nominations(integer, date, uuid); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.get_pending_unmatched_nominations(p_limit integer DEFAULT 200, p_cursor_date date DEFAULT NULL::date, p_cursor_id uuid DEFAULT NULL::uuid) RETURNS TABLE(id uuid, nominee_name text, reason text, submitted_date date)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $$
  SELECT an.id, an.nominee_name::TEXT, an.reason::TEXT, an.submitted_date
  FROM anonymous_nominations an
  WHERE an.nominee_member_id IS NULL
    AND (
      (p_cursor_date IS NULL AND p_cursor_id IS NULL)
      OR coalesce(an.submitted_date, DATE '0001-01-01') < coalesce(p_cursor_date, DATE '0001-01-01')
      OR (
        coalesce(an.submitted_date, DATE '0001-01-01') = coalesce(p_cursor_date, DATE '0001-01-01')
        AND p_cursor_id IS NOT NULL
        AND an.id > p_cursor_id
      )
    )
    AND NOT EXISTS (
      SELECT 1
      FROM nomination_adjudications na
      WHERE an.id = ANY(na.affected_nomination_ids)
    )
  ORDER BY an.submitted_date DESC NULLS LAST, an.id ASC
  LIMIT GREATEST(COALESCE(p_limit, 200), 0)
;
$$;


ALTER FUNCTION private.get_pending_unmatched_nominations(p_limit integer, p_cursor_date date, p_cursor_id uuid) OWNER TO postgres;

--
-- Name: issue_paper_ballot(uuid, uuid); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.issue_paper_ballot(p_member_id uuid, p_admin_id uuid DEFAULT NULL::uuid) RETURNS TABLE(success boolean, message text, member_name text, member_code text, short_code text, participation_date date, status text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
    AS $$
DECLARE
  v_short_code TEXT;
  v_attempts INTEGER := 0;
  v_inserted BOOLEAN := FALSE;
BEGIN
  WHILE v_attempts < 10 AND NOT v_inserted LOOP
    v_short_code := private.generate_short_code();
    BEGIN
      INSERT INTO paper_ballots(short_code, status) VALUES (v_short_code, 'AVAILABLE');
      v_inserted := TRUE;
    EXCEPTION WHEN unique_violation THEN
      v_attempts := v_attempts + 1;
    END;
  END LOOP;

  IF NOT v_inserted THEN
    RETURN QUERY SELECT FALSE, 'Could not generate unique identity-slip short code.'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::DATE, NULL::TEXT;
    RETURN;
  END IF;

  RETURN QUERY SELECT * FROM private.check_in_paper_voter(v_short_code, p_member_id, p_admin_id);
END;
$$;


ALTER FUNCTION private.issue_paper_ballot(p_member_id uuid, p_admin_id uuid) OWNER TO postgres;

--
-- Name: issue_preprinted_paper_ballot(text, uuid, uuid); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.issue_preprinted_paper_ballot(p_ballot_id text, p_member_id uuid, p_admin_id uuid DEFAULT NULL::uuid) RETURNS TABLE(success boolean, message text, ballot_id text, short_code text, qr_svg text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
    AS $$
BEGIN
  RETURN QUERY SELECT FALSE,
    'issue_preprinted_paper_ballot is superseded by check_in_paper_voter + anonymous blank pool.'::TEXT,
    NULL::TEXT, NULL::TEXT, NULL::TEXT;
END;
$$;


ALTER FUNCTION private.issue_preprinted_paper_ballot(p_ballot_id text, p_member_id uuid, p_admin_id uuid) OWNER TO postgres;

--
-- Name: paper_pool_reconciliation(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.paper_pool_reconciliation() RETURNS TABLE(checked_in_count bigint, spoiled_check_in_count bigint, available_blank_count bigint, cast_blank_count bigint, voided_blank_count bigint, paper_ballot_count bigint)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $$
  SELECT
    (SELECT count(*) FROM paper_ballots WHERE status = 'ISSUED_TO_VOTER'),
    (SELECT count(*) FROM paper_ballots WHERE status = 'SPOILED'),
    (SELECT count(*) FROM anonymous_paper_blanks WHERE status = 'AVAILABLE'),
    (SELECT count(*) FROM anonymous_paper_blanks WHERE status = 'CAST'),
    (SELECT count(*) FROM anonymous_paper_blanks WHERE status = 'VOIDED'),
    (SELECT count(*) FROM ballots WHERE channel = 'PAPER');
$$;


ALTER FUNCTION private.paper_pool_reconciliation() OWNER TO postgres;

--
-- Name: provision_voting_entitlements(uuid[], uuid); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.provision_voting_entitlements(p_member_ids uuid[] DEFAULT NULL::uuid[], p_admin_id uuid DEFAULT NULL::uuid) RETURNS TABLE(requested_count integer, created_count integer, existing_count integer, ineligible_count integer, consumed_count integer, integrity_failed_count integer)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
    AS $$
DECLARE
  v_member RECORD;
  v_result RECORD;
  v_requested_count INT := 0;
  v_created_count INT := 0;
  v_existing_count INT := 0;
  v_ineligible_count INT := 0;
  v_consumed_count INT := 0;
  v_integrity_failed_count INT := 0;
BEGIN
  FOR v_member IN
    SELECT m.id, m.voting_eligible
    FROM members m
    WHERE m.is_active = TRUE
      AND (p_member_ids IS NULL OR m.id = ANY(p_member_ids))
  LOOP
    v_requested_count := v_requested_count + 1;

    IF v_member.voting_eligible IS NOT TRUE THEN
      v_ineligible_count := v_ineligible_count + 1;
      CONTINUE;
    END IF;

    SELECT * INTO v_result
    FROM private.ensure_voting_entitlement(v_member.id, p_admin_id, NULL, 'NONE');

    IF v_result.success IS TRUE THEN
      IF v_result.created IS TRUE THEN
        v_created_count := v_created_count + 1;
      ELSE
        v_existing_count := v_existing_count + 1;
      END IF;
    ELSIF v_result.code = 'VOTER_INELIGIBLE' THEN
      v_ineligible_count := v_ineligible_count + 1;
    ELSIF v_result.code = 'ENTITLEMENT_CONSUMED' THEN
      v_consumed_count := v_consumed_count + 1;
    ELSIF v_result.code = 'INTEGRITY_ERROR' THEN
      v_integrity_failed_count := v_integrity_failed_count + 1;
    ELSE
      v_integrity_failed_count := v_integrity_failed_count + 1;
    END IF;
  END LOOP;

  -- SEC-18: route through the hash-chaining audit RPC, NOT a raw insert.
  -- A direct INSERT would leave record_hash/previous_hash NULL and break the
  -- tamper-evident chain. insert_audit_log is SECURITY DEFINER and computes the
  -- chain via compute_audit_log_hash.
  PERFORM public.insert_audit_log(
    'ENTITLEMENTS_PROVISIONED',
    p_admin_id,
    NULL::UUID,
    jsonb_build_object(
      'requested_count', v_requested_count,
      'created_count', v_created_count,
      'existing_count', v_existing_count,
      'ineligible_count', v_ineligible_count,
      'consumed_count', v_consumed_count,
      'integrity_failed_count', v_integrity_failed_count
    )
  );

  RETURN QUERY
  SELECT
    v_requested_count,
    v_created_count,
    v_existing_count,
    v_ineligible_count,
    v_consumed_count,
    v_integrity_failed_count;
END;
$$;


ALTER FUNCTION private.provision_voting_entitlements(p_member_ids uuid[], p_admin_id uuid) OWNER TO postgres;

--
-- Name: purge_roster_pii(uuid, text, text); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.purge_roster_pii(p_admin_id uuid, p_stage text, p_confirm text) RETURNS TABLE(success boolean, stage text, members_touched integer, message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'governance', 'extensions'
    AS $$
DECLARE
  v_phase TEXT;
  v_voting_end TIMESTAMPTZ;
  v_count INT := 0;
BEGIN
  IF p_confirm <> 'PURGE' THEN
    RETURN QUERY SELECT FALSE, p_stage, 0, 'Confirmation token mismatch'; RETURN;
  END IF;
  SELECT current_phase, voting_end INTO v_phase, v_voting_end FROM election_settings WHERE id = 1;

  IF p_stage = 'CONTACT' THEN
    IF v_phase NOT IN ('VOTING_CLOSED','COMPLETED') THEN
      RETURN QUERY SELECT FALSE, p_stage, 0, 'Stage CONTACT requires VOTING_CLOSED/COMPLETED'; RETURN;
    END IF;
    UPDATE members m SET
      email = NULL, phone = NULL,
      has_voted = (EXISTS (SELECT 1 FROM tokens t WHERE t.member_id = m.id AND t.type='VOTING' AND t.is_used = TRUE)
                OR EXISTS (SELECT 1 FROM paper_ballots p WHERE p.member_id = m.id AND p.status = 'VOTED'))
    WHERE email IS NOT NULL OR phone IS NOT NULL;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    PERFORM private.append_governance_event('CONTACT_PII_PURGED', p_admin_id, NULL, NULL, NULL,
      'roster PII minimization', 'storage limitation', ARRAY['contact'], ARRAY['members'], 'purged at voting close',
      jsonb_build_object('members_touched', v_count, 'phase', v_phase));
    RETURN QUERY SELECT TRUE, p_stage, v_count, 'Contact PII purged'; RETURN;

  ELSIF p_stage = 'IDENTITY' THEN
    IF v_voting_end IS NULL OR now() < v_voting_end + INTERVAL '30 days' THEN
      RETURN QUERY SELECT FALSE, p_stage, 0, 'Stage IDENTITY requires 30-day dispute window elapsed'; RETURN;
    END IF;
    UPDATE members SET
      full_name = 'Redacted member ' || substring(id::text from 1 for 8),
      member_code = 'PURGED-' || substring(id::text from 1 for 12),
      email = NULL, phone = NULL, is_age_eligible = NULL,
      voting_eligible = FALSE, eligibility_reason = 'PURGED', eligibility_source = 'PURGE'
    WHERE full_name NOT LIKE 'Redacted member %';
    GET DIAGNOSTICS v_count = ROW_COUNT;
    PERFORM private.append_governance_event('IDENTITY_PII_ANONYMIZED', p_admin_id, NULL, NULL, NULL,
      'roster identity anonymization', 'storage limitation', ARRAY['identity'], ARRAY['members'], 'anonymized after dispute window',
      jsonb_build_object('members_touched', v_count));
    RETURN QUERY SELECT TRUE, p_stage, v_count, 'Identity anonymized'; RETURN;
  END IF;
  RETURN QUERY SELECT FALSE, p_stage, 0, 'Unknown stage (use CONTACT or IDENTITY)';
END;
$$;


ALTER FUNCTION private.purge_roster_pii(p_admin_id uuid, p_stage text, p_confirm text) OWNER TO postgres;

--
-- Name: redeem_voting_token(character varying); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.redeem_voting_token(p_token_hash character varying) RETURNS TABLE(o_success boolean, o_message text, o_credential text, o_ttl_seconds integer)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
    AS $$
DECLARE
  v_token_id UUID; v_member_id UUID; v_is_used BOOLEAN; v_expires_at TIMESTAMPTZ; v_voided_at TIMESTAMPTZ;
  v_phase election_phase; v_voting_end TIMESTAMPTZ; v_voting_eligible BOOLEAN; v_paper_ballot RECORD;
  v_ttl_minutes INT; v_credential TEXT; v_credential_hash TEXT; v_active_reservation UUID;
BEGIN
  PERFORM private.sweep_expired_digital_reservations();

  SELECT current_phase, voting_end, COALESCE(digital_credential_ttl_minutes, 15)
    INTO v_phase, v_voting_end, v_ttl_minutes FROM election_settings WHERE id = 1;

  IF v_phase != 'VOTING' OR (v_voting_end IS NOT NULL AND NOW() > v_voting_end) THEN
    RETURN QUERY SELECT FALSE, 'Voting phase is closed or expired.'::TEXT, NULL::TEXT, NULL::INT; RETURN;
  END IF;

  SELECT id, member_id, is_used, expires_at, voided_at
    INTO v_token_id, v_member_id, v_is_used, v_expires_at, v_voided_at
    FROM tokens WHERE token_hash = p_token_hash AND type = 'VOTING' FOR UPDATE;

  IF v_token_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Invalid or non-existent voting token.'::TEXT, NULL::TEXT, NULL::INT; RETURN;
  END IF;
  IF v_voided_at IS NOT NULL THEN
    RETURN QUERY SELECT FALSE, 'This voting token has been voided and reissued. Please use your most recent link.'::TEXT, NULL::TEXT, NULL::INT; RETURN;
  END IF;
  IF v_expires_at IS NULL OR v_expires_at <= NOW() THEN
    RETURN QUERY SELECT FALSE, 'This voting token has expired.'::TEXT, NULL::TEXT, NULL::INT; RETURN;
  END IF;
  IF v_is_used THEN
    RETURN QUERY SELECT FALSE, 'This token has already been used or reserved for paper voting.'::TEXT, NULL::TEXT, NULL::INT; RETURN;
  END IF;

  SELECT voting_eligible INTO v_voting_eligible FROM members WHERE id = v_member_id AND is_active = TRUE FOR SHARE;
  IF NOT FOUND OR v_voting_eligible IS NOT TRUE THEN
    RETURN QUERY SELECT FALSE, 'Member is not eligible to vote.'::TEXT, NULL::TEXT, NULL::INT; RETURN;
  END IF;

  SELECT * INTO v_paper_ballot FROM paper_ballots
   WHERE member_id = v_member_id AND status IN ('ISSUED', 'ISSUED_TO_VOTER', 'VOTED') FOR SHARE;
  IF FOUND THEN
    RETURN QUERY SELECT FALSE, 'A paper ballot has already been issued for this member.'::TEXT, NULL::TEXT, NULL::INT; RETURN;
  END IF;

  SELECT id INTO v_active_reservation FROM digital_credential_reservations
   WHERE token_id = v_token_id AND expires_at > now() FOR UPDATE;
  IF v_active_reservation IS NOT NULL THEN
    RETURN QUERY SELECT FALSE, 'A digital voting credential is already active for this token. Please finish or wait for it to expire.'::TEXT, NULL::TEXT, NULL::INT; RETURN;
  END IF;

  v_credential := 'DVC-' || encode(gen_random_bytes(24), 'hex');
  v_credential_hash := encode(digest(v_credential, 'sha256'), 'hex');

  INSERT INTO anonymous_digital_credentials (credential_hash, status) VALUES (v_credential_hash, 'RESERVED');
  INSERT INTO digital_credential_reservations (credential_hash, token_id, expires_at)
  VALUES (v_credential_hash, v_token_id, now() + (v_ttl_minutes * interval '1 minute'));

  UPDATE tokens SET reserved_at = now(), reserved_channel = 'DIGITAL', reservation_released_at = NULL
   WHERE id = v_token_id;

  RETURN QUERY SELECT TRUE, 'Credential issued.'::TEXT, v_credential, (v_ttl_minutes * 60);
END;
$$;


ALTER FUNCTION private.redeem_voting_token(p_token_hash character varying) OWNER TO postgres;

--
-- Name: reissue_token(uuid, uuid, text, character varying); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.reissue_token(p_old_token_id uuid, p_admin_id uuid, p_reason text, p_new_token_hash character varying) RETURNS TABLE(success boolean, message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
    AS $$
DECLARE
  v_member_id UUID; v_type token_type; v_is_used BOOLEAN; v_voided TIMESTAMPTZ;
  v_ttl_hours INT; v_new_expires TIMESTAMPTZ; v_active_res UUID;
BEGIN
  PERFORM private.sweep_expired_digital_reservations();

  SELECT member_id, type, is_used, voided_at INTO v_member_id, v_type, v_is_used, v_voided
    FROM tokens WHERE id = p_old_token_id FOR UPDATE;

  IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Token not found'; RETURN; END IF;
  IF v_is_used THEN RETURN QUERY SELECT FALSE, 'Used token cannot be reissued.'; RETURN; END IF;
  IF v_voided IS NOT NULL THEN RETURN QUERY SELECT FALSE, 'Token already voided.'; RETURN; END IF;

  SELECT id INTO v_active_res FROM digital_credential_reservations
   WHERE token_id = p_old_token_id AND expires_at > now() FOR UPDATE;
  IF v_active_res IS NOT NULL THEN
    RETURN QUERY SELECT FALSE, 'Token has an active digital voting credential; release or wait for it to expire before reissuing.'; RETURN;
  END IF;

  IF v_type = 'VOTING' THEN
    SELECT voting_token_ttl_hours INTO v_ttl_hours FROM election_settings WHERE id = 1;
    v_new_expires := NOW() + (COALESCE(v_ttl_hours, 168) * interval '1 hour');
  ELSE
    v_new_expires := NOW() + interval '24 hours';
  END IF;

  UPDATE tokens SET voided_at = NOW(), void_reason = p_reason WHERE id = p_old_token_id;
  INSERT INTO tokens (member_id, token_hash, type, reissued_from_token_id, expires_at)
  VALUES (v_member_id, p_new_token_hash, v_type, p_old_token_id, v_new_expires);

  RETURN QUERY SELECT TRUE, 'Reissued';
END;
$$;


ALTER FUNCTION private.reissue_token(p_old_token_id uuid, p_admin_id uuid, p_reason text, p_new_token_hash character varying) OWNER TO postgres;

--
-- Name: reject_adjudication_mutation(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.reject_adjudication_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN RAISE EXCEPTION 'eligibility_adjudications is append-only'; END; $$;


ALTER FUNCTION private.reject_adjudication_mutation() OWNER TO postgres;

--
-- Name: reject_nomination_mutation(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.reject_nomination_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'anonymous_nominations rows are immutable (append-only).';
END; $$;


ALTER FUNCTION private.reject_nomination_mutation() OWNER TO postgres;

--
-- Name: reject_vote_audit_log_colocation(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.reject_vote_audit_log_colocation() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
    AS $$
BEGIN
  IF NEW.member_id IS NOT NULL
     AND (
       NEW.ballot_id IS NOT NULL OR NEW.candidate_id IS NOT NULL
       OR COALESCE(NEW.details, '{}'::jsonb) ? 'ballot_id'
       OR COALESCE(NEW.details, '{}'::jsonb) ? 'candidate_id'
       OR COALESCE(NEW.details, '{}'::jsonb) ? 'receipt_code'
       OR COALESCE(NEW.details, '{}'::jsonb) ? 'short_code'
       OR COALESCE(NEW.details, '{}'::jsonb) ? 'batch_id'
     ) THEN
    RAISE EXCEPTION 'vote_audit_log may not co-locate member_id with ballot/candidate/receipt/short_code handles';
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION private.reject_vote_audit_log_colocation() OWNER TO postgres;

--
-- Name: reject_vote_audit_log_mutation(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.reject_vote_audit_log_mutation() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
    AS $$
BEGIN
  RAISE EXCEPTION 'vote_audit_log is append-only; UPDATE/DELETE is not permitted.';
END;
$$;


ALTER FUNCTION private.reject_vote_audit_log_mutation() OWNER TO postgres;

--
-- Name: release_digital_voting_reservation(character varying); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.release_digital_voting_reservation(p_token_hash character varying) RETURNS TABLE(o_success boolean, o_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
    AS $$
DECLARE v_token_id UUID; v_is_used BOOLEAN; v_res_id UUID;
BEGIN
  SELECT id, is_used INTO v_token_id, v_is_used FROM tokens
   WHERE token_hash = p_token_hash AND type = 'VOTING' FOR UPDATE;
  IF v_token_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Invalid or non-existent voting token.'::TEXT; RETURN;
  END IF;
  IF v_is_used IS TRUE THEN
    RETURN QUERY SELECT FALSE, 'Token is already consumed; nothing to release.'::TEXT; RETURN;
  END IF;

  SELECT id INTO v_res_id FROM digital_credential_reservations WHERE token_id = v_token_id FOR UPDATE;
  IF v_res_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'No active digital reservation for this token.'::TEXT; RETURN;
  END IF;

  DELETE FROM anonymous_digital_credentials
   WHERE credential_hash = (SELECT credential_hash FROM digital_credential_reservations WHERE id = v_res_id);
  UPDATE tokens SET reserved_at = NULL, reserved_channel = NULL, reservation_released_at = now()
   WHERE id = v_token_id AND is_used = FALSE AND reserved_channel = 'DIGITAL';

  RETURN QUERY SELECT TRUE, 'Digital reservation released.'::TEXT;
END;
$$;


ALTER FUNCTION private.release_digital_voting_reservation(p_token_hash character varying) OWNER TO postgres;

--
-- Name: search_members_for_nomination(character varying, text); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.search_members_for_nomination(p_token_hash character varying, p_query text) RETURNS TABLE(member_id uuid, full_name text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
    AS $$
DECLARE v_phase election_phase; v_token_id UUID; v_is_used BOOLEAN;
        v_expires_at TIMESTAMPTZ; v_voided_at TIMESTAMPTZ;
BEGIN
  IF p_query IS NULL OR length(trim(p_query)) < 2 THEN RETURN; END IF;
  SELECT current_phase INTO v_phase FROM election_settings WHERE id=1;
  IF v_phase <> 'NOMINATION' THEN RETURN; END IF;

  SELECT id, is_used, expires_at, voided_at
    INTO v_token_id, v_is_used, v_expires_at, v_voided_at
    FROM tokens WHERE token_hash = p_token_hash AND type='NOMINATION';
  IF v_token_id IS NULL OR v_is_used OR v_voided_at IS NOT NULL
     OR v_expires_at IS NULL OR v_expires_at <= NOW() THEN RETURN; END IF;

  RETURN QUERY
    SELECT m.id, m.full_name::text FROM members m
    WHERE m.is_active = TRUE
      AND (
        m.full_name ILIKE p_query || '%'
        OR p_query <% m.full_name
      )
    ORDER BY word_similarity(p_query, m.full_name) DESC, m.full_name
    LIMIT 5;
END; $$;


ALTER FUNCTION private.search_members_for_nomination(p_token_hash character varying, p_query text) OWNER TO postgres;

--
-- Name: set_member_active(uuid, boolean); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.set_member_active(p_member_id uuid, p_active boolean) RETURNS public.members
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
    AS $$
DECLARE
  v_member members;
BEGIN
  PERFORM private.assert_electorate_editable();

  UPDATE members
  SET is_active = p_active
  WHERE id = p_member_id
  RETURNING * INTO v_member;

  IF v_member.id IS NULL THEN
    RAISE EXCEPTION 'Member not found.';
  END IF;

  RETURN v_member;
END;
$$;


ALTER FUNCTION private.set_member_active(p_member_id uuid, p_active boolean) OWNER TO postgres;

--
-- Name: spoil_paper_ballot(text, text, uuid); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.spoil_paper_ballot(p_ballot_id text, p_reason text, p_admin_id uuid DEFAULT NULL::uuid) RETURNS TABLE(success boolean, message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
    AS $$
BEGIN
  RETURN QUERY SELECT FALSE,
    'spoil_paper_ballot is superseded by spoil_paper_check_in or void_anonymous_paper_blank.'::TEXT;
END;
$$;


ALTER FUNCTION private.spoil_paper_ballot(p_ballot_id text, p_reason text, p_admin_id uuid) OWNER TO postgres;

--
-- Name: spoil_paper_check_in(text, text, uuid); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.spoil_paper_check_in(p_short_code text, p_reason text DEFAULT 'Spoiled before record'::text, p_admin_id uuid DEFAULT NULL::uuid) RETURNS TABLE(success boolean, message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
    AS $$
DECLARE v_short_code TEXT := upper(trim(p_short_code)); v_paper RECORD; v_token RECORD;
BEGIN
  SELECT * INTO v_paper FROM paper_ballots WHERE short_code = v_short_code FOR UPDATE;
  IF v_paper.id IS NULL THEN RETURN QUERY SELECT FALSE, 'Identity slip not found.'::TEXT; RETURN; END IF;
  IF v_paper.status <> 'ISSUED_TO_VOTER' THEN
    RETURN QUERY SELECT FALSE, 'Only checked-in, unclosed paper reservations can be spoiled here.'::TEXT; RETURN;
  END IF;
  IF v_paper.member_id IS NULL OR v_paper.token_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Identity slip has no member/token reservation to release.'::TEXT; RETURN;
  END IF;

  SELECT * INTO v_token FROM tokens
   WHERE id = v_paper.token_id AND member_id = v_paper.member_id AND type = 'VOTING' FOR UPDATE;
  IF v_token.id IS NULL THEN RETURN QUERY SELECT FALSE, 'Voting entitlement not found.'::TEXT; RETURN; END IF;

  IF v_token.reserved_channel IS DISTINCT FROM 'PAPER' THEN
    RETURN QUERY SELECT FALSE, 'Reservation is not a PAPER reservation and cannot be spoiled here.'::TEXT; RETURN;
  END IF;

  UPDATE paper_ballots SET status = 'SPOILED', spoiled_at = now(), spoiled_by = p_admin_id, invalid_reason = p_reason
   WHERE id = v_paper.id;

  INSERT INTO participation_audit(action, member_id, token_id, channel, event_date, admin_id)
  VALUES ('PAPER_CHECK_IN_SPOILED_PRE_RECORD', v_paper.member_id, v_paper.token_id, 'PAPER', CURRENT_DATE, p_admin_id);

  RETURN QUERY SELECT TRUE, 'Identity slip marked SPOILED for dispute history. The voting entitlement was NOT auto-released; use reissue if a genuinely unused entitlement must be restored.'::TEXT;
END;
$$;


ALTER FUNCTION private.spoil_paper_check_in(p_short_code text, p_reason text, p_admin_id uuid) OWNER TO postgres;

--
-- Name: submit_anonymous_vote(character varying, uuid); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.submit_anonymous_vote(p_token_hash character varying, p_candidate_id uuid) RETURNS TABLE(success boolean, message text, receipt_code text, ballot_id text)
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


ALTER FUNCTION private.submit_anonymous_vote(p_token_hash character varying, p_candidate_id uuid) OWNER TO postgres;

--
-- Name: submit_nomination(character varying, jsonb); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.submit_nomination(p_token_hash character varying, p_nominees jsonb) RETURNS TABLE(success boolean, message text, inserted_count integer)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
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


ALTER FUNCTION private.submit_nomination(p_token_hash character varying, p_nominees jsonb) OWNER TO postgres;

--
-- Name: submit_paper_invalid(text, text); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.submit_paper_invalid(p_ballot_id text, p_reason text) RETURNS TABLE(success boolean, message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
    AS $$
BEGIN
  RETURN QUERY SELECT FALSE,
    'submit_paper_invalid is superseded by spoil_paper_check_in or void_anonymous_paper_blank.'::TEXT;
END;
$$;


ALTER FUNCTION private.submit_paper_invalid(p_ballot_id text, p_reason text) OWNER TO postgres;

--
-- Name: submit_paper_vote(text, uuid, uuid); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.submit_paper_vote(p_ballot_id text, p_candidate_id uuid, p_admin_id uuid DEFAULT NULL::uuid) RETURNS TABLE(success boolean, message text, receipt_code text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
    AS $_$
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
$_$;


ALTER FUNCTION private.submit_paper_vote(p_ballot_id text, p_candidate_id uuid, p_admin_id uuid) OWNER TO postgres;

--
-- Name: sweep_expired_digital_reservations(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.sweep_expired_digital_reservations() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
    AS $$
DECLARE
  v_expired_token_ids UUID[];
  v_swept INT := 0;
BEGIN
  WITH expired AS (
    DELETE FROM digital_credential_reservations WHERE expires_at <= now() RETURNING token_id
  )
  SELECT array_agg(token_id) INTO v_expired_token_ids FROM expired;

  IF v_expired_token_ids IS NOT NULL THEN
    UPDATE tokens t
    SET reserved_at = NULL, reserved_channel = NULL, reservation_released_at = now()
    WHERE t.id = ANY(v_expired_token_ids) AND t.is_used = FALSE AND t.reserved_channel = 'DIGITAL';
    GET DIAGNOSTICS v_swept = ROW_COUNT;
  END IF;
  RETURN v_swept;
END;
$$;


ALTER FUNCTION private.sweep_expired_digital_reservations() OWNER TO postgres;

--
-- Name: void_anonymous_paper_blank(text, text, uuid); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.void_anonymous_paper_blank(p_ballot_id text, p_reason text DEFAULT 'Voided anonymous blank'::text, p_admin_id uuid DEFAULT NULL::uuid) RETURNS TABLE(success boolean, message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
    AS $_$
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
$_$;


ALTER FUNCTION private.void_anonymous_paper_blank(p_ballot_id text, p_reason text, p_admin_id uuid) OWNER TO postgres;

--
-- Name: void_unused_anonymous_paper_blanks(uuid, text); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.void_unused_anonymous_paper_blanks(p_admin_id uuid DEFAULT NULL::uuid, p_reason text DEFAULT 'Election closed - voiding unused anonymous paper blanks'::text) RETURNS TABLE(voided_count integer, message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
    AS $$
DECLARE
  v_count INTEGER := 0;
BEGIN
  UPDATE anonymous_paper_blanks SET status = 'VOIDED', voided_at = now(), void_reason = p_reason
  WHERE status = 'AVAILABLE';

  GET DIAGNOSTICS v_count = ROW_COUNT;

  INSERT INTO ballot_audit_log(action, channel, event_date, admin_id, details)
  VALUES ('ANONYMOUS_PAPER_POOL_VOID_UNUSED', 'PAPER', CURRENT_DATE, p_admin_id, jsonb_build_object('voided_count', v_count));

  RETURN QUERY SELECT v_count, 'Unused anonymous paper blanks voided.'::TEXT;
END;
$$;


ALTER FUNCTION private.void_unused_anonymous_paper_blanks(p_admin_id uuid, p_reason text) OWNER TO postgres;

--
-- Name: void_unused_paper_ballots(uuid, text, uuid); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.void_unused_paper_ballots(p_batch_id uuid DEFAULT NULL::uuid, p_reason text DEFAULT 'Election closed - voiding unused anonymous paper blanks'::text, p_admin_id uuid DEFAULT NULL::uuid) RETURNS TABLE(voided_count integer, message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
    AS $$
BEGIN
  RETURN QUERY SELECT * FROM private.void_unused_anonymous_paper_blanks(p_admin_id, p_reason);
END;
$$;


ALTER FUNCTION private.void_unused_paper_ballots(p_batch_id uuid, p_reason text, p_admin_id uuid) OWNER TO postgres;

--
-- Name: wipe_election_data(uuid, character varying); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.wipe_election_data(p_admin_id uuid, p_token_hash character varying) RETURNS TABLE(success boolean, message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'governance', 'extensions'
    AS $$
DECLARE
  v_phase election_phase;
  v_token_record RECORD;
BEGIN
  SELECT current_phase
    INTO v_phase
  FROM election_settings
  WHERE id = 1
  FOR UPDATE;

  IF NOT FOUND OR v_phase IS NULL THEN
    RAISE EXCEPTION 'Missing election settings row (id=1).';
  END IF;

  IF v_phase <> 'SETUP' THEN
    RAISE EXCEPTION 'Database wipe is only allowed during SETUP phase.';
  END IF;

  SELECT admin_session_id, confirmed_at, expires_at
    INTO v_token_record
  FROM wipe_confirmation_tokens
  WHERE admin_session_id = p_admin_id
    AND token_hash = p_token_hash
  FOR UPDATE;

  IF NOT FOUND OR v_token_record.confirmed_at IS NULL THEN
    RAISE EXCEPTION 'wipe not confirmed';
  END IF;

  IF v_token_record.expires_at <= clock_timestamp() THEN
    RAISE EXCEPTION 'wipe confirmation expired';
  END IF;

  PERFORM private.append_governance_event(
    'WIPE_STARTED', p_admin_id, 'admin', NULL, NULL,
    'Election data wipe for new-election setup', 'Legitimate interest',
    NULL, NULL, NULL,
    jsonb_build_object('scope', 'all election-scoped tables + members')
  );

  TRUNCATE candidates, tokens, anonymous_nominations, ballots, paper_ballots,
    paper_ballot_batches, vote_audit_log, eligibility_adjudications, phase_change_tokens,
    wipe_confirmation_tokens, admin_sessions, rate_limit_hits,
    anonymous_paper_blanks, anonymous_digital_credentials,
    digital_credential_reservations, nomination_adjudications,
    participation_audit, ballot_audit_log
    CASCADE;

  DELETE FROM members WHERE id IS NOT NULL;

  UPDATE election_settings SET current_phase = 'SETUP' WHERE id = 1;

  -- F16 structural fix (2026-10-08): dynamic completeness check over ALL
  -- application schemas (public, private, governance) instead of an
  -- enumerated public-table list, plus outright rejection of any unexpected
  -- non-system schema. A rogue schema (e.g. the historical backup_wave6,
  -- which survived a full wipe with co-located member/ballot/candidate
  -- rows) or a rogue table can no longer evade the check. Fail-closed: new
  -- tables and schemas are covered by default; only the explicit survivor
  -- allowlist below is exempt, and its entries must exist.
  DECLARE
    v_schema_bad TEXT;
    v_table_bad  TEXT;
    v_survivor   TEXT;
    v_row        RECORD;
    v_has_rows   BOOLEAN;
    v_survivors  TEXT[] := ARRAY[
      'public.election_settings',
      'governance.processing_activity_ledger'
    ];
  BEGIN
    -- (a) No unexpected non-system schema may exist at all.
    SELECT string_agg(nspname, ', ' ORDER BY nspname)
      INTO v_schema_bad
    FROM pg_namespace
    WHERE nspname NOT IN (
        'public', 'private', 'governance',
        'auth', 'storage', 'realtime', 'vault', 'extensions',
        'graphql', 'graphql_public', 'pgbouncer', 'supabase_migrations',
        'information_schema'
      )
      AND nspname NOT LIKE 'pg\_%';

    IF v_schema_bad IS NOT NULL THEN
      RAISE EXCEPTION
        'wipe completeness check failed: unexpected schema(s) present: %',
        v_schema_bad;
    END IF;

    -- (b) Survivor allowlist entries must exist (typo protection).
    FOREACH v_survivor IN ARRAY v_survivors LOOP
      IF to_regclass(v_survivor) IS NULL THEN
        RAISE EXCEPTION
          'wipe completeness check failed: survivor allowlist entry % does not exist',
          v_survivor;
      END IF;
    END LOOP;

    -- (c) Every other table / partitioned table / materialized view in the
    --     application schemas must be empty.
    FOR v_row IN
      SELECT n.nspname AS sch, c.relname AS tbl
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE c.relkind IN ('r', 'p', 'm')
        AND n.nspname IN ('public', 'private', 'governance')
        AND (n.nspname || '.' || c.relname) <> ALL (v_survivors)
      ORDER BY n.nspname, c.relname
    LOOP
      EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.%I)', v_row.sch, v_row.tbl)
        INTO v_has_rows;
      IF v_has_rows THEN
        v_table_bad := coalesce(v_table_bad || ', ', '') || v_row.sch || '.' || v_row.tbl;
      END IF;
    END LOOP;

    IF v_table_bad IS NOT NULL THEN
      RAISE EXCEPTION
        'wipe completeness check failed: non-empty table(s) after wipe: %',
        v_table_bad;
    END IF;
  END;

  PERFORM private.append_governance_event(
    'WIPE_COMPLETED', p_admin_id, 'admin', NULL, NULL,
    'Election data wipe for new-election setup', 'Legitimate interest',
    NULL, NULL, NULL,
    jsonb_build_object('scope', 'all election-scoped tables + members', 'result', 'clean SETUP state')
  );

  RETURN QUERY SELECT TRUE, 'Election data wiped. Database is ready for a new election (SETUP phase). All admin sessions were revoked.'::TEXT;
END;
$$;


ALTER FUNCTION private.wipe_election_data(p_admin_id uuid, p_token_hash character varying) OWNER TO postgres;

--
-- Name: adjudicate_eligibility(uuid, uuid, boolean, text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.adjudicate_eligibility(p_admin_session_id uuid, p_member_id uuid, p_new_voting_eligible boolean, p_new_eligibility_reason text, p_note text DEFAULT NULL::text) RETURNS TABLE(success boolean, message text, member_id uuid)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $_$
  SELECT * FROM private.adjudicate_eligibility($1,$2,$3,$4,$5);
$_$;


ALTER FUNCTION public.adjudicate_eligibility(p_admin_session_id uuid, p_member_id uuid, p_new_voting_eligible boolean, p_new_eligibility_reason text, p_note text) OWNER TO postgres;

--
-- Name: adjudicate_nomination(text, uuid, uuid[], uuid, text, text, uuid, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.adjudicate_nomination(p_decision text, p_admin_session_id uuid, p_affected_nomination_ids uuid[], p_nominee_member_id uuid DEFAULT NULL::uuid, p_nominee_name text DEFAULT NULL::text, p_candidate_statement text DEFAULT NULL::text, p_candidate_id uuid DEFAULT NULL::uuid, p_note text DEFAULT NULL::text) RETURNS TABLE(success boolean, message text, candidate_id uuid)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $$
  SELECT * FROM private.adjudicate_nomination(
    p_decision, p_admin_session_id, p_affected_nomination_ids,
    p_nominee_member_id, p_nominee_name, p_candidate_statement,
    p_candidate_id, p_note);
$$;


ALTER FUNCTION public.adjudicate_nomination(p_decision text, p_admin_session_id uuid, p_affected_nomination_ids uuid[], p_nominee_member_id uuid, p_nominee_name text, p_candidate_statement text, p_candidate_id uuid, p_note text) OWNER TO postgres;

--
-- Name: admin_add_nomination(uuid, text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.admin_add_nomination(p_nominee_member_id uuid, p_nominee_name text, p_reason text) RETURNS TABLE(success boolean, message text)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $$
  SELECT * FROM private.admin_add_nomination(p_nominee_member_id, p_nominee_name, p_reason);
$$;


ALTER FUNCTION public.admin_add_nomination(p_nominee_member_id uuid, p_nominee_name text, p_reason text) OWNER TO postgres;

--
-- Name: append_governance_event(text, uuid, text, text, text, text, text, text[], text[], text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.append_governance_event(p_event_type text, p_actor_admin_id uuid, p_actor_label text, p_controller_name text, p_organization_ref text, p_processing_purpose text, p_lawful_basis text, p_data_categories text[], p_data_subject_categories text[], p_retention_policy text, p_event_summary jsonb) RETURNS uuid
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $_$
  SELECT private.append_governance_event($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11);
$_$;


ALTER FUNCTION public.append_governance_event(p_event_type text, p_actor_admin_id uuid, p_actor_label text, p_controller_name text, p_organization_ref text, p_processing_purpose text, p_lawful_basis text, p_data_categories text[], p_data_subject_categories text[], p_retention_policy text, p_event_summary jsonb) OWNER TO postgres;

--
-- Name: assert_electorate_editable(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.assert_electorate_editable() RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $$
  SELECT private.assert_electorate_editable();
$$;


ALTER FUNCTION public.assert_electorate_editable() OWNER TO postgres;

--
-- Name: cast_anonymous_digital_vote(text, uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.cast_anonymous_digital_vote(p_credential text, p_candidate_id uuid) RETURNS TABLE(o_success boolean, o_message text, o_receipt_code text, o_ballot_id text)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $$ SELECT * FROM private.cast_anonymous_digital_vote(p_credential, p_candidate_id); $$;


ALTER FUNCTION public.cast_anonymous_digital_vote(p_credential text, p_candidate_id uuid) OWNER TO postgres;

--
-- Name: check_in_paper_voter(text, uuid, uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.check_in_paper_voter(p_short_code text, p_member_id uuid, p_admin_id uuid DEFAULT NULL::uuid) RETURNS TABLE(success boolean, message text, member_name text, member_code text, short_code text, participation_date date, status text)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $$ SELECT * FROM private.check_in_paper_voter(p_short_code, p_member_id, p_admin_id); $$;


ALTER FUNCTION public.check_in_paper_voter(p_short_code text, p_member_id uuid, p_admin_id uuid) OWNER TO postgres;

--
-- Name: check_rate_limit(text, integer, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.check_rate_limit(p_identifier text, p_window_seconds integer DEFAULT 60, p_max_requests integer DEFAULT 10) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
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


ALTER FUNCTION public.check_rate_limit(p_identifier text, p_window_seconds integer, p_max_requests integer) OWNER TO postgres;

--
-- Name: compute_audit_log_hash(text, uuid, uuid, jsonb, character, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.compute_audit_log_hash(p_action text, p_admin_id uuid, p_member_id uuid, p_details jsonb, p_previous_hash character, p_created_at timestamp with time zone) RETURNS character
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
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


ALTER FUNCTION public.compute_audit_log_hash(p_action text, p_admin_id uuid, p_member_id uuid, p_details jsonb, p_previous_hash character, p_created_at timestamp with time zone) OWNER TO postgres;

--
-- Name: correct_paper_vote(text, uuid, uuid, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.correct_paper_vote(p_ballot_id text, p_new_candidate_id uuid, p_admin_id uuid DEFAULT NULL::uuid, p_reason text DEFAULT NULL::text) RETURNS TABLE(success boolean, message text)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $$ SELECT * FROM private.correct_paper_vote(p_ballot_id, p_new_candidate_id, p_admin_id, p_reason); $$;


ALTER FUNCTION public.correct_paper_vote(p_ballot_id text, p_new_candidate_id uuid, p_admin_id uuid, p_reason text) OWNER TO postgres;

--
-- Name: create_member(text, text, text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.create_member(p_full_name text, p_email text DEFAULT NULL::text, p_phone text DEFAULT NULL::text, p_member_code text DEFAULT NULL::text) RETURNS public.members
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $$
  SELECT * FROM private.create_member(p_full_name, p_email, p_phone, p_member_code);
$$;


ALTER FUNCTION public.create_member(p_full_name text, p_email text, p_phone text, p_member_code text) OWNER TO postgres;

--
-- Name: ensure_voting_entitlement(uuid, uuid, character varying, character varying); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.ensure_voting_entitlement(p_member_id uuid, p_admin_id uuid DEFAULT NULL::uuid, p_token_hash character varying DEFAULT NULL::character varying, p_channel_sent character varying DEFAULT 'NONE'::character varying) RETURNS TABLE(success boolean, code text, message text, token_id uuid, created boolean, expires_at timestamp with time zone)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $$
  SELECT * FROM private.ensure_voting_entitlement(p_member_id, p_admin_id, p_token_hash, p_channel_sent);
$$;


ALTER FUNCTION public.ensure_voting_entitlement(p_member_id uuid, p_admin_id uuid, p_token_hash character varying, p_channel_sent character varying) OWNER TO postgres;

--
-- Name: f4_candidates(); Type: FUNCTION; Schema: public; Owner: f4_public_reader
--

CREATE FUNCTION public.f4_candidates() RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
  SELECT COALESCE(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'id', c.id,
        'full_name', c.full_name,
        'statement', c.statement,
        'photo_url', c.photo_url
      )
      ORDER BY c.created_at ASC, c.id ASC
    ),
    '[]'::jsonb
  )
  FROM public.candidates AS c
  WHERE c.is_active = true;
$$;


ALTER FUNCTION public.f4_candidates() OWNER TO f4_public_reader;

--
-- Name: f4_election_status(); Type: FUNCTION; Schema: public; Owner: f4_public_reader
--

CREATE FUNCTION public.f4_election_status() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
  v_current_phase public.election_phase;
  v_nomination_start timestamptz;
  v_nomination_end timestamptz;
  v_voting_start timestamptz;
  v_voting_end timestamptz;
  v_allow_write_ins boolean;
  v_max_nominees_per_member integer;
BEGIN
  SELECT
    s.current_phase,
    s.nomination_start,
    s.nomination_end,
    s.voting_start,
    s.voting_end,
    s.allow_write_ins,
    s.max_nominees_per_member
    INTO
      v_current_phase,
      v_nomination_start,
      v_nomination_end,
      v_voting_start,
      v_voting_end,
      v_allow_write_ins,
      v_max_nominees_per_member
  FROM public.election_settings
  AS s
  WHERE id = 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'public read unavailable';
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'phase', v_current_phase::text,
    'current_phase', v_current_phase::text,
    'nomination_start', v_nomination_start,
    'nomination_end', v_nomination_end,
    'voting_start', v_voting_start,
    'voting_end', v_voting_end,
    'allow_write_ins', v_allow_write_ins,
    'max_nominees_per_member', v_max_nominees_per_member
  );
END;
$$;


ALTER FUNCTION public.f4_election_status() OWNER TO f4_public_reader;

--
-- Name: f4_results(text); Type: FUNCTION; Schema: public; Owner: f4_public_reader
--

CREATE FUNCTION public.f4_results(p_receipt_code text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
  v_phase public.election_phase;
  v_receipt text;
  v_total_votes bigint;
  v_receipt_found boolean := NULL;
  v_results jsonb;
BEGIN
  SELECT s.current_phase
    INTO v_phase
  FROM public.election_settings AS s
  WHERE s.id = 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'public read unavailable';
  END IF;

  IF v_phase NOT IN ('VOTING_CLOSED', 'COMPLETED') THEN
    RETURN pg_catalog.jsonb_build_object(
      'published', false,
      'phase', v_phase::text
    );
  END IF;

  v_receipt := NULLIF(pg_catalog.upper(pg_catalog.btrim(p_receipt_code)), '');
  IF v_receipt IS NOT NULL THEN
    IF pg_catalog.length(v_receipt) > 32 THEN
      RAISE EXCEPTION 'public read unavailable';
    END IF;
    v_receipt := pg_catalog.lower(v_receipt);
  END IF;

  SELECT pg_catalog.count(b.candidate_id)
    INTO v_total_votes
  FROM public.ballots AS b;

  IF v_receipt IS NOT NULL THEN
    SELECT EXISTS(
      SELECT 1
      FROM public.ballots AS b
      WHERE pg_catalog.lower(b.receipt_code) = v_receipt
    )
      INTO v_receipt_found;
  END IF;

  SELECT COALESCE(
           pg_catalog.jsonb_agg(r.row_obj ORDER BY r.votes DESC, r.created_at ASC, r.id ASC),
           '[]'::jsonb
         )
    INTO v_results
  FROM (
    SELECT
      c.id,
      c.created_at,
      pg_catalog.count(b.candidate_id) AS votes,
      pg_catalog.jsonb_build_object(
        'id', c.id,
        'full_name', c.full_name,
        'statement', c.statement,
        'photo_url', c.photo_url,
        'votes', pg_catalog.count(b.candidate_id),
        'percentage', CASE
          WHEN v_total_votes > 0
            THEN pg_catalog.round((pg_catalog.count(b.candidate_id)::numeric * 100.0) / v_total_votes::numeric, 1)
          ELSE 0
        END
      ) AS row_obj
    FROM public.candidates AS c
    LEFT JOIN public.ballots AS b
      ON b.candidate_id = c.id
    WHERE c.is_active = true
    GROUP BY c.id, c.full_name, c.statement, c.photo_url, c.created_at
  ) AS r;

  RETURN pg_catalog.jsonb_build_object(
    'published', true,
    'phase', v_phase::text,
    'totalVotes', v_total_votes,
    'results', v_results,
    'receipt_found', v_receipt_found
  );
END;
$$;


ALTER FUNCTION public.f4_results(p_receipt_code text) OWNER TO f4_public_reader;

--
-- Name: f4_verify_ballot(text, text); Type: FUNCTION; Schema: public; Owner: f4_public_reader
--

CREATE FUNCTION public.f4_verify_ballot(p_ballot_id text, p_receipt_code text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
DECLARE
  v_ballot_id text;
  v_receipt text;
  v_bound constant integer := 256;
  v_found_channel text;
  v_found_cast_date date;
  v_found_receipt_code text;
BEGIN
  v_ballot_id := NULLIF(pg_catalog.btrim(p_ballot_id), '');
  v_receipt := NULLIF(pg_catalog.upper(pg_catalog.btrim(p_receipt_code)), '');

  IF v_ballot_id IS NOT NULL AND pg_catalog.length(v_ballot_id) > v_bound THEN
    RETURN pg_catalog.jsonb_build_object('found', false);
  END IF;

  IF v_receipt IS NOT NULL THEN
    IF pg_catalog.length(v_receipt) > 32 THEN
      RETURN pg_catalog.jsonb_build_object('found', false);
    END IF;

    IF v_receipt !~ '^(VC|PB)-[0-9A-F]{10}$' THEN
      RETURN pg_catalog.jsonb_build_object('found', false);
    END IF;

    v_receipt := pg_catalog.upper(pg_catalog.left(v_receipt, 3)) || pg_catalog.lower(pg_catalog.right(v_receipt, 10));
  END IF;

  IF v_ballot_id IS NULL AND v_receipt IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('found', false);
  END IF;

  IF v_ballot_id IS NOT NULL THEN
    SELECT b.channel, b.cast_date, b.receipt_code
      INTO v_found_channel, v_found_cast_date, v_found_receipt_code
    FROM public.ballots AS b
    WHERE b.ballot_id = v_ballot_id
    LIMIT 1;

    IF NOT FOUND THEN
      RETURN pg_catalog.jsonb_build_object('found', false);
    END IF;

    RETURN pg_catalog.jsonb_build_object(
      'found', true,
      'channel', v_found_channel,
      'cast_date', v_found_cast_date,
      'receipt_match', CASE
        WHEN v_receipt IS NULL THEN NULL
        ELSE (v_found_receipt_code = v_receipt)
      END
    );
  END IF;

  SELECT b.channel, b.cast_date
    INTO v_found_channel, v_found_cast_date
  FROM public.ballots AS b
  WHERE b.receipt_code = v_receipt
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('found', false);
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'found', true,
    'channel', v_found_channel,
    'cast_date', v_found_cast_date
  );
END;
$_$;


ALTER FUNCTION public.f4_verify_ballot(p_ballot_id text, p_receipt_code text) OWNER TO f4_public_reader;

--
-- Name: generate_anonymous_blank_ballot_pool(integer, uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.generate_anonymous_blank_ballot_pool(p_count integer, p_admin_id uuid DEFAULT NULL::uuid) RETURNS TABLE(success boolean, message text, generated_count integer, ballot_ids text[])
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $$ SELECT * FROM private.generate_anonymous_blank_ballot_pool(p_count, p_admin_id); $$;


ALTER FUNCTION public.generate_anonymous_blank_ballot_pool(p_count integer, p_admin_id uuid) OWNER TO postgres;

--
-- Name: generate_blank_paper_ballot_batch(integer, uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.generate_blank_paper_ballot_batch(p_count integer, p_admin_id uuid DEFAULT NULL::uuid) RETURNS TABLE(batch_id uuid, generated_count integer, message text)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $$ SELECT * FROM private.generate_blank_paper_ballot_batch(p_count, p_admin_id); $$;


ALTER FUNCTION public.generate_blank_paper_ballot_batch(p_count integer, p_admin_id uuid) OWNER TO postgres;

--
-- Name: get_pending_unmatched_nominations(integer, date, uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_pending_unmatched_nominations(p_limit integer DEFAULT 200, p_cursor_date date DEFAULT NULL::date, p_cursor_id uuid DEFAULT NULL::uuid) RETURNS TABLE(id uuid, nominee_name text, reason text, submitted_date date)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $$
  SELECT * FROM private.get_pending_unmatched_nominations(p_limit, p_cursor_date, p_cursor_id);
$$;


ALTER FUNCTION public.get_pending_unmatched_nominations(p_limit integer, p_cursor_date date, p_cursor_id uuid) OWNER TO postgres;

--
-- Name: insert_audit_log(text, uuid, uuid, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.insert_audit_log(p_action text, p_admin_id uuid DEFAULT NULL::uuid, p_member_id uuid DEFAULT NULL::uuid, p_details jsonb DEFAULT '{}'::jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'private', 'extensions'
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


ALTER FUNCTION public.insert_audit_log(p_action text, p_admin_id uuid, p_member_id uuid, p_details jsonb) OWNER TO postgres;

--
-- Name: issue_paper_ballot(uuid, uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.issue_paper_ballot(p_member_id uuid, p_admin_id uuid DEFAULT NULL::uuid) RETURNS TABLE(success boolean, message text, member_name text, member_code text, short_code text, participation_date date, status text)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $$ SELECT * FROM private.issue_paper_ballot(p_member_id, p_admin_id); $$;


ALTER FUNCTION public.issue_paper_ballot(p_member_id uuid, p_admin_id uuid) OWNER TO postgres;

--
-- Name: issue_preprinted_paper_ballot(text, uuid, uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.issue_preprinted_paper_ballot(p_ballot_id text, p_member_id uuid, p_admin_id uuid DEFAULT NULL::uuid) RETURNS TABLE(success boolean, message text, ballot_id text, short_code text, qr_svg text)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $$ SELECT * FROM private.issue_preprinted_paper_ballot(p_ballot_id, p_member_id, p_admin_id); $$;


ALTER FUNCTION public.issue_preprinted_paper_ballot(p_ballot_id text, p_member_id uuid, p_admin_id uuid) OWNER TO postgres;

--
-- Name: paper_pool_reconciliation(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.paper_pool_reconciliation() RETURNS TABLE(checked_in_count bigint, spoiled_check_in_count bigint, available_blank_count bigint, cast_blank_count bigint, voided_blank_count bigint, paper_ballot_count bigint)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $$ SELECT * FROM private.paper_pool_reconciliation(); $$;


ALTER FUNCTION public.paper_pool_reconciliation() OWNER TO postgres;

--
-- Name: provision_voting_entitlements(uuid[], uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.provision_voting_entitlements(p_member_ids uuid[] DEFAULT NULL::uuid[], p_admin_id uuid DEFAULT NULL::uuid) RETURNS TABLE(requested_count integer, created_count integer, existing_count integer, ineligible_count integer, consumed_count integer, integrity_failed_count integer)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $$
  SELECT * FROM private.provision_voting_entitlements(p_member_ids, p_admin_id);
$$;


ALTER FUNCTION public.provision_voting_entitlements(p_member_ids uuid[], p_admin_id uuid) OWNER TO postgres;

--
-- Name: purge_roster_pii(uuid, text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.purge_roster_pii(p_admin_id uuid, p_stage text, p_confirm text) RETURNS TABLE(success boolean, stage text, members_touched integer, message text)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $_$
  SELECT * FROM private.purge_roster_pii($1,$2,$3);
$_$;


ALTER FUNCTION public.purge_roster_pii(p_admin_id uuid, p_stage text, p_confirm text) OWNER TO postgres;

--
-- Name: redeem_voting_token(character varying); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.redeem_voting_token(p_token_hash character varying) RETURNS TABLE(o_success boolean, o_message text, o_credential text, o_ttl_seconds integer)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $$ SELECT * FROM private.redeem_voting_token(p_token_hash); $$;


ALTER FUNCTION public.redeem_voting_token(p_token_hash character varying) OWNER TO postgres;

--
-- Name: reissue_token(uuid, uuid, text, character varying); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.reissue_token(p_old_token_id uuid, p_admin_id uuid, p_reason text, p_new_token_hash character varying) RETURNS TABLE(success boolean, message text)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $$
  SELECT * FROM private.reissue_token(p_old_token_id, p_admin_id, p_reason, p_new_token_hash);
$$;


ALTER FUNCTION public.reissue_token(p_old_token_id uuid, p_admin_id uuid, p_reason text, p_new_token_hash character varying) OWNER TO postgres;

--
-- Name: release_digital_voting_reservation(character varying); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.release_digital_voting_reservation(p_token_hash character varying) RETURNS TABLE(o_success boolean, o_message text)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $$ SELECT * FROM private.release_digital_voting_reservation(p_token_hash); $$;


ALTER FUNCTION public.release_digital_voting_reservation(p_token_hash character varying) OWNER TO postgres;

--
-- Name: rls_auto_enable(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.rls_auto_enable() RETURNS event_trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog'
    AS $$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$$;


ALTER FUNCTION public.rls_auto_enable() OWNER TO postgres;

--
-- Name: search_members_for_nomination(character varying, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.search_members_for_nomination(p_token_hash character varying, p_query text) RETURNS TABLE(member_id uuid, full_name text)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $$
  SELECT * FROM private.search_members_for_nomination(p_token_hash, p_query);
$$;


ALTER FUNCTION public.search_members_for_nomination(p_token_hash character varying, p_query text) OWNER TO postgres;

--
-- Name: set_member_active(uuid, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.set_member_active(p_member_id uuid, p_active boolean) RETURNS public.members
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $$
  SELECT * FROM private.set_member_active(p_member_id, p_active);
$$;


ALTER FUNCTION public.set_member_active(p_member_id uuid, p_active boolean) OWNER TO postgres;

--
-- Name: spoil_paper_ballot(text, text, uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.spoil_paper_ballot(p_ballot_id text, p_reason text, p_admin_id uuid DEFAULT NULL::uuid) RETURNS TABLE(success boolean, message text)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $$ SELECT * FROM private.spoil_paper_ballot(p_ballot_id, p_reason, p_admin_id); $$;


ALTER FUNCTION public.spoil_paper_ballot(p_ballot_id text, p_reason text, p_admin_id uuid) OWNER TO postgres;

--
-- Name: spoil_paper_check_in(text, text, uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.spoil_paper_check_in(p_short_code text, p_reason text DEFAULT 'Spoiled before record'::text, p_admin_id uuid DEFAULT NULL::uuid) RETURNS TABLE(success boolean, message text)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $$ SELECT * FROM private.spoil_paper_check_in(p_short_code, p_reason, p_admin_id); $$;


ALTER FUNCTION public.spoil_paper_check_in(p_short_code text, p_reason text, p_admin_id uuid) OWNER TO postgres;

--
-- Name: submit_anonymous_vote(character varying, uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.submit_anonymous_vote(p_token_hash character varying, p_candidate_id uuid) RETURNS TABLE(success boolean, message text, receipt_code text, ballot_id text)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $$
  SELECT * FROM private.submit_anonymous_vote(p_token_hash, p_candidate_id);
$$;


ALTER FUNCTION public.submit_anonymous_vote(p_token_hash character varying, p_candidate_id uuid) OWNER TO postgres;

--
-- Name: submit_nomination(character varying, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.submit_nomination(p_token_hash character varying, p_nominees jsonb) RETURNS TABLE(success boolean, message text, inserted_count integer)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $$
  SELECT * FROM private.submit_nomination(p_token_hash, p_nominees);
$$;


ALTER FUNCTION public.submit_nomination(p_token_hash character varying, p_nominees jsonb) OWNER TO postgres;

--
-- Name: submit_paper_invalid(text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.submit_paper_invalid(p_ballot_id text, p_reason text) RETURNS TABLE(success boolean, message text)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $$ SELECT * FROM private.submit_paper_invalid(p_ballot_id, p_reason); $$;


ALTER FUNCTION public.submit_paper_invalid(p_ballot_id text, p_reason text) OWNER TO postgres;

--
-- Name: submit_paper_vote(text, uuid, uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.submit_paper_vote(p_ballot_id text, p_candidate_id uuid, p_admin_id uuid DEFAULT NULL::uuid) RETURNS TABLE(success boolean, message text, receipt_code text)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $$ SELECT * FROM private.submit_paper_vote(p_ballot_id, p_candidate_id, p_admin_id); $$;


ALTER FUNCTION public.submit_paper_vote(p_ballot_id text, p_candidate_id uuid, p_admin_id uuid) OWNER TO postgres;

--
-- Name: update_election_settings_updated_at(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_election_settings_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_election_settings_updated_at() OWNER TO postgres;

--
-- Name: validate_phase_transition(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.validate_phase_transition() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  -- Prevent transition from COMPLETED (except admin reset to SETUP)
  IF OLD.current_phase = 'COMPLETED' AND NEW.current_phase != 'COMPLETED' AND NEW.current_phase != 'SETUP' THEN
    RAISE EXCEPTION 'Cannot transition from COMPLETED';
  END IF;
  -- Prevent reopening voting after close
  IF OLD.current_phase = 'VOTING_CLOSED' AND NEW.current_phase = 'VOTING' THEN
    RAISE EXCEPTION 'Cannot reopen voting after VOTING_CLOSED';
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION public.validate_phase_transition() OWNER TO postgres;

--
-- Name: void_anonymous_paper_blank(text, text, uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.void_anonymous_paper_blank(p_ballot_id text, p_reason text DEFAULT 'Voided anonymous blank'::text, p_admin_id uuid DEFAULT NULL::uuid) RETURNS TABLE(success boolean, message text)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $$ SELECT * FROM private.void_anonymous_paper_blank(p_ballot_id, p_reason, p_admin_id); $$;


ALTER FUNCTION public.void_anonymous_paper_blank(p_ballot_id text, p_reason text, p_admin_id uuid) OWNER TO postgres;

--
-- Name: void_unused_anonymous_paper_blanks(uuid, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.void_unused_anonymous_paper_blanks(p_admin_id uuid DEFAULT NULL::uuid, p_reason text DEFAULT 'Election closed - voiding unused anonymous paper blanks'::text) RETURNS TABLE(voided_count integer, message text)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $$ SELECT * FROM private.void_unused_anonymous_paper_blanks(p_admin_id, p_reason); $$;


ALTER FUNCTION public.void_unused_anonymous_paper_blanks(p_admin_id uuid, p_reason text) OWNER TO postgres;

--
-- Name: void_unused_paper_ballots(uuid, text, uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.void_unused_paper_ballots(p_batch_id uuid DEFAULT NULL::uuid, p_reason text DEFAULT 'Election closed - voiding unused anonymous paper blanks'::text, p_admin_id uuid DEFAULT NULL::uuid) RETURNS TABLE(voided_count integer, message text)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $$ SELECT * FROM private.void_unused_paper_ballots(p_batch_id, p_reason, p_admin_id); $$;


ALTER FUNCTION public.void_unused_paper_ballots(p_batch_id uuid, p_reason text, p_admin_id uuid) OWNER TO postgres;

--
-- Name: wipe_election_data(uuid, character varying); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.wipe_election_data(p_admin_id uuid, p_token_hash character varying) RETURNS TABLE(success boolean, message text)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'private'
    AS $$
  SELECT * FROM private.wipe_election_data(p_admin_id, p_token_hash);
$$;


ALTER FUNCTION public.wipe_election_data(p_admin_id uuid, p_token_hash character varying) OWNER TO postgres;

--
-- Name: processing_activity_ledger; Type: TABLE; Schema: governance; Owner: postgres
--

CREATE TABLE governance.processing_activity_ledger (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    event_type text NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    actor_admin_id uuid,
    actor_label text,
    controller_name text,
    organization_ref text,
    processing_purpose text,
    lawful_basis text,
    data_categories text[],
    data_subject_categories text[],
    retention_policy text,
    event_summary jsonb DEFAULT '{}'::jsonb NOT NULL,
    previous_hash character(64),
    record_hash character(64) NOT NULL,
    CONSTRAINT governance_no_voter_linkage CHECK (((event_summary)::text !~* '(member_id|memberId|ballot_id|ballotId|token|email|phone|full_name|member_code)'::text)),
    CONSTRAINT processing_activity_ledger_event_type_check CHECK ((event_type = ANY (ARRAY['ROPA_DECLARED'::text, 'ELIGIBILITY_POLICY_CONFIGURED'::text, 'ROSTER_IMPORTED_SUMMARY'::text, 'ELIGIBILITY_ADJUDICATION_SUMMARY'::text, 'TOKENS_DISPATCHED_SUMMARY'::text, 'CONTACT_PII_PURGED'::text, 'IDENTITY_PII_ANONYMIZED'::text, 'AGGREGATE_RESULTS_EXPORTED'::text, 'WIPE_STARTED'::text, 'WIPE_COMPLETED'::text, 'RAW_RETENTION_OUT_OF_BAND_DECLARED'::text])))
);


ALTER TABLE governance.processing_activity_ledger OWNER TO postgres;

--
-- Name: admin_sessions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.admin_sessions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    token_hash character(64),
    expires_at timestamp with time zone NOT NULL,
    user_agent text,
    ip_address inet,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    revoked_at timestamp with time zone,
    revoke_reason text,
    scope text DEFAULT 'desktop'::text NOT NULL,
    CONSTRAINT admin_sessions_scope_chk CHECK ((scope = ANY (ARRAY['desktop'::text, 'mobile'::text])))
);


ALTER TABLE public.admin_sessions OWNER TO postgres;

--
-- Name: anonymous_digital_credentials; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.anonymous_digital_credentials (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    credential_hash text NOT NULL,
    status character varying(10) DEFAULT 'RESERVED'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    cast_at timestamp with time zone,
    CONSTRAINT anonymous_digital_credentials_status_check CHECK (((status)::text = ANY ((ARRAY['RESERVED'::character varying, 'CAST'::character varying])::text[])))
);


ALTER TABLE public.anonymous_digital_credentials OWNER TO postgres;

--
-- Name: TABLE anonymous_digital_credentials; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.anonymous_digital_credentials IS 'Anon-plane digital voting credentials: SHA-256 hash + RESERVED/CAST status only. No identity handle.';


--
-- Name: anonymous_nominations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.anonymous_nominations (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    nominee_name character varying(100) NOT NULL,
    reason text,
    submitted_date date DEFAULT CURRENT_DATE,
    nominee_member_id uuid,
    source text DEFAULT 'DIGITAL'::text NOT NULL,
    CONSTRAINT anonymous_nominations_source_check CHECK ((source = ANY (ARRAY['DIGITAL'::text, 'ADMIN'::text])))
);


ALTER TABLE public.anonymous_nominations OWNER TO postgres;

--
-- Name: anonymous_paper_blanks; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.anonymous_paper_blanks (
    ballot_id text NOT NULL,
    status text DEFAULT 'AVAILABLE'::text NOT NULL,
    generated_at timestamp with time zone DEFAULT now() NOT NULL,
    generated_date date DEFAULT CURRENT_DATE NOT NULL,
    cast_at timestamp with time zone,
    voided_at timestamp with time zone,
    void_reason text,
    CONSTRAINT anonymous_paper_blanks_status_check CHECK ((status = ANY (ARRAY['AVAILABLE'::text, 'CAST'::text, 'VOIDED'::text])))
);


ALTER TABLE public.anonymous_paper_blanks OWNER TO postgres;

--
-- Name: ballot_audit_log; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.ballot_audit_log (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    action text NOT NULL,
    ballot_id text,
    channel character varying(10) NOT NULL,
    event_date date DEFAULT CURRENT_DATE NOT NULL,
    old_candidate_id uuid,
    new_candidate_id uuid,
    admin_id uuid,
    source_vote_audit_log_id uuid,
    details jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ballot_audit_log_channel_check CHECK (((channel)::text = ANY ((ARRAY['DIGITAL'::character varying, 'PAPER'::character varying])::text[]))),
    CONSTRAINT ballot_audit_log_no_identity_handles_chk CHECK (((NOT (COALESCE(details, '{}'::jsonb) ? 'member_id'::text)) AND (NOT (COALESCE(details, '{}'::jsonb) ? 'token_id'::text)) AND (NOT (COALESCE(details, '{}'::jsonb) ? 'short_code'::text)) AND (NOT (COALESCE(details, '{}'::jsonb) ? 'batch_id'::text)) AND (NOT (COALESCE(details, '{}'::jsonb) ? 'credential_hash'::text)) AND (NOT (COALESCE(details, '{}'::jsonb) ? 'reservation_id'::text))))
);


ALTER TABLE public.ballot_audit_log OWNER TO postgres;

--
-- Name: ballots; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.ballots (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    candidate_id uuid NOT NULL,
    receipt_code character varying(32) NOT NULL,
    channel character varying(10) DEFAULT 'DIGITAL'::character varying NOT NULL,
    cast_date date DEFAULT CURRENT_DATE,
    ballot_id text
);


ALTER TABLE public.ballots OWNER TO postgres;

--
-- Name: candidates; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.candidates (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    full_name character varying(100) NOT NULL,
    statement text,
    photo_url text,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.candidates OWNER TO postgres;

--
-- Name: digital_credential_reservations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.digital_credential_reservations (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    credential_hash text NOT NULL,
    token_id uuid NOT NULL,
    reserved_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL
);


ALTER TABLE public.digital_credential_reservations OWNER TO postgres;

--
-- Name: TABLE digital_credential_reservations; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.digital_credential_reservations IS 'TRANSIENT identity<->credential bridge (credential_hash -> token_id). Short TTL, hard-deleted on cast, swept on expiry. RATIFIED exception to no-durable-co-occurrence. service_role-only.';


--
-- Name: election_settings; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.election_settings (
    id integer DEFAULT 1 NOT NULL,
    current_phase public.election_phase DEFAULT 'SETUP'::public.election_phase NOT NULL,
    nomination_start timestamp with time zone,
    nomination_end timestamp with time zone,
    voting_start timestamp with time zone,
    voting_end timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    voting_token_ttl_hours integer DEFAULT 168 NOT NULL,
    allow_write_ins boolean DEFAULT true NOT NULL,
    max_nominees_per_member smallint DEFAULT 1 NOT NULL,
    age_requirement_enabled boolean DEFAULT false NOT NULL,
    minimum_voting_age smallint,
    undetermined_eligibility_defaults_ineligible boolean DEFAULT true NOT NULL,
    paper_ballot_layout text DEFAULT 'SEPARATE_SLIP'::text NOT NULL,
    digital_write_mode character varying(16) DEFAULT 'LEGACY'::character varying NOT NULL,
    digital_credential_ttl_minutes integer DEFAULT 15 NOT NULL,
    allow_adding_member_during_voting boolean DEFAULT false NOT NULL,
    CONSTRAINT election_settings_age_requirement_config_check CHECK (((age_requirement_enabled = false) OR (minimum_voting_age IS NOT NULL))),
    CONSTRAINT election_settings_digital_ttl_positive_chk CHECK (((digital_credential_ttl_minutes > 0) AND (digital_credential_ttl_minutes <= 1440))),
    CONSTRAINT election_settings_digital_write_mode_chk CHECK (((digital_write_mode)::text = ANY ((ARRAY['LEGACY'::character varying, 'TWO_PHASE'::character varying])::text[]))),
    CONSTRAINT election_settings_id_check CHECK ((id = 1)),
    CONSTRAINT election_settings_max_nominees_per_member_check CHECK (((max_nominees_per_member >= 1) AND (max_nominees_per_member <= 3))),
    CONSTRAINT election_settings_minimum_voting_age_check CHECK (((minimum_voting_age IS NULL) OR ((minimum_voting_age >= 0) AND (minimum_voting_age <= 130)))),
    CONSTRAINT election_settings_paper_ballot_layout_chk CHECK ((paper_ballot_layout = ANY (ARRAY['SEPARATE_SLIP'::text, 'SINGLE_SHEET'::text]))),
    CONSTRAINT election_settings_voting_token_ttl_hours_check CHECK (((voting_token_ttl_hours >= 1) AND (voting_token_ttl_hours <= 2160)))
);


ALTER TABLE public.election_settings OWNER TO postgres;

--
-- Name: eligibility_adjudications; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.eligibility_adjudications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    member_id uuid NOT NULL,
    admin_id uuid,
    old_voting_eligible boolean NOT NULL,
    old_eligibility_reason text NOT NULL,
    old_eligibility_source text NOT NULL,
    old_is_age_eligible boolean,
    new_voting_eligible boolean NOT NULL,
    new_eligibility_reason text NOT NULL,
    new_eligibility_source text NOT NULL,
    new_is_age_eligible boolean,
    note text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.eligibility_adjudications OWNER TO postgres;

--
-- Name: nomination_adjudications; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.nomination_adjudications (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    admin_id uuid,
    decision text NOT NULL,
    candidate_id uuid,
    nominee_member_id uuid,
    affected_nomination_ids uuid[] DEFAULT '{}'::uuid[] NOT NULL,
    note text,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT nomination_adjudications_decision_check CHECK ((decision = ANY (ARRAY['PROMOTE'::text, 'MERGE'::text, 'DISCARD'::text])))
);


ALTER TABLE public.nomination_adjudications OWNER TO postgres;

--
-- Name: COLUMN nomination_adjudications.admin_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.nomination_adjudications.admin_id IS 'Admin session id -> admin_sessions(id) (NOT members). See migration_fix_admin_id_fk.sql.';


--
-- Name: paper_ballot_batches; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.paper_ballot_batches (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    generated_count integer NOT NULL,
    generated_by uuid,
    generated_at timestamp with time zone DEFAULT now() NOT NULL,
    voided_at timestamp with time zone,
    notes text
);


ALTER TABLE public.paper_ballot_batches OWNER TO postgres;

--
-- Name: COLUMN paper_ballot_batches.generated_by; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.paper_ballot_batches.generated_by IS 'Admin session id -> admin_sessions(id) (NOT members). Unwritten until attribution writes are re-enabled. See migration_repoint_paper_actor_fks.sql.';


--
-- Name: paper_ballots; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.paper_ballots (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    short_code character varying(14) NOT NULL,
    member_id uuid,
    token_id uuid,
    status public.paper_ballot_status DEFAULT 'AVAILABLE'::public.paper_ballot_status NOT NULL,
    checked_in_at timestamp with time zone,
    checked_in_date date,
    checked_in_by uuid,
    spoiled_at timestamp with time zone,
    spoiled_by uuid,
    voided_at timestamp with time zone,
    voided_by uuid,
    invalid_reason text,
    void_reason text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.paper_ballots OWNER TO postgres;

--
-- Name: participation_audit; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.participation_audit (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    action text NOT NULL,
    member_id uuid NOT NULL,
    token_id uuid,
    channel character varying(10) NOT NULL,
    event_date date DEFAULT CURRENT_DATE NOT NULL,
    admin_id uuid,
    source_vote_audit_log_id uuid,
    details jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT participation_audit_channel_check CHECK (((channel)::text = ANY ((ARRAY['DIGITAL'::character varying, 'PAPER'::character varying])::text[]))),
    CONSTRAINT participation_audit_no_vote_handles_chk CHECK (((NOT (COALESCE(details, '{}'::jsonb) ? 'ballot_id'::text)) AND (NOT (COALESCE(details, '{}'::jsonb) ? 'candidate_id'::text)) AND (NOT (COALESCE(details, '{}'::jsonb) ? 'receipt_code'::text)) AND (NOT (COALESCE(details, '{}'::jsonb) ? 'short_code'::text)) AND (NOT (COALESCE(details, '{}'::jsonb) ? 'batch_id'::text)) AND (NOT (COALESCE(details, '{}'::jsonb) ? 'credential'::text)) AND (NOT (COALESCE(details, '{}'::jsonb) ? 'credential_hash'::text)) AND (NOT (COALESCE(details, '{}'::jsonb) ? 'reservation_id'::text))))
);


ALTER TABLE public.participation_audit OWNER TO postgres;

--
-- Name: phase_change_tokens; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.phase_change_tokens (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    token_hash character varying(64) NOT NULL,
    from_phase public.election_phase NOT NULL,
    to_phase public.election_phase NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    used boolean DEFAULT false,
    used_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    admin_session_id uuid
);


ALTER TABLE public.phase_change_tokens OWNER TO postgres;

--
-- Name: rate_limit_hits; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.rate_limit_hits (
    id bigint NOT NULL,
    identifier text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.rate_limit_hits OWNER TO postgres;

--
-- Name: rate_limit_hits_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.rate_limit_hits_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.rate_limit_hits_id_seq OWNER TO postgres;

--
-- Name: rate_limit_hits_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.rate_limit_hits_id_seq OWNED BY public.rate_limit_hits.id;


--
-- Name: tokens; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.tokens (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    member_id uuid NOT NULL,
    token_hash character varying(64) NOT NULL,
    type public.token_type NOT NULL,
    is_used boolean DEFAULT false,
    used_at timestamp with time zone,
    channel_sent character varying(20) DEFAULT 'EMAIL'::character varying,
    created_at timestamp with time zone DEFAULT now(),
    expires_at timestamp with time zone,
    voided_at timestamp with time zone,
    void_reason text,
    reissued_from_token_id uuid,
    reserved_at timestamp with time zone,
    reservation_released_at timestamp with time zone,
    reserved_channel character varying(20)
);


ALTER TABLE public.tokens OWNER TO postgres;

--
-- Name: vote_audit_log; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.vote_audit_log (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    action character varying(50) NOT NULL,
    member_id uuid,
    ballot_id text,
    candidate_id uuid,
    admin_id uuid,
    details jsonb,
    created_at timestamp with time zone DEFAULT now(),
    record_hash character(64),
    previous_hash character(64),
    CONSTRAINT vote_audit_log_wave6_no_colocation_chk CHECK (((member_id IS NULL) OR ((ballot_id IS NULL) AND (candidate_id IS NULL) AND (NOT (COALESCE(details, '{}'::jsonb) ? 'ballot_id'::text)) AND (NOT (COALESCE(details, '{}'::jsonb) ? 'candidate_id'::text)) AND (NOT (COALESCE(details, '{}'::jsonb) ? 'receipt_code'::text)) AND (NOT (COALESCE(details, '{}'::jsonb) ? 'short_code'::text)) AND (NOT (COALESCE(details, '{}'::jsonb) ? 'batch_id'::text)) AND (NOT (COALESCE(details, '{}'::jsonb) ? 'credential'::text)) AND (NOT (COALESCE(details, '{}'::jsonb) ? 'credential_hash'::text)) AND (NOT (COALESCE(details, '{}'::jsonb) ? 'reservation_id'::text)))))
);


ALTER TABLE public.vote_audit_log OWNER TO postgres;

--
-- Name: COLUMN vote_audit_log.admin_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.vote_audit_log.admin_id IS 'Admin session id -> admin_sessions(id) (NOT members). See migration_fix_admin_id_fk.sql.';


--
-- Name: wipe_confirmation_tokens; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.wipe_confirmation_tokens (
    admin_session_id uuid NOT NULL,
    token_hash character varying(64) NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    confirmed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.wipe_confirmation_tokens OWNER TO postgres;

--
-- Name: rate_limit_hits id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.rate_limit_hits ALTER COLUMN id SET DEFAULT nextval('public.rate_limit_hits_id_seq'::regclass);


--
-- Name: processing_activity_ledger processing_activity_ledger_pkey; Type: CONSTRAINT; Schema: governance; Owner: postgres
--

ALTER TABLE ONLY governance.processing_activity_ledger
    ADD CONSTRAINT processing_activity_ledger_pkey PRIMARY KEY (id);


--
-- Name: admin_sessions admin_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.admin_sessions
    ADD CONSTRAINT admin_sessions_pkey PRIMARY KEY (id);


--
-- Name: admin_sessions admin_sessions_token_hash_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.admin_sessions
    ADD CONSTRAINT admin_sessions_token_hash_key UNIQUE (token_hash);


--
-- Name: anonymous_digital_credentials anonymous_digital_credentials_credential_hash_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.anonymous_digital_credentials
    ADD CONSTRAINT anonymous_digital_credentials_credential_hash_key UNIQUE (credential_hash);


--
-- Name: anonymous_digital_credentials anonymous_digital_credentials_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.anonymous_digital_credentials
    ADD CONSTRAINT anonymous_digital_credentials_pkey PRIMARY KEY (id);


--
-- Name: anonymous_nominations anonymous_nominations_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.anonymous_nominations
    ADD CONSTRAINT anonymous_nominations_pkey PRIMARY KEY (id);


--
-- Name: anonymous_paper_blanks anonymous_paper_blanks_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.anonymous_paper_blanks
    ADD CONSTRAINT anonymous_paper_blanks_pkey PRIMARY KEY (ballot_id);


--
-- Name: ballot_audit_log ballot_audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ballot_audit_log
    ADD CONSTRAINT ballot_audit_log_pkey PRIMARY KEY (id);


--
-- Name: ballot_audit_log ballot_audit_log_source_vote_audit_log_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ballot_audit_log
    ADD CONSTRAINT ballot_audit_log_source_vote_audit_log_id_key UNIQUE (source_vote_audit_log_id);


--
-- Name: ballots ballots_ballot_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ballots
    ADD CONSTRAINT ballots_ballot_id_key UNIQUE (ballot_id);


--
-- Name: ballots ballots_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ballots
    ADD CONSTRAINT ballots_pkey PRIMARY KEY (id);


--
-- Name: ballots ballots_receipt_code_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ballots
    ADD CONSTRAINT ballots_receipt_code_key UNIQUE (receipt_code);


--
-- Name: candidates candidates_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.candidates
    ADD CONSTRAINT candidates_pkey PRIMARY KEY (id);


--
-- Name: digital_credential_reservations digital_credential_reservations_credential_hash_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.digital_credential_reservations
    ADD CONSTRAINT digital_credential_reservations_credential_hash_key UNIQUE (credential_hash);


--
-- Name: digital_credential_reservations digital_credential_reservations_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.digital_credential_reservations
    ADD CONSTRAINT digital_credential_reservations_pkey PRIMARY KEY (id);


--
-- Name: digital_credential_reservations digital_credential_reservations_token_uniq; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.digital_credential_reservations
    ADD CONSTRAINT digital_credential_reservations_token_uniq UNIQUE (token_id);


--
-- Name: election_settings election_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.election_settings
    ADD CONSTRAINT election_settings_pkey PRIMARY KEY (id);


--
-- Name: eligibility_adjudications eligibility_adjudications_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.eligibility_adjudications
    ADD CONSTRAINT eligibility_adjudications_pkey PRIMARY KEY (id);


--
-- Name: members members_email_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.members
    ADD CONSTRAINT members_email_key UNIQUE (email);


--
-- Name: members members_member_code_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.members
    ADD CONSTRAINT members_member_code_key UNIQUE (member_code);


--
-- Name: members members_phone_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.members
    ADD CONSTRAINT members_phone_key UNIQUE (phone);


--
-- Name: members members_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.members
    ADD CONSTRAINT members_pkey PRIMARY KEY (id);


--
-- Name: nomination_adjudications nomination_adjudications_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.nomination_adjudications
    ADD CONSTRAINT nomination_adjudications_pkey PRIMARY KEY (id);


--
-- Name: paper_ballot_batches paper_ballot_batches_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.paper_ballot_batches
    ADD CONSTRAINT paper_ballot_batches_pkey PRIMARY KEY (id);


--
-- Name: paper_ballots paper_ballots_pkey1; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.paper_ballots
    ADD CONSTRAINT paper_ballots_pkey1 PRIMARY KEY (id);


--
-- Name: paper_ballots paper_ballots_short_code_key1; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.paper_ballots
    ADD CONSTRAINT paper_ballots_short_code_key1 UNIQUE (short_code);


--
-- Name: participation_audit participation_audit_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.participation_audit
    ADD CONSTRAINT participation_audit_pkey PRIMARY KEY (id);


--
-- Name: participation_audit participation_audit_source_vote_audit_log_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.participation_audit
    ADD CONSTRAINT participation_audit_source_vote_audit_log_id_key UNIQUE (source_vote_audit_log_id);


--
-- Name: phase_change_tokens phase_change_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.phase_change_tokens
    ADD CONSTRAINT phase_change_tokens_pkey PRIMARY KEY (id);


--
-- Name: phase_change_tokens phase_change_tokens_token_hash_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.phase_change_tokens
    ADD CONSTRAINT phase_change_tokens_token_hash_key UNIQUE (token_hash);


--
-- Name: rate_limit_hits rate_limit_hits_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.rate_limit_hits
    ADD CONSTRAINT rate_limit_hits_pkey PRIMARY KEY (id);


--
-- Name: tokens tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.tokens
    ADD CONSTRAINT tokens_pkey PRIMARY KEY (id);


--
-- Name: tokens tokens_token_hash_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.tokens
    ADD CONSTRAINT tokens_token_hash_key UNIQUE (token_hash);


--
-- Name: vote_audit_log vote_audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.vote_audit_log
    ADD CONSTRAINT vote_audit_log_pkey PRIMARY KEY (id);


--
-- Name: wipe_confirmation_tokens wipe_confirmation_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.wipe_confirmation_tokens
    ADD CONSTRAINT wipe_confirmation_tokens_pkey PRIMARY KEY (admin_session_id);


--
-- Name: wipe_confirmation_tokens wipe_confirmation_tokens_token_hash_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.wipe_confirmation_tokens
    ADD CONSTRAINT wipe_confirmation_tokens_token_hash_key UNIQUE (token_hash);


--
-- Name: idx_adjudication_one_promote_per_nominee; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX idx_adjudication_one_promote_per_nominee ON public.nomination_adjudications USING btree (nominee_member_id) WHERE ((decision = 'PROMOTE'::text) AND (nominee_member_id IS NOT NULL));


--
-- Name: idx_admin_sessions_expires_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_admin_sessions_expires_at ON public.admin_sessions USING btree (expires_at);


--
-- Name: idx_admin_sessions_revoked_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_admin_sessions_revoked_at ON public.admin_sessions USING btree (revoked_at);


--
-- Name: idx_anon_digital_credentials_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_anon_digital_credentials_status ON public.anonymous_digital_credentials USING btree (status);


--
-- Name: idx_anonymous_paper_blanks_generated_date; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_anonymous_paper_blanks_generated_date ON public.anonymous_paper_blanks USING btree (generated_date);


--
-- Name: idx_anonymous_paper_blanks_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_anonymous_paper_blanks_status ON public.anonymous_paper_blanks USING btree (status);


--
-- Name: idx_ballot_audit_log_ballot; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_ballot_audit_log_ballot ON public.ballot_audit_log USING btree (ballot_id);


--
-- Name: idx_ballot_audit_log_event_date; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_ballot_audit_log_event_date ON public.ballot_audit_log USING btree (event_date);


--
-- Name: idx_ballots_ballot_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_ballots_ballot_id ON public.ballots USING btree (ballot_id);


--
-- Name: idx_ballots_receipt; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_ballots_receipt ON public.ballots USING btree (receipt_code);


--
-- Name: idx_digital_cred_reservations_expires; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_digital_cred_reservations_expires ON public.digital_credential_reservations USING btree (expires_at);


--
-- Name: idx_members_full_name_trgm; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_members_full_name_trgm ON public.members USING gin (full_name public.gin_trgm_ops);


--
-- Name: idx_members_voting_eligible; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_members_voting_eligible ON public.members USING btree (voting_eligible);


--
-- Name: idx_paper_ballots_one_checked_in_member; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX idx_paper_ballots_one_checked_in_member ON public.paper_ballots USING btree (member_id) WHERE ((member_id IS NOT NULL) AND (status = ANY (ARRAY['ISSUED_TO_VOTER'::public.paper_ballot_status, 'VOTED'::public.paper_ballot_status])));


--
-- Name: idx_paper_ballots_one_checked_in_token; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX idx_paper_ballots_one_checked_in_token ON public.paper_ballots USING btree (token_id) WHERE ((token_id IS NOT NULL) AND (status = ANY (ARRAY['ISSUED_TO_VOTER'::public.paper_ballot_status, 'VOTED'::public.paper_ballot_status])));


--
-- Name: idx_paper_ballots_token; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_paper_ballots_token ON public.paper_ballots USING btree (token_id);


--
-- Name: idx_participation_audit_channel_date; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_participation_audit_channel_date ON public.participation_audit USING btree (channel, event_date);


--
-- Name: idx_participation_audit_member_date; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_participation_audit_member_date ON public.participation_audit USING btree (member_id, event_date);


--
-- Name: idx_phase_change_tokens_admin_session; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_phase_change_tokens_admin_session ON public.phase_change_tokens USING btree (admin_session_id);


--
-- Name: idx_phase_change_tokens_expires; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_phase_change_tokens_expires ON public.phase_change_tokens USING btree (expires_at);


--
-- Name: idx_phase_change_tokens_hash; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_phase_change_tokens_hash ON public.phase_change_tokens USING btree (token_hash);


--
-- Name: idx_rate_limit_hits_created_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_rate_limit_hits_created_at ON public.rate_limit_hits USING btree (created_at);


--
-- Name: idx_rate_limit_hits_identifier_created; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_rate_limit_hits_identifier_created ON public.rate_limit_hits USING btree (identifier, created_at);


--
-- Name: idx_tokens_expires_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_tokens_expires_at ON public.tokens USING btree (expires_at) WHERE (expires_at IS NOT NULL);


--
-- Name: idx_tokens_hash; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_tokens_hash ON public.tokens USING btree (token_hash);


--
-- Name: idx_tokens_wave6_reserved_channel; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_tokens_wave6_reserved_channel ON public.tokens USING btree (reserved_channel, reserved_at) WHERE (reserved_at IS NOT NULL);


--
-- Name: idx_vote_audit_log_ballot; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_vote_audit_log_ballot ON public.vote_audit_log USING btree (ballot_id);


--
-- Name: idx_vote_audit_log_created; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_vote_audit_log_created ON public.vote_audit_log USING btree (created_at);


--
-- Name: idx_vote_audit_log_hash_chain; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_vote_audit_log_hash_chain ON public.vote_audit_log USING btree (record_hash, previous_hash);


--
-- Name: idx_vote_audit_log_member; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_vote_audit_log_member ON public.vote_audit_log USING btree (member_id);


--
-- Name: tokens_one_live_per_member_type; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX tokens_one_live_per_member_type ON public.tokens USING btree (member_id, type) WHERE ((is_used = false) AND (voided_at IS NULL));


--
-- Name: processing_activity_ledger trg_governance_no_truncate; Type: TRIGGER; Schema: governance; Owner: postgres
--

CREATE TRIGGER trg_governance_no_truncate BEFORE TRUNCATE ON governance.processing_activity_ledger FOR EACH STATEMENT EXECUTE FUNCTION governance.reject_truncate();


--
-- Name: processing_activity_ledger trg_governance_no_update; Type: TRIGGER; Schema: governance; Owner: postgres
--

CREATE TRIGGER trg_governance_no_update BEFORE DELETE OR UPDATE ON governance.processing_activity_ledger FOR EACH ROW EXECUTE FUNCTION governance.reject_mutation();


--
-- Name: eligibility_adjudications trg_adjudication_no_update; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_adjudication_no_update BEFORE DELETE OR UPDATE ON public.eligibility_adjudications FOR EACH ROW EXECUTE FUNCTION private.reject_adjudication_mutation();


--
-- Name: anonymous_nominations trg_nominations_immutable; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_nominations_immutable BEFORE DELETE OR UPDATE ON public.anonymous_nominations FOR EACH ROW EXECUTE FUNCTION private.reject_nomination_mutation();


--
-- Name: election_settings trg_paper_ballot_layout_immutable; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_paper_ballot_layout_immutable BEFORE UPDATE OF paper_ballot_layout, current_phase ON public.election_settings FOR EACH ROW EXECUTE FUNCTION private.enforce_paper_ballot_layout_immutable();


--
-- Name: tokens trg_token_eligibility; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_token_eligibility BEFORE INSERT ON public.tokens FOR EACH ROW EXECUTE FUNCTION private.enforce_token_eligibility();


--
-- Name: vote_audit_log trg_vote_audit_log_immutable; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_vote_audit_log_immutable BEFORE DELETE OR UPDATE ON public.vote_audit_log FOR EACH ROW EXECUTE FUNCTION private.reject_vote_audit_log_mutation();


--
-- Name: vote_audit_log trg_vote_audit_log_no_colocation; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_vote_audit_log_no_colocation BEFORE INSERT OR UPDATE ON public.vote_audit_log FOR EACH ROW EXECUTE FUNCTION private.reject_vote_audit_log_colocation();


--
-- Name: election_settings trigger_update_election_settings_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trigger_update_election_settings_updated_at BEFORE UPDATE ON public.election_settings FOR EACH ROW EXECUTE FUNCTION public.update_election_settings_updated_at();


--
-- Name: election_settings trigger_validate_phase_transition; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trigger_validate_phase_transition BEFORE UPDATE ON public.election_settings FOR EACH ROW EXECUTE FUNCTION public.validate_phase_transition();


--
-- Name: anonymous_nominations anonymous_nominations_nominee_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.anonymous_nominations
    ADD CONSTRAINT anonymous_nominations_nominee_member_id_fkey FOREIGN KEY (nominee_member_id) REFERENCES public.members(id);


--
-- Name: ballot_audit_log ballot_audit_log_admin_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ballot_audit_log
    ADD CONSTRAINT ballot_audit_log_admin_id_fkey FOREIGN KEY (admin_id) REFERENCES public.admin_sessions(id) ON DELETE RESTRICT;


--
-- Name: ballot_audit_log ballot_audit_log_new_candidate_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ballot_audit_log
    ADD CONSTRAINT ballot_audit_log_new_candidate_id_fkey FOREIGN KEY (new_candidate_id) REFERENCES public.candidates(id);


--
-- Name: ballot_audit_log ballot_audit_log_old_candidate_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ballot_audit_log
    ADD CONSTRAINT ballot_audit_log_old_candidate_id_fkey FOREIGN KEY (old_candidate_id) REFERENCES public.candidates(id);


--
-- Name: ballots ballots_candidate_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ballots
    ADD CONSTRAINT ballots_candidate_id_fkey FOREIGN KEY (candidate_id) REFERENCES public.candidates(id);


--
-- Name: digital_credential_reservations digital_credential_reservations_credential_hash_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.digital_credential_reservations
    ADD CONSTRAINT digital_credential_reservations_credential_hash_fkey FOREIGN KEY (credential_hash) REFERENCES public.anonymous_digital_credentials(credential_hash) ON DELETE CASCADE;


--
-- Name: digital_credential_reservations digital_credential_reservations_token_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.digital_credential_reservations
    ADD CONSTRAINT digital_credential_reservations_token_id_fkey FOREIGN KEY (token_id) REFERENCES public.tokens(id) ON DELETE CASCADE;


--
-- Name: eligibility_adjudications eligibility_adjudications_admin_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.eligibility_adjudications
    ADD CONSTRAINT eligibility_adjudications_admin_id_fkey FOREIGN KEY (admin_id) REFERENCES public.admin_sessions(id) ON DELETE RESTRICT;


--
-- Name: eligibility_adjudications eligibility_adjudications_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.eligibility_adjudications
    ADD CONSTRAINT eligibility_adjudications_member_id_fkey FOREIGN KEY (member_id) REFERENCES public.members(id) ON DELETE RESTRICT;


--
-- Name: nomination_adjudications nomination_adjudications_admin_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.nomination_adjudications
    ADD CONSTRAINT nomination_adjudications_admin_id_fkey FOREIGN KEY (admin_id) REFERENCES public.admin_sessions(id) ON DELETE RESTRICT;


--
-- Name: nomination_adjudications nomination_adjudications_candidate_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.nomination_adjudications
    ADD CONSTRAINT nomination_adjudications_candidate_id_fkey FOREIGN KEY (candidate_id) REFERENCES public.candidates(id);


--
-- Name: nomination_adjudications nomination_adjudications_nominee_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.nomination_adjudications
    ADD CONSTRAINT nomination_adjudications_nominee_member_id_fkey FOREIGN KEY (nominee_member_id) REFERENCES public.members(id);


--
-- Name: paper_ballot_batches paper_ballot_batches_generated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.paper_ballot_batches
    ADD CONSTRAINT paper_ballot_batches_generated_by_fkey FOREIGN KEY (generated_by) REFERENCES public.admin_sessions(id) ON DELETE RESTRICT;


--
-- Name: paper_ballots paper_ballots_checked_in_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.paper_ballots
    ADD CONSTRAINT paper_ballots_checked_in_by_fkey FOREIGN KEY (checked_in_by) REFERENCES public.admin_sessions(id) ON DELETE RESTRICT;


--
-- Name: paper_ballots paper_ballots_member_id_fkey1; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.paper_ballots
    ADD CONSTRAINT paper_ballots_member_id_fkey1 FOREIGN KEY (member_id) REFERENCES public.members(id) ON DELETE RESTRICT;


--
-- Name: paper_ballots paper_ballots_spoiled_by_fkey1; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.paper_ballots
    ADD CONSTRAINT paper_ballots_spoiled_by_fkey1 FOREIGN KEY (spoiled_by) REFERENCES public.admin_sessions(id) ON DELETE RESTRICT;


--
-- Name: paper_ballots paper_ballots_token_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.paper_ballots
    ADD CONSTRAINT paper_ballots_token_id_fkey FOREIGN KEY (token_id) REFERENCES public.tokens(id) ON DELETE SET NULL;


--
-- Name: paper_ballots paper_ballots_voided_by_fkey1; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.paper_ballots
    ADD CONSTRAINT paper_ballots_voided_by_fkey1 FOREIGN KEY (voided_by) REFERENCES public.admin_sessions(id) ON DELETE RESTRICT;


--
-- Name: participation_audit participation_audit_admin_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.participation_audit
    ADD CONSTRAINT participation_audit_admin_id_fkey FOREIGN KEY (admin_id) REFERENCES public.admin_sessions(id) ON DELETE RESTRICT;


--
-- Name: participation_audit participation_audit_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.participation_audit
    ADD CONSTRAINT participation_audit_member_id_fkey FOREIGN KEY (member_id) REFERENCES public.members(id) ON DELETE RESTRICT;


--
-- Name: participation_audit participation_audit_token_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.participation_audit
    ADD CONSTRAINT participation_audit_token_id_fkey FOREIGN KEY (token_id) REFERENCES public.tokens(id) ON DELETE SET NULL;


--
-- Name: phase_change_tokens phase_change_tokens_admin_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.phase_change_tokens
    ADD CONSTRAINT phase_change_tokens_admin_session_id_fkey FOREIGN KEY (admin_session_id) REFERENCES public.admin_sessions(id);


--
-- Name: tokens tokens_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.tokens
    ADD CONSTRAINT tokens_member_id_fkey FOREIGN KEY (member_id) REFERENCES public.members(id) ON DELETE CASCADE;


--
-- Name: tokens tokens_reissued_from_token_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.tokens
    ADD CONSTRAINT tokens_reissued_from_token_id_fkey FOREIGN KEY (reissued_from_token_id) REFERENCES public.tokens(id);


--
-- Name: vote_audit_log vote_audit_log_admin_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.vote_audit_log
    ADD CONSTRAINT vote_audit_log_admin_id_fkey FOREIGN KEY (admin_id) REFERENCES public.admin_sessions(id) ON DELETE RESTRICT;


--
-- Name: vote_audit_log vote_audit_log_candidate_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.vote_audit_log
    ADD CONSTRAINT vote_audit_log_candidate_id_fkey FOREIGN KEY (candidate_id) REFERENCES public.candidates(id);


--
-- Name: vote_audit_log vote_audit_log_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.vote_audit_log
    ADD CONSTRAINT vote_audit_log_member_id_fkey FOREIGN KEY (member_id) REFERENCES public.members(id);


--
-- Name: wipe_confirmation_tokens wipe_confirmation_tokens_admin_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.wipe_confirmation_tokens
    ADD CONSTRAINT wipe_confirmation_tokens_admin_session_id_fkey FOREIGN KEY (admin_session_id) REFERENCES public.admin_sessions(id) ON DELETE CASCADE;


--
-- Name: admin_sessions; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.admin_sessions ENABLE ROW LEVEL SECURITY;

--
-- Name: anonymous_digital_credentials; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.anonymous_digital_credentials ENABLE ROW LEVEL SECURITY;

--
-- Name: anonymous_nominations; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.anonymous_nominations ENABLE ROW LEVEL SECURITY;

--
-- Name: anonymous_paper_blanks; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.anonymous_paper_blanks ENABLE ROW LEVEL SECURITY;

--
-- Name: ballot_audit_log; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.ballot_audit_log ENABLE ROW LEVEL SECURITY;

--
-- Name: ballots; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.ballots ENABLE ROW LEVEL SECURITY;

--
-- Name: candidates; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.candidates ENABLE ROW LEVEL SECURITY;

--
-- Name: digital_credential_reservations; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.digital_credential_reservations ENABLE ROW LEVEL SECURITY;

--
-- Name: election_settings; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.election_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: eligibility_adjudications; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.eligibility_adjudications ENABLE ROW LEVEL SECURITY;

--
-- Name: candidates f4_public_reader_active_candidates; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY f4_public_reader_active_candidates ON public.candidates FOR SELECT TO f4_public_reader USING ((is_active = true));


--
-- Name: ballots f4_public_reader_ballots_verify; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY f4_public_reader_ballots_verify ON public.ballots FOR SELECT TO f4_public_reader USING (true);


--
-- Name: election_settings f4_public_reader_settings_id1; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY f4_public_reader_settings_id1 ON public.election_settings FOR SELECT TO f4_public_reader USING ((id = 1));


--
-- Name: members; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.members ENABLE ROW LEVEL SECURITY;

--
-- Name: nomination_adjudications; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.nomination_adjudications ENABLE ROW LEVEL SECURITY;

--
-- Name: paper_ballot_batches; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.paper_ballot_batches ENABLE ROW LEVEL SECURITY;

--
-- Name: paper_ballots; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.paper_ballots ENABLE ROW LEVEL SECURITY;

--
-- Name: participation_audit; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.participation_audit ENABLE ROW LEVEL SECURITY;

--
-- Name: phase_change_tokens; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.phase_change_tokens ENABLE ROW LEVEL SECURITY;

--
-- Name: rate_limit_hits; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.rate_limit_hits ENABLE ROW LEVEL SECURITY;

--
-- Name: tokens; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.tokens ENABLE ROW LEVEL SECURITY;

--
-- Name: vote_audit_log; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.vote_audit_log ENABLE ROW LEVEL SECURITY;

--
-- Name: wipe_confirmation_tokens; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.wipe_confirmation_tokens ENABLE ROW LEVEL SECURITY;

--
-- Name: SCHEMA governance; Type: ACL; Schema: -; Owner: postgres
--

GRANT USAGE ON SCHEMA governance TO service_role;


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: pg_database_owner
--

GRANT USAGE ON SCHEMA public TO postgres;
GRANT USAGE ON SCHEMA public TO anon;
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT USAGE ON SCHEMA public TO service_role;
GRANT USAGE ON SCHEMA public TO f4_public_reader;


--
-- Name: FUNCTION adjudicate_eligibility(p_admin_session_id uuid, p_member_id uuid, p_new_voting_eligible boolean, p_new_eligibility_reason text, p_note text); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.adjudicate_eligibility(p_admin_session_id uuid, p_member_id uuid, p_new_voting_eligible boolean, p_new_eligibility_reason text, p_note text) FROM PUBLIC;


--
-- Name: FUNCTION adjudicate_nomination(p_decision text, p_admin_session_id uuid, p_affected_nomination_ids uuid[], p_nominee_member_id uuid, p_nominee_name text, p_candidate_statement text, p_candidate_id uuid, p_note text); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.adjudicate_nomination(p_decision text, p_admin_session_id uuid, p_affected_nomination_ids uuid[], p_nominee_member_id uuid, p_nominee_name text, p_candidate_statement text, p_candidate_id uuid, p_note text) FROM PUBLIC;
GRANT ALL ON FUNCTION private.adjudicate_nomination(p_decision text, p_admin_session_id uuid, p_affected_nomination_ids uuid[], p_nominee_member_id uuid, p_nominee_name text, p_candidate_statement text, p_candidate_id uuid, p_note text) TO service_role;


--
-- Name: FUNCTION admin_add_nomination(p_nominee_member_id uuid, p_nominee_name text, p_reason text); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.admin_add_nomination(p_nominee_member_id uuid, p_nominee_name text, p_reason text) FROM PUBLIC;
GRANT ALL ON FUNCTION private.admin_add_nomination(p_nominee_member_id uuid, p_nominee_name text, p_reason text) TO service_role;


--
-- Name: FUNCTION append_governance_event(p_event_type text, p_actor_admin_id uuid, p_actor_label text, p_controller_name text, p_organization_ref text, p_processing_purpose text, p_lawful_basis text, p_data_categories text[], p_data_subject_categories text[], p_retention_policy text, p_event_summary jsonb); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.append_governance_event(p_event_type text, p_actor_admin_id uuid, p_actor_label text, p_controller_name text, p_organization_ref text, p_processing_purpose text, p_lawful_basis text, p_data_categories text[], p_data_subject_categories text[], p_retention_policy text, p_event_summary jsonb) FROM PUBLIC;


--
-- Name: FUNCTION assert_electorate_editable(); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.assert_electorate_editable() FROM PUBLIC;
GRANT ALL ON FUNCTION private.assert_electorate_editable() TO service_role;


--
-- Name: FUNCTION assert_member_creation_allowed(); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.assert_member_creation_allowed() FROM PUBLIC;


--
-- Name: FUNCTION cast_anonymous_digital_vote(p_credential text, p_candidate_id uuid); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.cast_anonymous_digital_vote(p_credential text, p_candidate_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION private.cast_anonymous_digital_vote(p_credential text, p_candidate_id uuid) TO service_role;


--
-- Name: FUNCTION check_in_paper_voter(p_short_code text, p_member_id uuid, p_admin_id uuid); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.check_in_paper_voter(p_short_code text, p_member_id uuid, p_admin_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION private.check_in_paper_voter(p_short_code text, p_member_id uuid, p_admin_id uuid) TO service_role;


--
-- Name: FUNCTION cleanup_rate_limit_hits(p_older_than_seconds integer); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.cleanup_rate_limit_hits(p_older_than_seconds integer) FROM PUBLIC;
GRANT ALL ON FUNCTION private.cleanup_rate_limit_hits(p_older_than_seconds integer) TO service_role;


--
-- Name: FUNCTION correct_paper_vote(p_ballot_id text, p_new_candidate_id uuid, p_admin_id uuid, p_reason text); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.correct_paper_vote(p_ballot_id text, p_new_candidate_id uuid, p_admin_id uuid, p_reason text) FROM PUBLIC;
GRANT ALL ON FUNCTION private.correct_paper_vote(p_ballot_id text, p_new_candidate_id uuid, p_admin_id uuid, p_reason text) TO service_role;


--
-- Name: TABLE members; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.members TO service_role;


--
-- Name: FUNCTION create_member(p_full_name text, p_email text, p_phone text, p_member_code text); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.create_member(p_full_name text, p_email text, p_phone text, p_member_code text) FROM PUBLIC;
GRANT ALL ON FUNCTION private.create_member(p_full_name text, p_email text, p_phone text, p_member_code text) TO service_role;


--
-- Name: FUNCTION enforce_paper_ballot_layout_immutable(); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.enforce_paper_ballot_layout_immutable() FROM PUBLIC;


--
-- Name: FUNCTION enforce_token_eligibility(); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.enforce_token_eligibility() FROM PUBLIC;


--
-- Name: FUNCTION ensure_voting_entitlement(p_member_id uuid, p_admin_id uuid, p_token_hash character varying, p_channel_sent character varying); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.ensure_voting_entitlement(p_member_id uuid, p_admin_id uuid, p_token_hash character varying, p_channel_sent character varying) FROM PUBLIC;
GRANT ALL ON FUNCTION private.ensure_voting_entitlement(p_member_id uuid, p_admin_id uuid, p_token_hash character varying, p_channel_sent character varying) TO service_role;


--
-- Name: FUNCTION generate_anonymous_blank_ballot_pool(p_count integer, p_admin_id uuid); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.generate_anonymous_blank_ballot_pool(p_count integer, p_admin_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION private.generate_anonymous_blank_ballot_pool(p_count integer, p_admin_id uuid) TO service_role;


--
-- Name: FUNCTION generate_blank_paper_ballot_batch(p_count integer, p_admin_id uuid); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.generate_blank_paper_ballot_batch(p_count integer, p_admin_id uuid) FROM PUBLIC;


--
-- Name: FUNCTION generate_opaque_paper_ballot_id(); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.generate_opaque_paper_ballot_id() FROM PUBLIC;


--
-- Name: FUNCTION generate_qr_svg(p_ballot_id text); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.generate_qr_svg(p_ballot_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION private.generate_qr_svg(p_ballot_id text) TO service_role;


--
-- Name: FUNCTION generate_short_code(); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.generate_short_code() FROM PUBLIC;
GRANT ALL ON FUNCTION private.generate_short_code() TO service_role;


--
-- Name: FUNCTION get_pending_unmatched_nominations(p_limit integer, p_cursor_date date, p_cursor_id uuid); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.get_pending_unmatched_nominations(p_limit integer, p_cursor_date date, p_cursor_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION private.get_pending_unmatched_nominations(p_limit integer, p_cursor_date date, p_cursor_id uuid) TO service_role;


--
-- Name: FUNCTION issue_paper_ballot(p_member_id uuid, p_admin_id uuid); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.issue_paper_ballot(p_member_id uuid, p_admin_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION private.issue_paper_ballot(p_member_id uuid, p_admin_id uuid) TO service_role;


--
-- Name: FUNCTION issue_preprinted_paper_ballot(p_ballot_id text, p_member_id uuid, p_admin_id uuid); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.issue_preprinted_paper_ballot(p_ballot_id text, p_member_id uuid, p_admin_id uuid) FROM PUBLIC;


--
-- Name: FUNCTION paper_pool_reconciliation(); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.paper_pool_reconciliation() FROM PUBLIC;
GRANT ALL ON FUNCTION private.paper_pool_reconciliation() TO service_role;


--
-- Name: FUNCTION provision_voting_entitlements(p_member_ids uuid[], p_admin_id uuid); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.provision_voting_entitlements(p_member_ids uuid[], p_admin_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION private.provision_voting_entitlements(p_member_ids uuid[], p_admin_id uuid) TO service_role;


--
-- Name: FUNCTION purge_roster_pii(p_admin_id uuid, p_stage text, p_confirm text); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.purge_roster_pii(p_admin_id uuid, p_stage text, p_confirm text) FROM PUBLIC;


--
-- Name: FUNCTION redeem_voting_token(p_token_hash character varying); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.redeem_voting_token(p_token_hash character varying) FROM PUBLIC;
GRANT ALL ON FUNCTION private.redeem_voting_token(p_token_hash character varying) TO service_role;


--
-- Name: FUNCTION reissue_token(p_old_token_id uuid, p_admin_id uuid, p_reason text, p_new_token_hash character varying); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.reissue_token(p_old_token_id uuid, p_admin_id uuid, p_reason text, p_new_token_hash character varying) FROM PUBLIC;
GRANT ALL ON FUNCTION private.reissue_token(p_old_token_id uuid, p_admin_id uuid, p_reason text, p_new_token_hash character varying) TO service_role;


--
-- Name: FUNCTION reject_adjudication_mutation(); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.reject_adjudication_mutation() FROM PUBLIC;


--
-- Name: FUNCTION reject_nomination_mutation(); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.reject_nomination_mutation() FROM PUBLIC;


--
-- Name: FUNCTION reject_vote_audit_log_colocation(); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.reject_vote_audit_log_colocation() FROM PUBLIC;


--
-- Name: FUNCTION reject_vote_audit_log_mutation(); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.reject_vote_audit_log_mutation() FROM PUBLIC;


--
-- Name: FUNCTION release_digital_voting_reservation(p_token_hash character varying); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.release_digital_voting_reservation(p_token_hash character varying) FROM PUBLIC;
GRANT ALL ON FUNCTION private.release_digital_voting_reservation(p_token_hash character varying) TO service_role;


--
-- Name: FUNCTION search_members_for_nomination(p_token_hash character varying, p_query text); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.search_members_for_nomination(p_token_hash character varying, p_query text) FROM PUBLIC;
GRANT ALL ON FUNCTION private.search_members_for_nomination(p_token_hash character varying, p_query text) TO service_role;


--
-- Name: FUNCTION set_member_active(p_member_id uuid, p_active boolean); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.set_member_active(p_member_id uuid, p_active boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION private.set_member_active(p_member_id uuid, p_active boolean) TO service_role;


--
-- Name: FUNCTION spoil_paper_ballot(p_ballot_id text, p_reason text, p_admin_id uuid); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.spoil_paper_ballot(p_ballot_id text, p_reason text, p_admin_id uuid) FROM PUBLIC;


--
-- Name: FUNCTION spoil_paper_check_in(p_short_code text, p_reason text, p_admin_id uuid); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.spoil_paper_check_in(p_short_code text, p_reason text, p_admin_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION private.spoil_paper_check_in(p_short_code text, p_reason text, p_admin_id uuid) TO service_role;


--
-- Name: FUNCTION submit_anonymous_vote(p_token_hash character varying, p_candidate_id uuid); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.submit_anonymous_vote(p_token_hash character varying, p_candidate_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION private.submit_anonymous_vote(p_token_hash character varying, p_candidate_id uuid) TO service_role;


--
-- Name: FUNCTION submit_nomination(p_token_hash character varying, p_nominees jsonb); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.submit_nomination(p_token_hash character varying, p_nominees jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION private.submit_nomination(p_token_hash character varying, p_nominees jsonb) TO service_role;


--
-- Name: FUNCTION submit_paper_invalid(p_ballot_id text, p_reason text); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.submit_paper_invalid(p_ballot_id text, p_reason text) FROM PUBLIC;


--
-- Name: FUNCTION submit_paper_vote(p_ballot_id text, p_candidate_id uuid, p_admin_id uuid); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.submit_paper_vote(p_ballot_id text, p_candidate_id uuid, p_admin_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION private.submit_paper_vote(p_ballot_id text, p_candidate_id uuid, p_admin_id uuid) TO service_role;


--
-- Name: FUNCTION sweep_expired_digital_reservations(); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.sweep_expired_digital_reservations() FROM PUBLIC;
GRANT ALL ON FUNCTION private.sweep_expired_digital_reservations() TO service_role;


--
-- Name: FUNCTION void_anonymous_paper_blank(p_ballot_id text, p_reason text, p_admin_id uuid); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.void_anonymous_paper_blank(p_ballot_id text, p_reason text, p_admin_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION private.void_anonymous_paper_blank(p_ballot_id text, p_reason text, p_admin_id uuid) TO service_role;


--
-- Name: FUNCTION void_unused_anonymous_paper_blanks(p_admin_id uuid, p_reason text); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.void_unused_anonymous_paper_blanks(p_admin_id uuid, p_reason text) FROM PUBLIC;
GRANT ALL ON FUNCTION private.void_unused_anonymous_paper_blanks(p_admin_id uuid, p_reason text) TO service_role;


--
-- Name: FUNCTION void_unused_paper_ballots(p_batch_id uuid, p_reason text, p_admin_id uuid); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.void_unused_paper_ballots(p_batch_id uuid, p_reason text, p_admin_id uuid) FROM PUBLIC;


--
-- Name: FUNCTION wipe_election_data(p_admin_id uuid, p_token_hash character varying); Type: ACL; Schema: private; Owner: postgres
--

REVOKE ALL ON FUNCTION private.wipe_election_data(p_admin_id uuid, p_token_hash character varying) FROM PUBLIC;
GRANT ALL ON FUNCTION private.wipe_election_data(p_admin_id uuid, p_token_hash character varying) TO service_role;


--
-- Name: FUNCTION adjudicate_eligibility(p_admin_session_id uuid, p_member_id uuid, p_new_voting_eligible boolean, p_new_eligibility_reason text, p_note text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.adjudicate_eligibility(p_admin_session_id uuid, p_member_id uuid, p_new_voting_eligible boolean, p_new_eligibility_reason text, p_note text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.adjudicate_eligibility(p_admin_session_id uuid, p_member_id uuid, p_new_voting_eligible boolean, p_new_eligibility_reason text, p_note text) TO service_role;


--
-- Name: FUNCTION adjudicate_nomination(p_decision text, p_admin_session_id uuid, p_affected_nomination_ids uuid[], p_nominee_member_id uuid, p_nominee_name text, p_candidate_statement text, p_candidate_id uuid, p_note text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.adjudicate_nomination(p_decision text, p_admin_session_id uuid, p_affected_nomination_ids uuid[], p_nominee_member_id uuid, p_nominee_name text, p_candidate_statement text, p_candidate_id uuid, p_note text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.adjudicate_nomination(p_decision text, p_admin_session_id uuid, p_affected_nomination_ids uuid[], p_nominee_member_id uuid, p_nominee_name text, p_candidate_statement text, p_candidate_id uuid, p_note text) TO service_role;


--
-- Name: FUNCTION admin_add_nomination(p_nominee_member_id uuid, p_nominee_name text, p_reason text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.admin_add_nomination(p_nominee_member_id uuid, p_nominee_name text, p_reason text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_add_nomination(p_nominee_member_id uuid, p_nominee_name text, p_reason text) TO service_role;


--
-- Name: FUNCTION append_governance_event(p_event_type text, p_actor_admin_id uuid, p_actor_label text, p_controller_name text, p_organization_ref text, p_processing_purpose text, p_lawful_basis text, p_data_categories text[], p_data_subject_categories text[], p_retention_policy text, p_event_summary jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.append_governance_event(p_event_type text, p_actor_admin_id uuid, p_actor_label text, p_controller_name text, p_organization_ref text, p_processing_purpose text, p_lawful_basis text, p_data_categories text[], p_data_subject_categories text[], p_retention_policy text, p_event_summary jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.append_governance_event(p_event_type text, p_actor_admin_id uuid, p_actor_label text, p_controller_name text, p_organization_ref text, p_processing_purpose text, p_lawful_basis text, p_data_categories text[], p_data_subject_categories text[], p_retention_policy text, p_event_summary jsonb) TO service_role;


--
-- Name: FUNCTION assert_electorate_editable(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.assert_electorate_editable() FROM PUBLIC;
GRANT ALL ON FUNCTION public.assert_electorate_editable() TO service_role;


--
-- Name: FUNCTION cast_anonymous_digital_vote(p_credential text, p_candidate_id uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.cast_anonymous_digital_vote(p_credential text, p_candidate_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.cast_anonymous_digital_vote(p_credential text, p_candidate_id uuid) TO service_role;


--
-- Name: FUNCTION check_in_paper_voter(p_short_code text, p_member_id uuid, p_admin_id uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.check_in_paper_voter(p_short_code text, p_member_id uuid, p_admin_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.check_in_paper_voter(p_short_code text, p_member_id uuid, p_admin_id uuid) TO service_role;


--
-- Name: FUNCTION check_rate_limit(p_identifier text, p_window_seconds integer, p_max_requests integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.check_rate_limit(p_identifier text, p_window_seconds integer, p_max_requests integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.check_rate_limit(p_identifier text, p_window_seconds integer, p_max_requests integer) TO service_role;


--
-- Name: FUNCTION compute_audit_log_hash(p_action text, p_admin_id uuid, p_member_id uuid, p_details jsonb, p_previous_hash character, p_created_at timestamp with time zone); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.compute_audit_log_hash(p_action text, p_admin_id uuid, p_member_id uuid, p_details jsonb, p_previous_hash character, p_created_at timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION public.compute_audit_log_hash(p_action text, p_admin_id uuid, p_member_id uuid, p_details jsonb, p_previous_hash character, p_created_at timestamp with time zone) TO service_role;


--
-- Name: FUNCTION correct_paper_vote(p_ballot_id text, p_new_candidate_id uuid, p_admin_id uuid, p_reason text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.correct_paper_vote(p_ballot_id text, p_new_candidate_id uuid, p_admin_id uuid, p_reason text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.correct_paper_vote(p_ballot_id text, p_new_candidate_id uuid, p_admin_id uuid, p_reason text) TO service_role;


--
-- Name: FUNCTION create_member(p_full_name text, p_email text, p_phone text, p_member_code text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.create_member(p_full_name text, p_email text, p_phone text, p_member_code text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_member(p_full_name text, p_email text, p_phone text, p_member_code text) TO service_role;


--
-- Name: FUNCTION ensure_voting_entitlement(p_member_id uuid, p_admin_id uuid, p_token_hash character varying, p_channel_sent character varying); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.ensure_voting_entitlement(p_member_id uuid, p_admin_id uuid, p_token_hash character varying, p_channel_sent character varying) FROM PUBLIC;
GRANT ALL ON FUNCTION public.ensure_voting_entitlement(p_member_id uuid, p_admin_id uuid, p_token_hash character varying, p_channel_sent character varying) TO service_role;


--
-- Name: FUNCTION f4_candidates(); Type: ACL; Schema: public; Owner: f4_public_reader
--

REVOKE ALL ON FUNCTION public.f4_candidates() FROM PUBLIC;
GRANT ALL ON FUNCTION public.f4_candidates() TO anon;


--
-- Name: FUNCTION f4_election_status(); Type: ACL; Schema: public; Owner: f4_public_reader
--

REVOKE ALL ON FUNCTION public.f4_election_status() FROM PUBLIC;
GRANT ALL ON FUNCTION public.f4_election_status() TO anon;


--
-- Name: FUNCTION f4_results(p_receipt_code text); Type: ACL; Schema: public; Owner: f4_public_reader
--

REVOKE ALL ON FUNCTION public.f4_results(p_receipt_code text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.f4_results(p_receipt_code text) TO anon;


--
-- Name: FUNCTION f4_verify_ballot(p_ballot_id text, p_receipt_code text); Type: ACL; Schema: public; Owner: f4_public_reader
--

REVOKE ALL ON FUNCTION public.f4_verify_ballot(p_ballot_id text, p_receipt_code text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.f4_verify_ballot(p_ballot_id text, p_receipt_code text) TO anon;


--
-- Name: FUNCTION generate_anonymous_blank_ballot_pool(p_count integer, p_admin_id uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.generate_anonymous_blank_ballot_pool(p_count integer, p_admin_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.generate_anonymous_blank_ballot_pool(p_count integer, p_admin_id uuid) TO service_role;


--
-- Name: FUNCTION generate_blank_paper_ballot_batch(p_count integer, p_admin_id uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.generate_blank_paper_ballot_batch(p_count integer, p_admin_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.generate_blank_paper_ballot_batch(p_count integer, p_admin_id uuid) TO service_role;


--
-- Name: FUNCTION get_pending_unmatched_nominations(p_limit integer, p_cursor_date date, p_cursor_id uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.get_pending_unmatched_nominations(p_limit integer, p_cursor_date date, p_cursor_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_pending_unmatched_nominations(p_limit integer, p_cursor_date date, p_cursor_id uuid) TO service_role;


--
-- Name: FUNCTION insert_audit_log(p_action text, p_admin_id uuid, p_member_id uuid, p_details jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.insert_audit_log(p_action text, p_admin_id uuid, p_member_id uuid, p_details jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.insert_audit_log(p_action text, p_admin_id uuid, p_member_id uuid, p_details jsonb) TO service_role;


--
-- Name: FUNCTION issue_paper_ballot(p_member_id uuid, p_admin_id uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.issue_paper_ballot(p_member_id uuid, p_admin_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.issue_paper_ballot(p_member_id uuid, p_admin_id uuid) TO service_role;


--
-- Name: FUNCTION issue_preprinted_paper_ballot(p_ballot_id text, p_member_id uuid, p_admin_id uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.issue_preprinted_paper_ballot(p_ballot_id text, p_member_id uuid, p_admin_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.issue_preprinted_paper_ballot(p_ballot_id text, p_member_id uuid, p_admin_id uuid) TO service_role;


--
-- Name: FUNCTION paper_pool_reconciliation(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.paper_pool_reconciliation() FROM PUBLIC;
GRANT ALL ON FUNCTION public.paper_pool_reconciliation() TO service_role;


--
-- Name: FUNCTION provision_voting_entitlements(p_member_ids uuid[], p_admin_id uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.provision_voting_entitlements(p_member_ids uuid[], p_admin_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.provision_voting_entitlements(p_member_ids uuid[], p_admin_id uuid) TO service_role;


--
-- Name: FUNCTION purge_roster_pii(p_admin_id uuid, p_stage text, p_confirm text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.purge_roster_pii(p_admin_id uuid, p_stage text, p_confirm text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.purge_roster_pii(p_admin_id uuid, p_stage text, p_confirm text) TO service_role;


--
-- Name: FUNCTION redeem_voting_token(p_token_hash character varying); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.redeem_voting_token(p_token_hash character varying) FROM PUBLIC;
GRANT ALL ON FUNCTION public.redeem_voting_token(p_token_hash character varying) TO service_role;


--
-- Name: FUNCTION reissue_token(p_old_token_id uuid, p_admin_id uuid, p_reason text, p_new_token_hash character varying); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.reissue_token(p_old_token_id uuid, p_admin_id uuid, p_reason text, p_new_token_hash character varying) FROM PUBLIC;
GRANT ALL ON FUNCTION public.reissue_token(p_old_token_id uuid, p_admin_id uuid, p_reason text, p_new_token_hash character varying) TO service_role;


--
-- Name: FUNCTION release_digital_voting_reservation(p_token_hash character varying); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.release_digital_voting_reservation(p_token_hash character varying) FROM PUBLIC;
GRANT ALL ON FUNCTION public.release_digital_voting_reservation(p_token_hash character varying) TO service_role;


--
-- Name: FUNCTION rls_auto_enable(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.rls_auto_enable() TO service_role;


--
-- Name: FUNCTION search_members_for_nomination(p_token_hash character varying, p_query text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.search_members_for_nomination(p_token_hash character varying, p_query text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.search_members_for_nomination(p_token_hash character varying, p_query text) TO service_role;


--
-- Name: FUNCTION set_member_active(p_member_id uuid, p_active boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.set_member_active(p_member_id uuid, p_active boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_member_active(p_member_id uuid, p_active boolean) TO service_role;


--
-- Name: FUNCTION spoil_paper_ballot(p_ballot_id text, p_reason text, p_admin_id uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.spoil_paper_ballot(p_ballot_id text, p_reason text, p_admin_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.spoil_paper_ballot(p_ballot_id text, p_reason text, p_admin_id uuid) TO service_role;


--
-- Name: FUNCTION spoil_paper_check_in(p_short_code text, p_reason text, p_admin_id uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.spoil_paper_check_in(p_short_code text, p_reason text, p_admin_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.spoil_paper_check_in(p_short_code text, p_reason text, p_admin_id uuid) TO service_role;


--
-- Name: FUNCTION submit_anonymous_vote(p_token_hash character varying, p_candidate_id uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.submit_anonymous_vote(p_token_hash character varying, p_candidate_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.submit_anonymous_vote(p_token_hash character varying, p_candidate_id uuid) TO service_role;


--
-- Name: FUNCTION submit_nomination(p_token_hash character varying, p_nominees jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.submit_nomination(p_token_hash character varying, p_nominees jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.submit_nomination(p_token_hash character varying, p_nominees jsonb) TO service_role;


--
-- Name: FUNCTION submit_paper_invalid(p_ballot_id text, p_reason text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.submit_paper_invalid(p_ballot_id text, p_reason text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.submit_paper_invalid(p_ballot_id text, p_reason text) TO service_role;


--
-- Name: FUNCTION submit_paper_vote(p_ballot_id text, p_candidate_id uuid, p_admin_id uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.submit_paper_vote(p_ballot_id text, p_candidate_id uuid, p_admin_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.submit_paper_vote(p_ballot_id text, p_candidate_id uuid, p_admin_id uuid) TO service_role;


--
-- Name: FUNCTION void_anonymous_paper_blank(p_ballot_id text, p_reason text, p_admin_id uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.void_anonymous_paper_blank(p_ballot_id text, p_reason text, p_admin_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.void_anonymous_paper_blank(p_ballot_id text, p_reason text, p_admin_id uuid) TO service_role;


--
-- Name: FUNCTION void_unused_anonymous_paper_blanks(p_admin_id uuid, p_reason text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.void_unused_anonymous_paper_blanks(p_admin_id uuid, p_reason text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.void_unused_anonymous_paper_blanks(p_admin_id uuid, p_reason text) TO service_role;


--
-- Name: FUNCTION void_unused_paper_ballots(p_batch_id uuid, p_reason text, p_admin_id uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.void_unused_paper_ballots(p_batch_id uuid, p_reason text, p_admin_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.void_unused_paper_ballots(p_batch_id uuid, p_reason text, p_admin_id uuid) TO service_role;


--
-- Name: FUNCTION wipe_election_data(p_admin_id uuid, p_token_hash character varying); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.wipe_election_data(p_admin_id uuid, p_token_hash character varying) FROM PUBLIC;
GRANT ALL ON FUNCTION public.wipe_election_data(p_admin_id uuid, p_token_hash character varying) TO service_role;


--
-- Name: TABLE processing_activity_ledger; Type: ACL; Schema: governance; Owner: postgres
--

GRANT SELECT,INSERT ON TABLE governance.processing_activity_ledger TO service_role;


--
-- Name: TABLE admin_sessions; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.admin_sessions TO service_role;


--
-- Name: TABLE anonymous_digital_credentials; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.anonymous_digital_credentials TO service_role;


--
-- Name: TABLE anonymous_nominations; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.anonymous_nominations TO service_role;


--
-- Name: TABLE anonymous_paper_blanks; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.anonymous_paper_blanks TO service_role;


--
-- Name: TABLE ballot_audit_log; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.ballot_audit_log TO service_role;


--
-- Name: TABLE ballots; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.ballots TO service_role;


--
-- Name: COLUMN ballots.candidate_id; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(candidate_id) ON TABLE public.ballots TO f4_public_reader;


--
-- Name: COLUMN ballots.receipt_code; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(receipt_code) ON TABLE public.ballots TO f4_public_reader;


--
-- Name: COLUMN ballots.channel; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(channel) ON TABLE public.ballots TO f4_public_reader;


--
-- Name: COLUMN ballots.cast_date; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(cast_date) ON TABLE public.ballots TO f4_public_reader;


--
-- Name: COLUMN ballots.ballot_id; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(ballot_id) ON TABLE public.ballots TO f4_public_reader;


--
-- Name: TABLE candidates; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.candidates TO service_role;


--
-- Name: COLUMN candidates.id; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(id) ON TABLE public.candidates TO f4_public_reader;


--
-- Name: COLUMN candidates.full_name; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(full_name) ON TABLE public.candidates TO f4_public_reader;


--
-- Name: COLUMN candidates.statement; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(statement) ON TABLE public.candidates TO f4_public_reader;


--
-- Name: COLUMN candidates.photo_url; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(photo_url) ON TABLE public.candidates TO f4_public_reader;


--
-- Name: COLUMN candidates.is_active; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(is_active) ON TABLE public.candidates TO f4_public_reader;


--
-- Name: COLUMN candidates.created_at; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(created_at) ON TABLE public.candidates TO f4_public_reader;


--
-- Name: TABLE digital_credential_reservations; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.digital_credential_reservations TO service_role;


--
-- Name: TABLE election_settings; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.election_settings TO service_role;


--
-- Name: COLUMN election_settings.id; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(id) ON TABLE public.election_settings TO f4_public_reader;


--
-- Name: COLUMN election_settings.current_phase; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(current_phase) ON TABLE public.election_settings TO f4_public_reader;


--
-- Name: COLUMN election_settings.nomination_start; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(nomination_start) ON TABLE public.election_settings TO f4_public_reader;


--
-- Name: COLUMN election_settings.nomination_end; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(nomination_end) ON TABLE public.election_settings TO f4_public_reader;


--
-- Name: COLUMN election_settings.voting_start; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(voting_start) ON TABLE public.election_settings TO f4_public_reader;


--
-- Name: COLUMN election_settings.voting_end; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(voting_end) ON TABLE public.election_settings TO f4_public_reader;


--
-- Name: COLUMN election_settings.allow_write_ins; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(allow_write_ins) ON TABLE public.election_settings TO f4_public_reader;


--
-- Name: COLUMN election_settings.max_nominees_per_member; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(max_nominees_per_member) ON TABLE public.election_settings TO f4_public_reader;


--
-- Name: TABLE eligibility_adjudications; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.eligibility_adjudications TO service_role;


--
-- Name: TABLE nomination_adjudications; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.nomination_adjudications TO service_role;


--
-- Name: TABLE paper_ballot_batches; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.paper_ballot_batches TO service_role;


--
-- Name: TABLE paper_ballots; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.paper_ballots TO service_role;


--
-- Name: TABLE participation_audit; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.participation_audit TO service_role;


--
-- Name: TABLE phase_change_tokens; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.phase_change_tokens TO service_role;


--
-- Name: TABLE rate_limit_hits; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.rate_limit_hits TO service_role;


--
-- Name: TABLE tokens; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.tokens TO service_role;


--
-- Name: TABLE vote_audit_log; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.vote_audit_log TO service_role;


--
-- Name: TABLE wipe_confirmation_tokens; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.wipe_confirmation_tokens TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: supabase_admin
--



--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: supabase_admin
--



--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: supabase_admin
--



--
-- PostgreSQL database dump complete
--

\unrestrict vgWAUjqTlImCgHiiCGjkd7AyrBh68aHSVIQiOKmu4sukQwSjD2Xw8bRWpK8Jm0u


-- ---------------------------------------------------------------------------
-- Epilogue: restore least-privilege posture (matches the live database —
-- f4_public_reader holds no CREATE on schema public).
-- ---------------------------------------------------------------------------
REVOKE CREATE ON SCHEMA public FROM f4_public_reader;
REVOKE SET OPTION FOR f4_public_reader FROM postgres;
