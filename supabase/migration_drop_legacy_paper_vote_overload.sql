-- Drop the orphaned legacy private.submit_paper_vote(VARCHAR, UUID) overload
--
-- Context: the original design (docs/plans/2026-08-02-anonymous-election-hardened.md)
-- voted by member_code, so it defined private.submit_paper_vote(p_member_code
-- VARCHAR(20), p_candidate_id UUID). The implementation switched to voting by
-- ballot_id, so every migration that ships the function uses the
-- (p_ballot_id TEXT, p_candidate_id UUID) signature (schema.sql,
-- migration_paper_ballots.sql, migration_option_e_paper_ballots_part2.sql,
-- migration_fix_paper_rpcs.sql). Because CREATE OR REPLACE FUNCTION keys on
-- argument TYPES, the TEXT version never replaced the VARCHAR one — it created a
-- second overload, leaving the VARCHAR version orphaned in the live DB (with its
-- default PUBLIC EXECUTE grant, closed in migration_lock_public_vote_wrappers.sql).
--
-- The VARCHAR overload is dead code: no runtime caller passes p_member_code (the
-- only call site, app/api/admin/paper-vote/route.ts, passes p_ballot_id), and no
-- migration recreates this signature, so dropping it is safe and permanent.
--
-- Private schema (not PostgREST-exposed). Idempotent.

DROP FUNCTION IF EXISTS private.submit_paper_vote(VARCHAR, UUID);
