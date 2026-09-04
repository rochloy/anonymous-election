# Spec 2 — Token Reissue (Voting + Nomination)

Status: DRAFT (design gate — awaiting user approval before `writing-plans`)
Branch: `agent/nomination-submit-flow`
Date: 2026-09-04
Reviewed: `@oracle` verdict APPROVE-WITH-CHANGES (session ses_f94089b5affeX60ActgPUObYf2), req #1/#3 (race hardening).
Depends on: Spec 1 (shares the `tokens` guards; `submit_nomination` must reject `voided_at`).

---

## 1. Goal

A single, shared admin **void-and-reissue** mechanism for **both** VOTING and NOMINATION
tokens. Used when a member loses/never-received their magic link and needs a fresh one, without
allowing a double vote / double nomination.

## 2. Invariant (Decision 2)

> **At most one ACTIVE token per member per type.** Only an `is_used = false` token may be
> reissued; reissue **atomically** voids the old token and mints exactly one new one. A USED
> token is **never** reissued. Every reissue is logged (who/when). Stale old links fail gracefully.

Because casting a vote / submitting a nomination consumes the token `is_used=true` in the **same
transaction** as the action (`migration_opaque_ballot_ids.sql:261`; Spec 1 §5 step 10), "not yet
acted" ⟺ "token unused". So there is no window where old + new could each act.

## 3. Why app-level checks are insufficient — **[Oracle req #1]**

Current issuance checks "does an unused token exist?" in application code, then inserts later —
**non-transactional and raceable** (`app/api/admin/tokens-dispatch/route.ts:70-102`). The
`tokens` table only has `UNIQUE(token_hash)` (`schema.sql:39`), nothing enforcing one active
token per `(member_id, type)`. Two concurrent reissues could each mint a live token.

## 4. Schema changes

```sql
ALTER TABLE tokens
  ADD COLUMN voided_at TIMESTAMPTZ NULL,
  ADD COLUMN void_reason TEXT NULL,
  ADD COLUMN reissued_from_token_id UUID NULL REFERENCES tokens(id);

-- DB-enforced single-active-token invariant.
-- NOTE: partial index MUST NOT depend on volatile now()/expires_at (not IMMUTABLE).
-- Expired-but-not-voided tokens still "block" until an issuance/reissue tx voids them.
CREATE UNIQUE INDEX tokens_one_live_per_member_type
  ON tokens (member_id, type)
  WHERE is_used = FALSE AND voided_at IS NULL;
```

This mirrors the existing paper-ballot pattern `idx_paper_ballots_one_active`
(`schema.sql:96-98`).

**Backfill / rollout caveat:** before creating the index on the live DB, verify no member
currently has >1 active token of a type (should hold given current dispatch skip-logic, but
the index creation will fail loudly if violated — that is the desired safety check). This is
also why the second wipe (Option B backlog) is a clean moment to introduce it.

## 5. RPC `private.reissue_token`

```sql
private.reissue_token(
  p_old_token_id UUID,
  p_admin_id     UUID,
  p_reason       TEXT
) RETURNS TABLE (success BOOLEAN, message TEXT, new_token_hash VARCHAR(64))
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, private, extensions
```

**In one transaction:**

1. `SELECT id, member_id, type, is_used, voided_at INTO … FROM tokens
   WHERE id = p_old_token_id FOR UPDATE;`
2. Reject if not found.
3. Reject if `is_used = TRUE` → "Used token cannot be reissued."
4. Reject if `voided_at IS NOT NULL` → "Token already voided."
5. `UPDATE tokens SET voided_at = NOW(), void_reason = p_reason WHERE id = p_old_token_id;`
6. Generate new raw token in the **route** (needs to be emailed in cleartext) — pass its
   `token_hash` in, OR return enough for the route to mint. **Design choice:** the route
   generates `rawToken`, computes `token_hash`, and passes `token_hash` to the RPC, which
   inserts the new row `(member_id, token_hash, type, reissued_from_token_id=p_old_token_id,
   expires_at=…)`. The partial unique index rejects any racing second insert.
7. Return the new `token_hash` (route already holds the raw token to email).

The unique index makes step 6 safe under concurrency: if two reissues race, one insert wins,
the other raises `unique_violation` → RPC returns a clean failure, no double-mint.

**Grants** (match Spec 1 §5):
```sql
REVOKE EXECUTE ON FUNCTION private.reissue_token(UUID, UUID, VARCHAR) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.reissue_token(UUID, UUID, VARCHAR) TO service_role;
```

## 6. Race analysis — **[Oracle req #1, confirmed]**

- **reissue racing submit:** submit locks the token `FOR UPDATE` first → consumes → reissue
  sees `is_used=true` → rejected. OR reissue locks first → voids old + mints new → submit on
  old token sees `voided_at NOT NULL` (Spec 1 §5 step 4) → rejected. No double action.
- **concurrent reissues:** both try to void + insert; the partial unique index
  `tokens_one_live_per_member_type` permits exactly one live row → second insert fails.

## 7. Admin route + logging

- `POST /api/admin/tokens/reissue` (CSRF-guarded via `requireAdminWithCsrf`), body
  `{ tokenId, reason }` → generate rawToken → `token_hash` → `private.reissue_token` →
  email the new magic link (VOTING → `/vote/…`, NOMINATION → `/nominate/…`, reusing Spec 1 §6.5
  branch).
- Log every reissue to `vote_audit_log` (`action='ADMIN_ACTION'`, `admin_id`, `member_id`,
  `details` = `{old_token_id, reason}`). `vote_audit_log` already exists (`schema.sql:104-113`)
  and stores `member_id` — this is the **identity domain**, expected and correct for an admin
  audit trail; it does NOT touch the anonymous nomination/ballot rows.

## 8. UI

Admin dashboard: per-member token status shows an active NOMINATION and/or VOTING token; a
"Void & reissue" button appears only when the token is **unused** (used tokens show a disabled
state with reason). Confirmation dialog captures the reason.

## 9. Out of scope
- Self-service reissue (admin-only by design).
- Changing token TTLs (VOTING configurable, NOMINATION hardcoded 24h — unchanged YAGNI decision).

## 10. Migration ordering note
Ships as `migration_token_reissue.sql` **after** Spec 1's migration. Index creation is the
verification gate (fails if the one-active invariant is already violated). Best introduced at
the second wipe (Option B backlog) on a clean DB.

## 11. Open questions for user
1. Should reissue also be permitted during `NOMINATION_CLOSED`/`VOTING_CLOSED` (e.g. admin
   fixing a mistake), or strictly only while the matching action phase is open? (Leaning:
   allow reissue whenever the token type's action phase is still open; block otherwise.)
2. Notify the member that their old link was voided, or silently send only the new one?
