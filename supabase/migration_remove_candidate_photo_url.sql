-- migration_remove_candidate_photo_url.sql
--
-- Canonical run order item 51. Removes candidates.photo_url entirely:
-- the field was collected, validated, stored, and returned by three APIs —
-- but never rendered anywhere in the UI (the only <img> in the app is the
-- QR code). Rationale:
--   * Simplicity-first / YAGNI: a speculative feature that never shipped.
--   * Data minimization: photos of real candidates are PII; an unused
--     PII-adjacent column is pure liability ahead of the real-PII review.
--   * Election fairness: optional photos on a ballot create unequal visual
--     prominence (declining becomes a visible disadvantage, which also
--     undermines free consent). The uniform text ballot is the fair design.
--   * Debt-free: any future all-or-nothing photo feature (organizer-mandated,
--     uniform) would replace this free-form-URL column with a storage-object
--     design anyway — removal loses nothing in either future.
-- Companion app change: img-src drops the 'https:' wildcard (this field was
-- its only justification) -> 'self' data: blob:.
--
-- f4_candidates and f4_results are rewritten WITHOUT photo_url (they are
-- owned by f4_public_reader — the item-49 SET ROLE dance applies), then the
-- column is dropped (its f4_public_reader column grant dies with it).
-- The two function bodies are extracted verbatim from the item-50 baseline
-- (supabase/schema.sql) and altered by sed rules verified by the fail-closed
-- post-conditions at the end of this file.
BEGIN;

GRANT f4_public_reader TO postgres WITH SET OPTION;
GRANT CREATE ON SCHEMA public TO f4_public_reader;
SET ROLE f4_public_reader;

-- ---------------------------------------------------------------------------
-- 1. f4_candidates (verbatim, photo_url pair removed).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.f4_candidates() RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    AS $$
  SELECT COALESCE(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'id', c.id,
        'full_name', c.full_name,
        'statement', c.statement
      )
      ORDER BY c.created_at ASC, c.id ASC
    ),
    '[]'::jsonb
  )
  FROM public.candidates AS c
  WHERE c.is_active = true;
$$;


-- ---------------------------------------------------------------------------
-- 2. f4_results (verbatim, photo_url pair + GROUP BY entry removed).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.f4_results(p_receipt_code text) RETURNS jsonb
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
    GROUP BY c.id, c.full_name, c.statement, c.created_at
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


-- ---------------------------------------------------------------------------
-- 3. Re-assert the F4 ACL posture (matches the live ACL exactly).
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.f4_candidates() FROM PUBLIC;
GRANT ALL ON FUNCTION public.f4_candidates() TO anon;
REVOKE ALL ON FUNCTION public.f4_results(text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.f4_results(text) TO anon;

-- ---------------------------------------------------------------------------
-- 4. Unwind the ownership dance, then drop the column as the table owner.
-- ---------------------------------------------------------------------------
RESET ROLE;
REVOKE CREATE ON SCHEMA public FROM f4_public_reader;
REVOKE SET OPTION FOR f4_public_reader FROM postgres;

ALTER TABLE public.candidates DROP COLUMN photo_url;

-- ---------------------------------------------------------------------------
-- Fail-closed post-conditions. Any violation aborts the transaction.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_n INT;
  v_def TEXT;
  v_bad TEXT;
BEGIN
  -- (1) The column is gone.
  SELECT count(*) INTO v_n FROM information_schema.columns
  WHERE table_schema='public' AND table_name='candidates' AND column_name='photo_url';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'ABORT: candidates.photo_url still exists.';
  END IF;

  -- (2) Neither public RPC references it anymore.
  IF pg_get_functiondef('public.f4_candidates()'::regprocedure) LIKE '%photo_url%'
     OR pg_get_functiondef('public.f4_results(text)'::regprocedure) LIKE '%photo_url%' THEN
    RAISE EXCEPTION 'ABORT: an f4 public RPC still references photo_url.';
  END IF;

  -- (3) f4 ACL + ownership posture preserved on the two rewritten RPCs.
  SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname IN ('f4_candidates','f4_results')
    AND (pg_get_userbyid(p.proowner) <> 'f4_public_reader'
         OR NOT has_function_privilege('anon', p.oid, 'EXECUTE')
         OR has_function_privilege('authenticated', p.oid, 'EXECUTE'));
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'ABORT: f4_candidates/f4_results ownership or ACL posture broken.';
  END IF;

  -- (4) The untouched f4 RPCs are still intact.
  IF NOT has_function_privilege('anon','public.f4_verify_ballot(text,text)','EXECUTE')
     OR NOT has_function_privilege('anon','public.f4_election_status()','EXECUTE') THEN
    RAISE EXCEPTION 'ABORT: untouched f4 RPCs lost anon EXECUTE.';
  END IF;

  -- (5) Ownership dance fully unwound: membership rows keep set_option=false,
  --     reader holds no CREATE on public.
  SELECT count(*) INTO v_n FROM pg_auth_members
  WHERE roleid='f4_public_reader'::regrole AND member='postgres'::regrole AND set_option;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'ABORT: transient SET OPTION not revoked.';
  END IF;
  IF has_schema_privilege('f4_public_reader','public','CREATE') THEN
    RAISE EXCEPTION 'ABORT: transient CREATE on public not revoked.';
  END IF;

  -- (6) The reader's column grants on candidates lost exactly photo_url
  --     (M1 granted all 6 columns the RPCs read; 5 must remain).
  SELECT string_agg(column_name, ',' ORDER BY column_name) INTO v_bad
  FROM information_schema.column_privileges
  WHERE grantee='f4_public_reader' AND table_schema='public' AND table_name='candidates';
  IF v_bad IS DISTINCT FROM 'created_at,full_name,id,is_active,statement' THEN
    RAISE EXCEPTION 'ABORT: unexpected column-grant set on candidates: %', v_bad;
  END IF;

  RAISE NOTICE 'OK: photo_url removed; f4 posture, membership rows, and column grants consistent.';
END
$$;

COMMIT;
