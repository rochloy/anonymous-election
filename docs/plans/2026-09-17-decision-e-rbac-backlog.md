# Backlog — Decision E: admin role separation + participation/dispute view

**Status:** PARKED 2026-09-17 (user sign-off). NOT built in v0.13.0.
**Source design:** `docs/specs/2026-09-17-v0.13.0-anonymity-design.md` §2 (Decision E row) + §7 (retained design).

## Decision

Decision E (introduce a `dispute-resolution` admin role distinct from general admin,
gate anonymity-sensitive surfaces with `requirePermission()`, and add a data-minimized
participation/dispute view) is **deferred**, not built in the v0.13.0 Security/Anonymity Wave.

### Rationale

- **Not a blocker.** E is a **least-privilege / defense-in-depth** enhancement. It is not one
  of the GDPR council NO-GO findings (F1–F15), and it is not required for the shipped anonymity
  guarantee. The substantive control — identity↔vote linkage severance (Pillars B/C/D) — shipped
  in v0.13.0 and does not depend on E.
- **Vacuous today.** The deployment has a single shared `ADMIN_SECRET` and no differentiated
  admin duties (`app/api/admin/auth.ts:202-208`). RBAC among a single trusted admin principal
  separates nothing. The design's original "multi-admin at launch" premise did not hold.
- **Focus.** Delivery priority is a properly functional, regulatory-compliant, and secure
  application now; E adds compartmentalization that only becomes a real control under a
  multi-admin operating model.

## Why future implementation is mostly additive (minimal rework)

The v0.13.0 architecture was built as forward substrate for E. Picking it up later is largely
additive because the hooks already exist:

1. **`participation_audit` table already landed** (`supabase/migration_wave6_paper_severance.sql:113`)
   with a `participation_audit_no_vote_handles_chk` CHECK constraint (`:125`) — the exact
   data-minimized surface E's participation/dispute view would read and log against, with the
   content firewall (no vote handles) already enforced at the DB layer.
2. **`admin_sessions.admin_id` column already exists** (`supabase/schema.sql:125`) — the identity
   hook is pre-wired (attributes an action to a session today; ready to carry a role/principal).
3. **`requireAdmin()` is a single chokepoint** (`app/api/admin/auth.ts:46-99`) used by every
   admin route — a `requirePermission(<permission>)` wrapper slots in additively; existing
   call sites are unchanged unless they need gating.
4. **Data-minimization severance is already shipped** — the participation view reads existing
   identity-plane columns (`tokens.is_used/used_at/channel_sent`); no new severance work needed.

**The one non-additive caveat:** if future E is scoped as *real separation of duties* (general
admin **loses** participation visibility, which the dashboard shows today), that requires editing
the existing admin dashboard UI — a small, bounded change, not a rewrite. Scoped as
*additive-inspector* (inspector gets a logged, minimized view; general admin unchanged), it is
fully additive.

## Revisit trigger

Build E when the deployment becomes **multi-admin with separated duties** — e.g. a scrutineer /
inspector who must resolve disputes ("did this member already vote?") but must NOT be able to run
PII purge or ballot-keyed correction (or vice-versa).

## Future scope (when picked up) — from §7 retained design

- **DB:** add a `role` column to `admin_sessions` (default `admin`); optional `admin_roles` model;
  a participation-view access-log table (or reuse `participation_audit`).
- **Auth:** distinct inspector credential (surgical: a second shared secret stamped as `role` at
  login — the current model has no per-person accounts); `requirePermission()` wrapper over
  `requireAdmin()`.
- **Permission matrix:** scope RBAC surgically to the three anonymity-sensitive surfaces —
  participation/dispute view, ballot-keyed correction (`app/api/admin/paper-invalid/route.ts`),
  PII purge (`app/api/admin/purge/route.ts`). Not a blanket rewrite.
- **Participation view (behind `dispute-resolution` role):** `member + channel + coarse timestamp`;
  content firewall (never join/display `candidate_id`); no handles (`ballot_id`, `short_code`,
  `batch_id`, `receipt_code`); coarse time both sides; access log (viewer, role, action, row count).
- **Security test (mandatory):** the permission gate must be proven to **refuse** a wrong-role /
  no-role request (known-bad input), per AGENTS.md guard-testing discipline — not only a
  happy-path pass.
