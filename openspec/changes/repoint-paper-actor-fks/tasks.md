# Tasks

## 1. Migration

- [ ] 1.1 Write `supabase/migration_repoint_paper_actor_fks.sql`: NULL pre-check (raisable) on `paper_ballots.issued_by/.recorded_by/.spoiled_by/.voided_by` and `paper_ballot_batches.generated_by`; dynamic FK drop via `information_schema`; re-add all five as `REFERENCES admin_sessions(id) ON DELETE RESTRICT`. Verify: SQL parses cleanly in a rolled-back `DO`-block dry run.
- [ ] 1.2 Write rollback migration (re-point to `members(id)`) — authored and reviewed, NOT executed. Verify: file exists alongside the forward migration with clear header marking it rollback-only.

## 2. Documentation

- [ ] 2.1 Append item 39 (`migration_repoint_paper_actor_fks.sql`) to the canonical run order in `docs/TECHNICAL_GUIDE.md`, noting it precedes `seed.sql` (which stays last) and is SETUP-phase-only. Verify: doc lists 39 items and the new entry matches the filename exactly.
- [ ] 2.2 CHANGELOG `[Unreleased]` entry describing the repoint and its data-safe NULL precondition. Verify: entry exists under the correct heading.

## 3. Live-DB verification (requires SETUP phase — do NOT run mid-election)

- [ ] 3.1 Apply the migration via Supabase MCP / SQL Editor; confirm all five constraints now reference `admin_sessions` with `DELETE RESTRICT`. Verify: `information_schema.table_constraints` + `referential_constraints` query returns the expected 5 rows.
- [ ] 3.2 Known-bad input guard: setting `issued_by` to a member UUID MUST fail with FK violation; setting it to a real `admin_sessions.id` MUST succeed (revert after). Verify: both outcomes observed in a rolled-back transaction (`BEGIN; ... ROLLBACK;`).
