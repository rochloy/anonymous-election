-- Public schema wrapper functions forwarding calls to private schema RPCs
-- Executing this in Supabase SQL Editor ensures PostgREST exposes these endpoints under public schema

CREATE OR REPLACE FUNCTION public.issue_paper_ballot(p_member_id UUID)
RETURNS TABLE (success BOOLEAN, message TEXT, ballot_id TEXT, short_code TEXT, qr_svg TEXT)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, private
AS $$
  SELECT * FROM private.issue_paper_ballot(p_member_id);
$$;

CREATE OR REPLACE FUNCTION public.submit_paper_vote(p_ballot_id TEXT, p_candidate_id UUID)
RETURNS TABLE (success BOOLEAN, message TEXT, receipt_code TEXT)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, private
AS $$
  SELECT * FROM private.submit_paper_vote(p_ballot_id, p_candidate_id);
$$;

CREATE OR REPLACE FUNCTION public.submit_paper_invalid(p_ballot_id TEXT, p_reason TEXT)
RETURNS TABLE (success BOOLEAN, message TEXT)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, private
AS $$
  SELECT * FROM private.submit_paper_invalid(p_ballot_id, p_reason);
$$;

CREATE OR REPLACE FUNCTION public.submit_anonymous_vote(p_token_hash VARCHAR, p_candidate_id UUID)
RETURNS TABLE (success BOOLEAN, message TEXT, receipt_code TEXT, ballot_id TEXT)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, private
AS $$
  SELECT * FROM private.submit_anonymous_vote(p_token_hash, p_candidate_id);
$$;

GRANT EXECUTE ON FUNCTION public.issue_paper_ballot(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.submit_paper_vote(TEXT, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.submit_paper_invalid(TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.submit_anonymous_vote(VARCHAR, UUID) TO service_role;
