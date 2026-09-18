# Paper-Severance App-Layer Reconciliation

**Status:** DRAFT — awaiting user approval before ANY implementation
**Date:** 2026-09-18
**Trigger:** v0.13.0 regression — admin member search 500s (`42703 column "ballot_id" does not exist`); investigation revealed the v0.13.0 internal Wave 6/7 paper/digital severance migrations restructured the DB but the app layer (API routes + dashboard UI) was never reconciled.
**Branch (at implementation time):** `agent/paper-severance-reconciliation` off `main` (NOT the parked `agent/f14-csp-tier1`).
**Reviewers:** @oracle designed this (ses ora-1); @oracle should also review the Phase-2 diff for residual anonymity leaks.

## Anonymity guardrail (acceptance gate for EVERY task here)

Invariant (`supabase/migration_wave6_paper_severance.sql:5-8`): *no durable row, audit row, RPC argument set, or RPC return set may co-locate `member_id` with `ballots.ballot_id` or `candidate_id`.*

- **NEVER** re-add `ballot_id`/QR to any `member_id`-keyed query, response, RPC arg, or UI state. Re-adding the dropped columns is the wrong fix.
- A member-keyed response may carry identity-plane data ONLY: `status`, `short_code`, check-in timestamps.
- Anonymous ballot artifacts (`ballot_id`, QR) live ONLY in member-blind flows (anonymous blank pool, scan-by-ballot).
- **Test-against-known-bad:** after the fix, grep must show zero `paper_ballots` selects of `ballot_id`; and any endpoint returning a member row must be asserted (test/manual) to contain no `ballotId`/`qrDataUrl`.

## Runtime-confirmed status (live pg_catalog probe, 2026-09-18)

`private` implementations are authoritative. `paper-vote` is the only fully-working paper route.

| Route | RPC/query | Status |
|---|---|---|
| `members` | direct select | BROKEN hard (42703) |
| `paper-batch` | `generate_blank_paper_ballot_batch` | BROKEN hard (superseded, raises) |
| `paper-ballot` | `issue_paper_ballot` | DB fn CORRECT-by-severance (returns identity slip `short_code`, no `ballot_id`); stale APP contract expects `ballotId`/QR — app is the bug |
| `paper-assign` | `issue_preprinted_paper_ballot` | BROKEN soft (superseded stub) + forbidden arg co-location |
| `paper-invalid` | `spoil_paper_ballot`,`submit_paper_invalid` | BROKEN soft (superseded stubs) |
| `paper-void-unused` | `void_unused_paper_ballots` | FUNCTIONS; batch arg ignored (global void) — copy stale |
| `paper-vote` | `submit_paper_vote` | OK |

---

## Design decision — Option A (identity-slip model) — user-confirmed 2026-09-18

Verified live this session (Supabase MCP `pg_get_functiondef` + schema): the severed system uses **two separate physical artifacts, never joined by any RPC**:

- **Identity slip** = `paper_ballots.short_code` (member-bound; `paper_ballots` has NO `ballot_id`).
- **Anonymous ballot** = `anonymous_paper_blanks.ballot_id` (the QR; has NO `short_code`, NO `member_id`).
- `check_in_paper_voter(p_short_code, p_member_id, …)` binds the member to a `paper_ballots` row and **never touches `anonymous_paper_blanks`/`ballot_id`**. `generate_anonymous_blank_ballot_pool` writes `ballot_id`-only. `issue_paper_ballot(p_member_id)` generates a `short_code` + calls `check_in_paper_voter`, returning the **identity slip**, not a ballot QR.

**Decision:** adopt **Option A** — the admin/member context shows the **identity-slip `short_code` only**; the anonymous ballot QR appears **only** on the physical pool sheet, never re-rendered digitally next to a member. Rejected Option B (re-showing a pool QR in member context) as an unnecessary visual co-location surface.

**Both required workflows are supported under A:**
1. **Pre-printed anonymous ballots** (primary) — batch from `generate_anonymous_blank_ballot_pool`, no member link.
2. **Per-member "issue a paper ballot to member X"** — `issue_paper_ballot(p_member_id)` issues an identity slip + checks the member in. Valid and clean.

Consequence for Phase 2B: the `paper-ballot` route surfaces `short_code` (identity slip), NOT a ballot QR — the DB fn is already correct.

---

## Phase 1 — Unblock member search (highest priority; restores the mobile workflow)

Lanes: @fixer (backend), @designer (member-row UI), @verifier (build). @oracle review optional (small, well-specified).

### 1A. `app/api/admin/members/route.ts` (@fixer)
- [ ] Replace the `paper_ballots` projection (`:68`) with identity-plane only: `status, short_code, checked_in_at, checked_in_date` (+ optionally `spoiled_at, voided_at, invalid_reason, void_reason` if the row needs desk-resolution history).
- [ ] Remove the `QRCode` import (`:2`) and the entire `paperBallotObj` QR/ballotId block (`:90-121`). Emit reduced object — **rename `paperBallot` → `paperCheckIn`** with `{ shortCode, status, checkedInAt, checkedInDate }` so no future code assumes a ballot QR exists.
- [ ] Fix `votingStatus` derivation:
  - [ ] `DIGITAL_VOTED` ONLY when the used token is digital — gate on `channel_sent === 'DIGITAL'` (paper check-in also sets `tokens.is_used=true` with `channel_sent='PAPER'`, so the current `if (activeVotingToken?.is_used)` misclassifies paper as digital). Select the needed token columns.
  - [ ] `PAPER_VOTED` ONLY from identity-plane `paper_ballots.status='VOTED'`; do NOT infer from `ballots`/anonymous records.
  - [ ] `PAPER_ISSUED` from `status IN ('ISSUED_TO_VOTER','ISSUED')` (checked-in / entitlement consumed).
  - [ ] `DIGITAL_RESERVED` (UI already supports it) from token `reserved_channel='DIGITAL'` while `is_used=false` — add the needed token columns WITHOUT returning credential/hash/ballot handles.
- [ ] Outer `catch {}` (`:143`) → `catch (err: unknown) { console.error('[members/search] GET failed:', err); ... }`; keep client response generic `{ error: 'Server error' }`. No PII (no query string, no names) in the log.

### 1B. `app/admin/dashboard/page.tsx` member-row UI (@designer)
- [ ] Update `Member` type (`:15-30`): drop `paperBallot.ballotId/qrDataUrl/qrSvg`; reflect `paperCheckIn { shortCode, status, checkedInAt }`.
- [ ] Member row (`:2459-2573`): remove the `View QR / Print` button and all `paperBallot.ballotId/qrDataUrl/qrSvg` reads; **relabel** the short code → "Paper check-in code" (not "Ballot").
- [ ] `PAPER_ISSUED` copy: "Paper checked in" + subtext "Anonymous ballot QR is only on the physical ballot."
- [ ] Do NOT open the ballot-QR issued-modal from a member row anymore.
- [ ] Preserve all existing visual/interaction design for the surrounding row; this is a removal + relabel, not a redesign.

### 1C. Verify + UAT
- [ ] @verifier standard (`npm run build`).
- [ ] Push branch for a Vercel preview (ONLY on explicit user go) → user UAT: mobile member search returns results, statuses correct, no QR on member rows, no console/500.

---

## Phase 2 — Reconcile the rest of the paper workflow

Lanes: @fixer (backend routes), @designer (batch UI), @verifier, then @oracle anonymity review of the full diff.

### 2A. `paper-batch/route.ts` + dashboard batch tiles
- [ ] Route: call `generate_anonymous_blank_ballot_pool(p_count)`; read `ballot_ids`; build QR per anonymous `ballot_id`; return `{ generatedCount, ballots:[{ ballotId, qrDataUrl, qrSvg }] }`. Remove the `paper_ballots` select entirely. **No `short_code`** (anonymous blanks have none).
- [ ] Dashboard batch/issued tiles (`:2800+`, `:2987+`): type → `{ ballotId, qrDataUrl?, qrSvg? }`; drop `shortCode`; title "Anonymous Blank #{n}" (or last-8 of ballotId). QR/full ballotId OK here (member-blind, not paired with identity).

### 2B. `paper-ballot/route.ts`
- [ ] `issue_paper_ballot` now returns identity-only. Stop expecting `res.ballot_id`; stop generating a verify QR. Return identity-slip/check-in confirmation `{ memberName, memberCode, shortCode, participationDate, status }`.

### 2C. `paper-assign/route.ts`
- [ ] Retire the forbidden `p_ballot_id`+`p_member_id` co-location call. Under Option A the per-member desk flow is `issue_paper_ballot(p_member_id)` (or `check_in_paper_voter(p_short_code, p_member_id)` for pre-printed identity slips) for identity; anonymous blanks come from the pool separately — there is no "matched pair" to assign. Verified live: no RPC pairs `short_code`↔`ballot_id`. Likely **deprecate/remove** `paper-assign` + its `mobile-assign` UI. **@oracle to confirm deprecate-vs-repurpose before coding.**

### 2D. `paper-invalid/route.ts`
- [ ] Split per severed model: spoil/check-in by `short_code` → `spoil_paper_check_in(p_short_code, …)`; void anonymous blank by scanned `ballot_id` → `void_anonymous_paper_blank(p_ballot_id, …)`. Stop calling the superseded `spoil_paper_ballot`/`submit_paper_invalid`.

### 2E. `paper-void-unused/route.ts`
- [ ] Not broken, but semantics changed: `p_batch_id` is ignored (global void). Either wire directly to `void_unused_anonymous_paper_blanks` and update UI copy to "void ALL unused anonymous blanks", or keep the shim and fix the copy. Remove any per-batch promise from the UI.

### 2F. Sweep + review
- [ ] Grep sweep: zero remaining direct `paper_ballots` selects of dropped columns anywhere (app/, scripts/). Fix `scripts/test-paper-vote.js:50,118` or mark obsolete.
- [ ] `mobile-assign/page.tsx` — reconcile with 2C outcome.
- [ ] @oracle reviews the complete Phase-2 diff against the anonymity invariant.
- [ ] @verifier standard; user UAT of the full paper desk flow.

---

## Risks
- **Reintroducing co-location** — mitigated by the guardrail + grep/assert acceptance gate + @oracle Phase-2 review.
- **Behavioral change to admin workflow** — removing member→QR is intentional (it was the leak); Phase 2C may deprecate a whole endpoint. Confirm desk operational flow with user before 2C.
- **Scope creep** — Phase 1 is strictly the search unblock; resist folding Phase 2 into it.

## Rollback
Per-file git revert; no DB/schema changes in this plan (DB is already at the target state — this is app-only reconciliation).

## Definition of done
- All paper routes function against the severed schema; `paper-vote` unchanged.
- Zero member-keyed responses carry `ballot_id`/QR (asserted).
- Dashboard reflects identity-plane member data + anonymous-only batch QR.
- Diagnosability: member-search failures are logged server-side.
- @oracle sign-off on Phase 2 diff.
- CHANGELOG entry; this closes a v0.13.0 regression (patch release, e.g. v0.13.1).
