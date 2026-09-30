# Tasks

## 1. Migration

- [x] 1.1 Write `supabase/migration_repoint_paper_actor_fks.sql`: NULL pre-check (raisable) on `paper_ballots.issued_by/.recorded_by/.spoiled_by/.voided_by` and `paper_ballot_batches.generated_by`; dynamic FK drop via `pg_constraint`/`information_schema`; re-add all five as `REFERENCES admin_sessions(id) ON DELETE RESTRICT`. Parse verification deferred to task 3.1 (no local Postgres/Docker on this machine — the live-DB apply session proves syntax).
- [x] 1.2 Write rollback migration `supabase/migration_repoint_paper_actor_fks_rollback.sql` (re-point to `members(id)`, NULL-guarded) — authored and reviewed, NOT executed; listed in TECHNICAL_GUIDE EXCLUDED block.

## 2. Documentation

- [x] 2.1 Append item 39 (`migration_repoint_paper_actor_fks.sql`) to the canonical run order in `docs/TECHNICAL_GUIDE.md` (after item 38, SETUP-phase-only note; `seed.sql` stays last of the base rebuild at item 21). Verify: list reads 1–39 and filename matches exactly.
- [x] 2.2 CHANGELOG `[Unreleased]` entry describing the repoint and its data-safe NULL precondition. Verify: entry exists under the correct heading.

## 3. Live-DB verification (requires SETUP phase — do NOT run mid-election; requires a session with Supabase MCP env vars sourced)

- [ ] 3.1 Apply the migration via Supabase MCP / SQL Editor; confirm all five constraints now reference `admin_sessions` with `DELETE RESTRICT`. Verify: `information_schema.table_constraints` + `referential_constraints` query returns the expected 5 rows.
- [ ] 3.2 Known-bad input guard: setting `issued_by` to a member UUID MUST fail with FK violation; setting it to a real `admin_sessions.id` MUST succeed (revert after). Verify: both outcomes observed in a rolled-back transaction (`BEGIN; ... ROLLBACK;`).
