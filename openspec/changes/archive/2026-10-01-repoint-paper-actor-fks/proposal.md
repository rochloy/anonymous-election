# Proposal

## Why

Paper-plane actor/attribution columns record *which admin* performed an operation, but an admin's identity in this system is an `admin_sessions` row — never a `members` row. Historically these columns were FK'd to `members(id)`, which made them unwritable (an admin session UUID FK-violates) and semantically false (the schema would accept a *voter* UUID as the actor). Wave 6's paper severance already fixed the `paper_ballots` actor columns — the rebuilt table declares `checked_in_by` / `spoiled_by` / `voided_by` as `REFERENCES admin_sessions(id) ON DELETE RESTRICT`, and the pre-Wave-6 `issued_by` / `recorded_by` columns no longer exist. **Live-DB verification (2026-09-30, SETUP phase) confirmed exactly one wrong actor FK remains: `paper_ballot_batches.generated_by` → `members(id)`** (created by the Option E migration, never touched by the later waves). The column is all-NULL today, so the repoint is a pure constraint correction with zero data migration.

## What Changes

- New final-writer migration repointing the one remaining wrong actor FK from `members(id)` to `admin_sessions(id) ON DELETE RESTRICT`:
  - `paper_ballot_batches.generated_by`
- Hard NULL pre-check (fails loudly if the column is unexpectedly populated); dynamic FK drop (robust to constraint-name drift); idempotent re-add.
- Canonical migration run order in `docs/TECHNICAL_GUIDE.md` gains the new migration (item 39, after the wipe RPC; `seed.sql` stays last of the base rebuild).
- NOT in scope: re-enabling RPC writes to the column (admin attribution UX is a separate decision), the `admin_principals` feature, and the two other audit-integrity backlog items (`insert_audit_log` advisory lock, `audit-log.ts` direct-insert fallback) — recorded as follow-ups only.

## Capabilities

### New Capabilities

- `paper-ballot-attribution`: integrity guarantee that paper-plane actor columns reference admin sessions (not members), so admin attribution is *possible* without ever confusing it for voter identity. Covers the already-correct `paper_ballots` actor columns (invariant restated) and the `generated_by` repoint (the delta this change lands).

### Modified Capabilities

(none — no existing capability specs; first OpenSpec change in this repo)

## Impact

- **Database:** one new migration `supabase/migration_repoint_paper_actor_fks.sql` (final-writer discipline); touches the constraint on `paper_ballot_batches.generated_by` only. The `paper_ballots` actor columns are already correct (Wave 6) and are deliberately left untouched.
- **Application code:** none — no RPC or route changes in this change. `generated_by` remains entirely NULL after this change; re-enabling the write (e.g. in `generate_anonymous_blank_ballot_pool`) is a separate future change requiring its own review.
- **Docs:** `docs/TECHNICAL_GUIDE.md` canonical migration run order; CHANGELOG entry on release.
- **Anonymity posture:** unchanged or better — the column remains NULL; repointing to `admin_sessions` removes the theoretical member-id-collision path and aligns with the severed-plane design (attribution vs identity stay distinct).
- **Session purge interplay:** `ON DELETE RESTRICT` means an expired admin session referenced by `generated_by` could no longer be purge-deleted. Acceptable: the column is unwritten today, and the existing precedent (`vote_audit_log.admin_id`, Wave 6 `paper_ballots` actor columns) already chose RESTRICT for attribution integrity.
