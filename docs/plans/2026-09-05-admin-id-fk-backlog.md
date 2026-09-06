# Backlog — admin_id FK fix (Plan C) follow-ups

Context: `migration_fix_admin_id_fk.sql` (2026-09-05) repointed `vote_audit_log.admin_id`
and `nomination_adjudications.admin_id` from `members(id)` to `admin_sessions(id) ON DELETE
RESTRICT`, added revoke-not-delete columns, a `vote_audit_log` append-only trigger, and the
atomic `adjudicate_nomination` RPC. The items below were deliberately deferred out of Plan C.

## 1. Advisory lock in `insert_audit_log` (concurrency — chain fork risk)
`insert_audit_log` (`supabase/migration_audit_log_hash_chain.sql:37-65`) reads the latest
`record_hash` then inserts a new row hashing it as `previous_hash`. Under concurrent admin
writes, two transactions can read the same tip and both chain off it — forking the SEC-18
tamper-evident chain (two rows share a `previous_hash`). Fix: take a transaction-scoped
advisory lock (`pg_advisory_xact_lock(<const>)`) at the top of `insert_audit_log` to serialize
appends. Low probability today (single shared admin credential, low write concurrency), but it
is a correctness bug in the integrity guarantee. Oracle-flagged 2026-09-05.

## 2. `audit-log.ts` direct-insert fallback bypasses the hash chain
`lib/audit-log.ts:24-48` falls back to a direct `INSERT` into `vote_audit_log` when the RPC
fails. Before the FK fix that fallback always FK-violated (no row). Now the FK is valid, so the
fallback would SUCCEED but write a row with NULL `record_hash`/`previous_hash`, silently
breaking the chain. Oracle guidance: audit failures for state-mutating admin actions should
HARD-FAIL, not fall back. Options: (a) drop the direct-insert fallback entirely and propagate
the error so callers fail the action; (b) keep a fallback only for non-mutating/observational
logs. The adjudication path already avoids this (audit is inside the atomic RPC); the remaining
`insertAuditLog` callers (paper-ballot/admin action paths) still use the fallback.

## 3. `admin_principals` — multiple admins / per-person credentials
Today there is a single shared `ADMIN_SECRET`; `admin_sessions` has no person linkage, so
`admin_id` attributes an action to a *session*, not an identity. If per-admin accountability is
ever required, add an `admin_principals` table (person identity + credential), link
`admin_sessions.principal_id -> admin_principals(id)`, and surface the principal in audit
queries. Explicitly OUT OF SCOPE for Plan C (which only corrected the FK target); this is a
feature, not a fix.
