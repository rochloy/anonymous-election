-- ============================================================================
-- Public wrapper for the in-app database wipe RPC (canonical run order item 40)
-- Purpose: migration_wipe_election_data.sql (item 38) created the function ONLY
--   in the `private` schema, which is NOT exposed via PostgREST. The route
--   app/api/admin/wipe-database/route.ts calls supabaseServer.rpc(
--   'wipe_election_data', { p_admin_id }), which resolves against `public` and
--   failed with "Could not find the function public.wipe_election_data(p_admin_id)
--   in the schema cache". This wrapper restores the call path, mirroring
--   migration_public_wrappers.sql / migration_nomination_public_wrappers.sql.
--
-- Run AFTER migration_wipe_election_data.sql (item 38). Idempotent.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.wipe_election_data(
  p_admin_id UUID DEFAULT NULL
)
RETURNS TABLE (success BOOLEAN, message TEXT)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, private
AS $$
  SELECT * FROM private.wipe_election_data(p_admin_id);
$$;

-- Lock down: a new function gets EXECUTE granted to PUBLIC by default. This
-- wrapper lives in the PostgREST-exposed `public` schema and has no internal
-- auth (admin auth + CSRF is enforced in the Next.js route), so the default
-- grant would let anyone holding the public anon key wipe the database during
-- SETUP. The REVOKE/GRANT signature MUST be (UUID) — a mismatched signature
-- fails with 42883 and leaves the PUBLIC default in place.
REVOKE EXECUTE ON FUNCTION public.wipe_election_data(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.wipe_election_data(UUID) TO service_role;

-- Make the new function visible to PostgREST immediately.
NOTIFY pgrst, 'reload schema';
