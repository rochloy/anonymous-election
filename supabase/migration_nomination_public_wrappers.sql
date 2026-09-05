-- Public schema wrapper functions forwarding calls to private nomination RPCs.
-- Mirrors migration_public_wrappers.sql: the nomination feature's private RPCs
-- (migration_nomination_submission.sql) were created only in the `private` schema,
-- which is NOT exposed via PostgREST. Without these public wrappers,
-- supabaseServer.rpc('search_members_for_nomination'|'submit_nomination'|
-- 'admin_add_nomination') resolves against `public`, finds nothing, and the route's
-- `.schema('private').rpc(...)` fallback also fails (private is unexposed) — so the
-- whole nomination HTTP flow silently returns empty. These wrappers restore it.
--
-- Run AFTER migration_nomination_submission.sql.

CREATE OR REPLACE FUNCTION public.search_members_for_nomination(p_token_hash VARCHAR, p_query TEXT)
RETURNS TABLE (member_id UUID, full_name TEXT)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, private
AS $$
  SELECT * FROM private.search_members_for_nomination(p_token_hash, p_query);
$$;

CREATE OR REPLACE FUNCTION public.submit_nomination(p_token_hash VARCHAR, p_nominees JSONB)
RETURNS TABLE (success BOOLEAN, message TEXT, inserted_count INTEGER)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, private
AS $$
  SELECT * FROM private.submit_nomination(p_token_hash, p_nominees);
$$;

CREATE OR REPLACE FUNCTION public.admin_add_nomination(p_nominee_member_id UUID, p_nominee_name TEXT, p_reason TEXT)
RETURNS TABLE (success BOOLEAN, message TEXT)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, private
AS $$
  SELECT * FROM private.admin_add_nomination(p_nominee_member_id, p_nominee_name, p_reason);
$$;

GRANT EXECUTE ON FUNCTION public.search_members_for_nomination(VARCHAR, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.submit_nomination(VARCHAR, JSONB) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_add_nomination(UUID, TEXT, TEXT) TO service_role;
