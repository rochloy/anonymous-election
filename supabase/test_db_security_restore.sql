-- test_db_security_restore.sql
--
-- Exact undo of test_db_security_sabotage.sql. Idempotent.

REVOKE SELECT ON public.candidates FROM anon;
REVOKE USAGE ON SCHEMA private FROM anon;
DROP FUNCTION IF EXISTS private.sabotage_canary();
DROP FUNCTION IF EXISTS private.hmac_sign(text);
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE SELECT ON TABLES FROM anon;
DROP SCHEMA IF EXISTS backup_sabotage CASCADE;
