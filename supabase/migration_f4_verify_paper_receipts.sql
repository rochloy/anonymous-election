-- migration_f4_verify_paper_receipts.sql
--
-- Canonical run order item 49. f4_verify_ballot (the public verification
-- surface) previously accepted only DIGITAL receipts (^VC-[0-9A-F]{10}$) and
-- returned found:false BEFORE the ballot lookup whenever a receipt was
-- supplied -- so a paper voter entering their PB- receipt got a false
-- "not found" even with a valid ballot ID. Ballot-ID-only lookup worked.
--
-- This accepts paper receipts (PB-<10hex>, minted by submit_paper_vote as
-- 'PB-' || encode(gen_random_bytes(5),'hex')) alongside digital ones, and
-- preserves the prefix during canonicalization instead of hardcoding VC-.
--
-- No new exposure: the response is still only {found, channel, cast_date,
-- receipt_match} -- never the candidate -- and paper voters already hold
-- the ballot_id printed on their ballot, so the PB- receipt is a second
-- handle to the same answer. Exact-match semantics unchanged (no wildcard).
--
-- f4_results needs NO change: it has no format guard (length cap only) and
-- compares lower(receipt_code) case-insensitively, so the results page
-- already accepts PB- receipts.
--
-- The modified function body is extracted verbatim from the live hosted
-- schema and altered by exactly two sed rules (verified by the fail-closed
-- post-conditions at the end of this file).
--
-- OWNERSHIP: f4_verify_ballot is owned by f4_public_reader (F4 M1 design --
-- the postgres role cannot alter the public verify surface unassumed).
-- postgres already HOLDS membership in f4_public_reader (the CREATE ROLE
-- auto-grant: admin_option=t, but set_option=f), so SET ROLE is normally
-- denied. This migration toggles the SET option on for the duration of ONE
-- transaction (allowed: postgres holds ADMIN on that membership) and toggles
-- it back off at the end, leaving every pre-existing membership row intact.
BEGIN;

GRANT f4_public_reader TO postgres WITH SET OPTION;
GRANT CREATE ON SCHEMA public TO f4_public_reader;
SET ROLE f4_public_reader;

-- ---------------------------------------------------------------------------
-- 1. f4_verify_ballot: accept PB- receipts (verbatim, 2-line change).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.f4_verify_ballot(p_ballot_id text, p_receipt_code text) RETURNS jsonb
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


-- ---------------------------------------------------------------------------
-- 2. Re-assert the F4 ACL posture (matches the live ACL exactly).
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.f4_verify_ballot(text, text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.f4_verify_ballot(text, text) TO anon;

-- ---------------------------------------------------------------------------
-- Fail-closed post-conditions. Any violation aborts the transaction.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_def TEXT;
BEGIN
  v_def := pg_get_functiondef('public.f4_verify_ballot(text,text)'::regprocedure);

  -- (1) Receipt pattern accepts both digital (VC-) and paper (PB-) receipts.
  IF position('''^(VC|PB)-[0-9A-F]{10}$''' IN v_def) = 0 THEN
    RAISE EXCEPTION 'ABORT: f4_verify_ballot does not accept PB- receipts (pattern guard unchanged).';
  END IF;

  -- (2) Canonicalization preserves the prefix instead of hardcoding VC-.
  IF position('pg_catalog.upper(pg_catalog.left(v_receipt, 3))' IN v_def) = 0 THEN
    RAISE EXCEPTION 'ABORT: f4_verify_ballot still hardcodes the VC- prefix in canonicalization.';
  END IF;

  -- (3) F4 ACL posture preserved: anon can call, authenticated cannot.
  IF NOT has_function_privilege('anon', 'public.f4_verify_ballot(text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'ABORT: anon lost EXECUTE on f4_verify_ballot.';
  END IF;
  IF has_function_privilege('authenticated', 'public.f4_verify_ballot(text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'ABORT: authenticated must not hold EXECUTE on f4_verify_ballot.';
  END IF;

  RAISE NOTICE 'OK: f4_verify_ballot accepts VC- and PB- receipts; ACL posture preserved.';
END
$$;


RESET ROLE;
REVOKE CREATE ON SCHEMA public FROM f4_public_reader;
REVOKE SET OPTION FOR f4_public_reader FROM postgres;
COMMIT;
