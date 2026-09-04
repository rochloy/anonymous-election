# Token Reissue (Voting + Nomination) — Implementation Plan (Spec 2)

> **For implementers:** Use the `executing-plans` skill (inline) or have the orchestrator dispatch one `@fixer` per task with review between tasks. Steps use checkbox (`- [ ]`) syntax for tracking. DB tasks are applied via the **Supabase MCP** (`supabase_apply_migration` / `supabase_execute_sql`) because this project has **no direct Postgres URL** — SQL is never run from app code (project AGENTS.md).

**Goal:** A single, shared admin **void-and-reissue** mechanism for both VOTING and NOMINATION tokens, enforcing at most one active token per `(member_id, type)` at the database level, so a lost/never-received magic link can be replaced without ever allowing a double vote or double nomination.

**Architecture:** Reissue is one `SECURITY DEFINER` RPC in the `private` schema that locks the old token, voids it, and mints exactly one replacement — atomic. A DB partial unique index (`is_used = false AND voided_at IS NULL`) is the real invariant; app checks are advisory only. The admin route generates the raw token (to email in cleartext), passes only the `token_hash` to the RPC, and sends one combined email (void notice + new link).

**Tech Stack:** Next.js 16.2.12 (App Router, Turbopack), TypeScript, Supabase/Postgres (RLS + `private` RPCs), Tailwind v4, Resend.

**Branch:** `agent/nomination-submit-flow` (already checked out).

**Spec:** `docs/specs/2026-09-04-token-reissue-design.md` (OpenSpec §12 requirements are the acceptance criteria).

**Depends on:** Spec 1 must ship first. `submit_nomination` (Spec 1 §5 step 4) must already reject `voided_at IS NOT NULL`; the reissue race-safety proof relies on it. The submit-side `voided_at` guard for the VOTING path (`submit_anonymous_vote`) is added by Task 2 here.

---

## Preflight (do once, before Task 1)

- [ ] **P.1 — Read the framework docs.** Project AGENTS.md: "This is NOT the Next.js you know." Before writing any route, read `node_modules/next/dist/docs/` for App Router route handlers.
- [ ] **P.2 — Confirm branch + clean tree.**

Run: `git -C /home/rtaniman/Programs/opencode-projects/anonymous-election status --porcelain && git rev-parse --abbrev-ref HEAD`
Expected: clean tree, branch `agent/nomination-submit-flow`.

- [ ] **P.3 — Confirm Spec 1 landed.** The `submit_nomination` RPC exists and rejects voided tokens; `anonymous_nominations` migration applied.

Run: `grep -rn "submit_nomination" supabase; grep -rn "voided_at" supabase`
Expected: `submit_nomination` present; `voided_at` referenced in the submit guard.

- [ ] **P.4 — Confirm helpers exist:** `app/api/admin/auth.ts` exports `requireAdminWithCsrf`, `getAdminSession`; `lib/audit-log.ts` exports `insertAuditLog`; Resend email helper used by `tokens-dispatch` route is reusable.

Run: `grep -rn "requireAdminWithCsrf\|getAdminSession" app/api/admin/auth.ts; grep -rn "insertAuditLog" lib`
Expected: each found.

---

## Task 1: DB migration — schema columns + single-active-token index

**Files:**
- Create: `supabase/migration_token_reissue.sql`
- Apply via: `supabase_apply_migration` (name: `token_reissue`)

- [ ] **Step 1: Write the schema half.**

```sql
-- migration_token_reissue.sql  (Spec 2) — run AFTER migration_nomination_submission.sql.
ALTER TABLE tokens
  ADD COLUMN IF NOT EXISTS voided_at TIMESTAMPTZ NULL,
  ADD COLUMN IF NOT EXISTS void_reason TEXT NULL,
  ADD COLUMN IF NOT EXISTS reissued_from_token_id UUID NULL REFERENCES tokens(id);

-- DB-enforced single-active-token invariant.
-- NOTE: predicate MUST NOT depend on volatile now()/expires_at (not IMMUTABLE).
-- Expired-but-not-voided tokens still "block" until an issuance/reissue tx voids them.
CREATE UNIQUE INDEX IF NOT EXISTS tokens_one_live_per_member_type
  ON tokens (member_id, type)
  WHERE is_used = FALSE AND voided_at IS NULL;
```

- [ ] **Step 2: Backfill safety check (run BEFORE the index in the same migration, or verify first).** The `CREATE UNIQUE INDEX` fails loudly if any member already holds >1 active token of a type — this is the desired safety gate. Verify with `supabase_execute_sql`:

```sql
SELECT member_id, type, COUNT(*)
FROM tokens
WHERE is_used = FALSE AND voided_at IS NULL
GROUP BY member_id, type
HAVING COUNT(*) > 1;
```
Expected: **zero rows**. If any rows return, resolve duplicates (void the stale ones) before creating the index. Best introduced at the second wipe (Option B backlog) on a clean DB — see spec §4, §10.

**Acceptance:** Spec 2 §12 → *Single Active Token Invariant*.

---

## Task 2: Submit-side voided guard (VOTING path parity)

**Files:**
- Modify: `supabase/migration_token_reissue.sql` (append) — patch `private.submit_anonymous_vote`

- [ ] **Step 1:** In `submit_anonymous_vote` (currently `migration_opaque_ballot_ids.sql`), the token `SELECT ... FOR UPDATE` must also reject `voided_at IS NOT NULL` (Spec 1 already does this for `submit_nomination`; this brings the VOTING path to parity so a reissued VOTING token's old link fails gracefully). Add a `CREATE OR REPLACE FUNCTION private.submit_anonymous_vote(...)` in this migration that reproduces the existing body plus the new guard — **do not** hand-edit the old migration file; supersede via replace.

- [ ] **Step 2:** Re-grant if the replace drops grants: `GRANT EXECUTE ON FUNCTION private.submit_anonymous_vote(...) TO service_role;` (match the existing signature exactly — read it first).

Run (read the current definition before replacing): `grep -n "submit_anonymous_vote" supabase/migration_opaque_ballot_ids.sql`

**Acceptance:** Spec 2 §12 → *Atomic Void-and-Reissue* (old link fails), *Reissue-vs-Submit Race Safety* (reissue-wins-lock scenario) for the VOTING path.

---

## Task 3: RPC `private.reissue_token`

**Files:**
- Modify: `supabase/migration_token_reissue.sql` (append)

- [ ] **Step 1: Write the RPC** per spec §5. Signature:

```sql
CREATE OR REPLACE FUNCTION private.reissue_token(
  p_old_token_id UUID,
  p_admin_id     UUID,
  p_reason       TEXT,
  p_new_token_hash VARCHAR(64)
) RETURNS TABLE (success BOOLEAN, message TEXT)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE v_member_id UUID; v_type TEXT; v_is_used BOOLEAN; v_voided TIMESTAMPTZ; v_expires TIMESTAMPTZ;
BEGIN
  SELECT member_id, type, is_used, voided_at, expires_at
    INTO v_member_id, v_type, v_is_used, v_voided, v_expires
    FROM tokens WHERE id = p_old_token_id FOR UPDATE;
  IF NOT FOUND THEN RETURN QUERY SELECT FALSE, 'Token not found'; RETURN; END IF;
  IF v_is_used THEN RETURN QUERY SELECT FALSE, 'Used token cannot be reissued.'; RETURN; END IF;
  IF v_voided IS NOT NULL THEN RETURN QUERY SELECT FALSE, 'Token already voided.'; RETURN; END IF;

  UPDATE tokens SET voided_at = NOW(), void_reason = p_reason WHERE id = p_old_token_id;

  -- New row inherits type; new expiry per type (VOTING = settings TTL, NOMINATION = 24h).
  INSERT INTO tokens (member_id, token_hash, type, reissued_from_token_id, expires_at)
  VALUES (v_member_id, p_new_token_hash, v_type, p_old_token_id, /* computed expiry */ v_expires);
  -- The partial unique index rejects any racing second insert (unique_violation → clean failure).

  RETURN QUERY SELECT TRUE, 'Reissued';
END; $$;
```

> **Decision note:** the route generates `rawToken`, computes `token_hash`, and passes it in (spec §5 step 6) so the raw token is available to email. Recompute `expires_at` for the *type* rather than copying the old value if the old one was already stale — confirm the exact TTL source (`election_settings.voting_token_ttl_hours` for VOTING; `NOW() + interval '24 hours'` for NOMINATION) against Spec 1 / `migration_configurable_token_ttl.sql`.

- [ ] **Step 2: Grants** (spec §5):

```sql
REVOKE EXECUTE ON FUNCTION private.reissue_token(UUID, UUID, TEXT, VARCHAR) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.reissue_token(UUID, UUID, TEXT, VARCHAR) TO service_role;
```

- [ ] **Step 3: Apply the full migration** via `supabase_apply_migration`.

**Acceptance:** Spec 2 §12 → *Used Token Non-Reissuable*, *Atomic Void-and-Reissue*, *Single Active Token Invariant* (concurrent-reissue scenario), *Reissue Privilege Lockdown* (anon denied).

---

## Task 4: Admin route `POST /api/admin/tokens/reissue`

**Files:**
- Create: `app/api/admin/tokens/reissue/route.ts`
- Reference: `app/api/admin/tokens-dispatch/route.ts` (raw-token gen + `token_hash` + magic-link + Resend send), `app/api/admin/settings/route.ts` (phase read), `app/api/admin/auth.ts`, `lib/audit-log.ts`

- [ ] **Step 1:** Guard with `requireAdminWithCsrf`. Body: `{ tokenId, reason }`. Validate both present; `reason` non-empty.

- [ ] **Step 2: Phase gate (locked, spec §7).** Read `current_phase`. Look up the token's `type`. Reject unless the type's action phase is open: NOMINATION tokens only during `NOMINATION`, VOTING tokens only during `VOTING`. Return a clear error otherwise (no CLOSED-phase reissue path).

- [ ] **Step 3:** Generate `rawToken` (mirror dispatch route's `crypto` gen), compute `token_hash` (sha256), call `private.reissue_token(tokenId, adminId, reason, token_hash)` via the service-role client. If `success = false`, surface the RPC `message`.

- [ ] **Step 4: Single combined email (locked, spec §7 Q5).** On success, send exactly **one** email that (a) states the previous link was voided and (b) contains the new magic link, branching by type: VOTING → `${APP_BASE_URL}/vote/${rawToken}`, NOMINATION → `${APP_BASE_URL}/nominate/${rawToken}` (reuse Spec 1 §6.5 link branch). No separate void-only email.

- [ ] **Step 5: Audit log.** `insertAuditLog({ action: 'ADMIN_ACTION', admin_id, member_id, details: { old_token_id: tokenId, reason } })`. (Identity-domain log — expected; does not touch anonymous rows.)

**Acceptance:** Spec 2 §12 → *Reissue Phase Gate*, *Reissue Notification*, *Reissue Audit Logging*, *Reissue Privilege Lockdown* (CSRF).

---

## Task 5: Admin UI — void & reissue control  → **@designer**

**Files:**
- Modify: `app/admin/dashboard/page.tsx` (per-member token status area)

- [ ] **Step 1:** In the per-member view, show active NOMINATION and/or VOTING token status. A **"Void & reissue"** button appears **only when the token is unused**; used tokens show a disabled state with the reason (spec §8).
- [ ] **Step 2:** Confirmation dialog captures the required `reason` before POSTing to `/api/admin/tokens/reissue` (include CSRF token per existing admin fetch pattern). On success show the new-status; on failure surface the RPC message.
- [ ] **Note for @designer:** match existing dashboard styling/interaction; keep copy plain and factual (orchestrator will review copy after). Pre-existing lint error at `page.tsx:95` (`setMounted`) is **out of scope** — do not touch.

**Acceptance:** Spec 2 §12 → *Used Token Non-Reissuable* (UI affordance), *Reissue Notification* (triggers the one email).

---

## Task 6: Verification

- [ ] **Step 1: Build + typecheck.** Delegate to `@verifier` (tier `standard`): `npm run build`, `npm run lint`. Expected: no new errors (the pre-existing `page.tsx:95` lint error is known/out of scope).

- [ ] **Step 2: DB behavioral checks** (via `supabase_execute_sql`, against a scratch/staging state — NOT the live election mid-phase):
  - Reissue an unused token → old `voided_at` set, new row with `reissued_from_token_id` present. *(Atomic Void-and-Reissue)*
  - Present the old raw token to the submit RPC → rejected on `voided_at`. *(old link stops working)*
  - Attempt reissue of an `is_used = true` token → failure, no new row. *(Used Token Non-Reissuable)*
  - Attempt to insert a second active token for the same `(member_id, type)` directly → `unique_violation`. *(Single Active Token Invariant — the guard-against-bad-input check per AGENTS.md; confirm the index actually rejects.)*
  - Attempt `reissue_token` as anon/authenticated → permission denied. *(Privilege Lockdown)*

- [ ] **Step 3: Phase-gate check.** With `current_phase = 'NOMINATION_CLOSED'`, POST reissue for a NOMINATION token → rejected. *(Reissue Phase Gate)*

- [ ] **Step 4: Map every Spec 2 §12 requirement to a passing check** before declaring done. Any unmet requirement keeps the task in progress.

---

## Post-implementation (orchestrator-gated, not for @fixer)

- [ ] Copy review of the reissue email + dialog wording (orchestrator).
- [ ] Migration ordering: `migration_token_reissue.sql` is appended to the CANONICAL run order in `docs/TECHNICAL_GUIDE.md` **after** the Spec 1 migration; index creation is the go-live verification gate. Best applied at the **second wipe (Option B backlog)** on a clean DB.
- [ ] User review gate → merge `agent/nomination-submit-flow` only after both Spec 1 and Spec 2 land and verify.
