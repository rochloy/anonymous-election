# Tasks

## 1. Migration

- [x] 1.1 Write `supabase/migration_repoint_paper_actor_fks.sql`: NULL pre-check (raisable) on `paper_ballot_batches.generated_by`; dynamic FK drop via `pg_constraint`/`pg_attribute`; re-add as `REFERENCES admin_sessions(id) ON DELETE RESTRICT`. **Revised after live-DB pre-flight (2026-09-30):** scope narrowed from five FKs to one — Wave 6 already repointed the `paper_ballots` actor columns (`checked_in_by`/`spoiled_by`/`voided_by`), and `issued_by`/`recorded_by` no longer exist. Parse verification deferred to task 3.1 (no local Postgres/Docker on this machine — the live-DB apply session proves syntax).
- [x] 1.2 Write rollback migration `supabase/migration_repoint_paper_actor_fks_rollback.sql` (re-point `generated_by` to `members(id)`, NULL-guarded) — authored and reviewed, NOT executed; listed in TECHNICAL_GUIDE EXCLUDED block.

## 2. Documentation

- [x] 2.1 Append item 39 (`migration_repoint_paper_actor_fks.sql`) to the canonical run order in `docs/TECHNICAL_GUIDE.md` (after item 38, SETUP-phase-only note; `seed.sql` stays last of the base rebuild at item 21). Verify: list reads 1–39 and filename matches exactly.
- [x] 2.2 CHANGELOG `[Unreleased]` entry describing the repoint and its data-safe NULL precondition. Verify: entry exists under the correct heading.

## 3. Live-DB verification (requires SETUP phase — do NOT run mid-election; requires a session with Supabase MCP env vars sourced)

- [x] 3.1 Apply the migration via Supabase MCP; confirm `paper_ballot_batches.generated_by` now references `admin_sessions` with `DELETE RESTRICT`. Verify: `pg_constraint` query returns the expected FK row (confrelid = admin_sessions, confdeltype = RESTRICT). **Done 2026-09-30** — migration `repoint_paper_actor_fks` applied; constraint query returned `paper_ballot_batches_generated_by_fkey → admin_sessions, on_delete 'r'`.
- [x] 3.2 Known-bad input guard: setting `generated_by` to a member UUID MUST fail with FK violation; setting it to a real `admin_sessions.id` MUST succeed (revert after). Verify: the member-UUID UPDATE was rejected with 23503 (so nothing changed); the admin-session UPDATE was committed, then a second UPDATE reset `generated_by` to NULL; final SELECT confirms NULL. **Done 2026-09-30** — member UUID rejected with 23503 (`Key (generated_by)=(…) is not present in table "admin_sessions"`); session UUID accepted, then reset to NULL (final SELECT confirms NULL).
