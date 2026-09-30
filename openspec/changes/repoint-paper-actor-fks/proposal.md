# Proposal

## Why

The paper-plane actor columns (`paper_ballots.issued_by` / `recorded_by` / `spoiled_by` / `voided_by`, `paper_ballot_batches.generated_by`) are foreign-keyed to `members(id)` even though the actors are *admins*, whose identity in this system is an `admin_sessions` row. The FK target is simply wrong: an admin's UUID is a session id, not a member id, so passing `p_admin_id` FK-violated and `migration_paper_assign_phase_gate.sql` had to *stop writing* `issued_by` altogether. The result: attribution columns exist but can never be legitimately populated, and the mis-pointed FK is a latent integrity hazard (a member UUID that collides would silently pass). The correct pattern already exists in the codebase — Wave 6 severance declares actor columns as `REFERENCES admin_sessions(id) ON DELETE RESTRICT`.

## What Changes

- New final-writer migration repointing five FK constraints from `members(id)` to `admin_sessions(id) ON DELETE RESTRICT`:
  - `paper_ballots.issued_by`, `.recorded_by`, `.spoiled_by`, `.voided_by`
  - `paper_ballot_batches.generated_by`
- All five columns are NULL today (nothing writes them since the phase-gate fix); the repoint is a constraint change with **zero data migration** (verified as a pre-apply gate).
- Canonical migration run order in `docs/TECHNICAL_GUIDE.md` gains the new migration (item 39, after the wipe RPC; `seed.sql` stays last of the base rebuild).
- NOT in scope: re-enabling RPC writes to the actor columns (admin attribution UX is a separate decision), the `admin_principals` feature, and the two other audit-integrity backlog items (`insert_audit_log` advisory lock, `audit-log.ts` direct-insert fallback) — recorded as follow-ups only.

## Capabilities

### New Capabilities

- `paper-ballot-attribution`: integrity guarantee that paper-plane actor columns reference admin sessions (not members), so admin attribution is *possible* without ever confusing it for voter identity.

### Modified Capabilities

(none — no existing capability specs; first OpenSpec change in this repo)

## Impact

- **Database:** one new migration `supabase/migration_repoint_paper_actor_fks.sql` (final-writer discipline); touches constraints only on `paper_ballots` + `paper_ballot_batches`.
- **Application code:** none — no RPC or route changes in this change. The actor columns remain entirely NULL after this change; re-enabling the writes they exist for (e.g. restoring the `issued_by` write that was stripped by the phase-gate fix) is a separate future change requiring its own review.
- **Docs:** `docs/TECHNICAL_GUIDE.md` canonical migration run order; CHANGELOG entry on release.
- **Anonymity posture:** unchanged or better — actor columns remain NULL; repointing to `admin_sessions` removes the theoretical member-id-collision path and aligns with the severed-plane design (attribution vs identity stay distinct).
- **Session purge interplay:** `ON DELETE RESTRICT` means an expired admin session referenced by an actor column could no longer be purge-deleted. Acceptable: columns are unwritten today, and the existing precedent (`vote_audit_log.admin_id`, Wave 6 blanks) already chose RESTRICT for attribution integrity.
