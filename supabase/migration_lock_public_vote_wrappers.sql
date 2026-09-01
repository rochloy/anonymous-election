-- Lock down public vote/ballot wrapper functions (correctness review #3)
--
-- Context: migration_public_wrappers.sql creates SECURITY DEFINER wrapper
-- functions in the `public` schema and GRANTs EXECUTE to service_role, but
-- never REVOKEs the PostgreSQL default (EXECUTE granted to PUBLIC on function
-- creation). Because these functions are exposed via PostgREST under the
-- public schema, anon/authenticated roles could invoke them directly with the
-- anon key, bypassing the server-only service-role app layer.
--
-- migration_option_e_paper_ballots_part2.sql already revokes the Option E
-- wrappers (generate_blank_paper_ballot_batch, issue_preprinted_paper_ballot,
-- spoil_paper_ballot, void_unused_paper_ballots) but NOT these four vote/issue
-- wrappers or their three still-public private counterparts. This migration
-- closes that gap. Idempotent; safe to re-run.
--
-- Run order: after migration_public_wrappers.sql (step 4) and after
-- migration_option_e_paper_ballots_part2.sql (step 8).

-- Public wrapper functions (PostgREST-exposed) --------------------------------
REVOKE EXECUTE ON FUNCTION public.issue_paper_ballot(UUID)            FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.submit_paper_vote(TEXT, UUID)       FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.submit_paper_invalid(TEXT, TEXT)    FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.submit_anonymous_vote(VARCHAR, UUID) FROM PUBLIC, anon, authenticated;

-- Private counterparts not yet revoked in part2 -------------------------------
REVOKE EXECUTE ON FUNCTION private.issue_paper_ballot(UUID)         FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.submit_paper_vote(TEXT, UUID)    FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.submit_paper_invalid(TEXT, TEXT) FROM PUBLIC, anon, authenticated;

-- private.submit_anonymous_vote: schema.sql + part2 revoke only anon/authenticated,
-- never PUBLIC. Close the PUBLIC default too.
REVOKE EXECUTE ON FUNCTION private.submit_anonymous_vote(VARCHAR, UUID) FROM PUBLIC, anon, authenticated;

-- Option E wrappers: part2 revokes only anon/authenticated, never PUBLIC --------
REVOKE EXECUTE ON FUNCTION public.generate_blank_paper_ballot_batch(INT, UUID)  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.issue_preprinted_paper_ballot(TEXT, UUID, UUID) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.spoil_paper_ballot(TEXT, TEXT, UUID)          FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.void_unused_paper_ballots(UUID, TEXT, UUID)   FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.generate_blank_paper_ballot_batch(INT, UUID) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.issue_preprinted_paper_ballot(TEXT, UUID, UUID) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.spoil_paper_ballot(TEXT, TEXT, UUID)         FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.void_unused_paper_ballots(UUID, TEXT, UUID)  FROM PUBLIC, anon, authenticated;

-- Re-assert service_role access (idempotent) ----------------------------------
GRANT EXECUTE ON FUNCTION public.issue_paper_ballot(UUID)             TO service_role;
GRANT EXECUTE ON FUNCTION public.submit_paper_vote(TEXT, UUID)        TO service_role;
GRANT EXECUTE ON FUNCTION public.submit_paper_invalid(TEXT, TEXT)     TO service_role;
GRANT EXECUTE ON FUNCTION public.submit_anonymous_vote(VARCHAR, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION private.issue_paper_ballot(UUID)            TO service_role;
GRANT EXECUTE ON FUNCTION private.submit_paper_vote(TEXT, UUID)       TO service_role;
GRANT EXECUTE ON FUNCTION private.submit_paper_invalid(TEXT, TEXT)    TO service_role;

-- Future-proofing: stop new functions in these schemas from defaulting to
-- PUBLIC EXECUTE. Affects only FUTURE functions created by the current role;
-- existing functions are handled by the explicit REVOKEs above. The app only
-- ever invokes RPCs as service_role, so this is safe.
ALTER DEFAULT PRIVILEGES IN SCHEMA public  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA private REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
