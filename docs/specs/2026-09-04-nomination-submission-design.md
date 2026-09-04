# Spec 1 — Nomination Submission & Adjudication

Status: DRAFT (design gate — awaiting user approval before `writing-plans`)
Branch: `agent/nomination-submit-flow`
Date: 2026-09-04
Reviewed: `@oracle` verdict APPROVE-WITH-CHANGES (session ses_f94089b5affeX60ActgPUObYf2). All 9 required changes folded in.

---

## 1. Goal

Implement the currently-missing **NOMINATION submission flow**. Today the phase machine
supports `SETUP → NOMINATION → NOMINATION_CLOSED → VOTING …`, NOMINATION tokens are minted
with a hardcoded 24h TTL, but there is **no `/nominate` page/route, no RPC, and
`anonymous_nominations` is only ever `CREATE`d/`TRUNCATE`d — never inserted into**.

This spec covers: token-gated digital nomination submission, admin out-of-band entry,
member typeahead search, and admin adjudication (promote nominees → `candidates`).
Token **reissue** is deferred to Spec 2.

## 2. Threat model (authoritative — unchanged)

- Admin is **TRUSTED**. Adversary = the **PUBLIC** and **OTHER VOTERS/nominators**.
- The one hard guarantee: **a nomination row must never be linkable to the member who
  submitted it** (the nominator). The nominee's identity is *public* by nature (they are
  being proposed as a candidate) — only the *nominator* is protected.
- Writes flow only through `SECURITY DEFINER` RPCs in the `private` schema (not exposed via
  PostgREST). Identity-domain tables (`members`, `tokens`) are RLS-locked from public reads.

## 3. Anonymity model — mirror the vote RPC

`private.submit_nomination` MUST copy the transactional pattern of
`private.submit_anonymous_vote`
(`supabase/migration_opaque_ballot_ids.sql:204-263`): read phase → `SELECT … FOR UPDATE`
the token row → validate expiry/used → insert **anonymous-domain facts only** → mark token
used, all in one transaction. `member_id` is read **only** to validate the token; it is
never inserted into, returned from, or logged alongside `anonymous_nominations`. This is the
identical property the vote path already proves
(`migration_opaque_ballot_ids.sql:211-249` — ballot row carries no `member_id`).

---

## 4. Schema changes

### 4.1 `anonymous_nominations` (currently `schema.sql:50-55`)

```sql
ALTER TABLE anonymous_nominations
  ADD COLUMN nominee_member_id UUID REFERENCES members(id) NULL,  -- matched=NOT NULL, write-in=NULL
  ADD COLUMN source TEXT NOT NULL DEFAULT 'DIGITAL'
    CHECK (source IN ('DIGITAL','ADMIN'));
-- existing cols kept: id, nominee_name VARCHAR(100), reason TEXT, submitted_date DATE
```

- `submitted_date` stays **DATE** (coarse — no high-resolution timestamp on the row, so no
  fine-grained correlation surface). Do NOT add `created_at TIMESTAMPTZ` to this table.
- `nominee_member_id` identifies the **nominee** (public), never the nominator. Not a leak.

### 4.2 RLS on `anonymous_nominations` — **[Oracle req #1]**

Base schema enables RLS on `members/tokens/election_settings/candidates/ballots/paper_ballots/vote_audit_log`
(`schema.sql:120-126`) but **not** on `anonymous_nominations`. Close this:

```sql
ALTER TABLE anonymous_nominations ENABLE ROW LEVEL SECURITY;
-- No public SELECT policy. Admin reads go through service_role server routes only.
GRANT SELECT, INSERT ON anonymous_nominations TO service_role;
```

### 4.3 DB-enforced immutability — **[Oracle req #8]**

Rows are append-only. Enforce with a trigger, not convention:

```sql
CREATE OR REPLACE FUNCTION private.reject_nomination_mutation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'anonymous_nominations rows are immutable (append-only).';
END; $$;

CREATE TRIGGER trg_nominations_immutable
  BEFORE UPDATE OR DELETE ON anonymous_nominations
  FOR EACH ROW EXECUTE FUNCTION private.reject_nomination_mutation();
```

Admin adjudication NEVER mutates these rows — decisions live in `nomination_adjudications`
(§4.5) and in the created `candidates` rows.

### 4.4 `election_settings` config

```sql
ALTER TABLE election_settings
  ADD COLUMN allow_write_ins BOOLEAN NOT NULL DEFAULT TRUE,
  ADD COLUMN max_nominees_per_member SMALLINT NOT NULL DEFAULT 1
    CHECK (max_nominees_per_member BETWEEN 1 AND 3);
```

### 4.5 `nomination_adjudications` (admin-only audit) — **[Oracle req #9]**

Records candidate-promotion decisions. Links decisions to nomination rows and admins — never
to nominators. Provides idempotence + provenance for the election.

```sql
CREATE TABLE nomination_adjudications (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  admin_id UUID REFERENCES members(id),
  decision TEXT NOT NULL CHECK (decision IN ('PROMOTE','MERGE','DISCARD')),
  candidate_id UUID REFERENCES candidates(id),       -- set on PROMOTE/MERGE
  nominee_member_id UUID REFERENCES members(id),     -- for matched groups
  affected_nomination_ids UUID[] NOT NULL DEFAULT '{}',
  note TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE nomination_adjudications ENABLE ROW LEVEL SECURITY;  -- admin/service_role only
GRANT SELECT, INSERT ON nomination_adjudications TO service_role;

-- Idempotent promotion: at most one PROMOTE candidate per matched nominee.
CREATE UNIQUE INDEX idx_adjudication_one_promote_per_nominee
  ON nomination_adjudications (nominee_member_id)
  WHERE decision = 'PROMOTE' AND nominee_member_id IS NOT NULL;
```

### 4.6 Extensions

```sql
CREATE EXTENSION IF NOT EXISTS pg_trgm;  -- Supabase installs into `extensions` schema
```

All new RPCs use `SET search_path = public, private, extensions` (matches existing pattern,
`schema.sql:148`, `migration_opaque_ballot_ids.sql:188`) so `similarity()` resolves.

---

## 5. RPC `private.submit_nomination` — **[Oracle req #4, #5]**

Signature (single-shot 1…N nominees, one token consumption — Decision 5):

```sql
private.submit_nomination(
  p_token_hash VARCHAR(64),
  p_nominees   JSONB   -- array of {nominee_member_id: uuid|null, nominee_name: text, reason: text}
) RETURNS TABLE (success BOOLEAN, message TEXT, inserted_count INT)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, private, extensions
```

**In one transaction, in this order** (mirrors vote RPC):

1. `SELECT current_phase, nomination_start, nomination_end INTO … FROM election_settings WHERE id=1;`
2. Require `current_phase = 'NOMINATION'`; if `nomination_start/end` set, require `NOW()` within window.
3. Read `allow_write_ins`, `max_nominees_per_member` from settings.
4. `SELECT id, member_id, is_used, expires_at, voided_at INTO … FROM tokens
   WHERE token_hash = p_token_hash AND type = 'NOMINATION' FOR UPDATE;`
   - reject if not found / `is_used` / expired (`expires_at <= NOW()`) / **`voided_at IS NOT NULL`** (Spec 2 column; guard now).
5. Parse `p_nominees`; enforce `array_length ≤ max_nominees_per_member`; de-dupe within submission
   (by `nominee_member_id` for matched, normalized `nominee_name` for write-ins).
6. **Canonicalize matched nominees [req #5]:** for each element with `nominee_member_id NOT NULL`,
   look up `members` (must exist AND `is_active`); **overwrite** `nominee_name` from
   `members.full_name` — ignore client-supplied name. Reject if member missing/inactive.
7. If `allow_write_ins = FALSE`, reject any element with `nominee_member_id IS NULL`.
8. Validate lengths: `nominee_name ≤ 100` (col is `VARCHAR(100)`, `schema.sql:52`), `reason ≤ 2000` (locked).
9. `INSERT` N rows `(nominee_member_id, nominee_name, reason, source='DIGITAL')` — **no nominator identity**.
10. `UPDATE tokens SET is_used = TRUE, used_at = NOW() WHERE id = v_token_id;`
11. Return `(TRUE, 'Nomination submitted.', N)`.

**Grants — [Oracle req #3]** (do not rely on defaults; match
`migration_lock_public_vote_wrappers.sql` pattern):

```sql
REVOKE EXECUTE ON FUNCTION private.submit_nomination(VARCHAR, JSONB) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.submit_nomination(VARCHAR, JSONB) TO service_role;
```

Same REVOKE/GRANT for any `public.*` wrapper if one is added.

---

## 6. Server routes

All routes hash the raw token server-side immediately (`sha256`, as
`app/api/vote/route.ts:30-35`) and call RPCs via the service-role client. **Never log raw
tokens, request bodies, or search queries tied to raw tokens [req #6, #7].**

### 6.1 `POST /api/nominate`
Body `{ rawToken, nominees[] }` → `token_hash` → `private.submit_nomination`. Returns success/count.

### 6.2 `POST /api/nominate/search` — token-gated, non-consuming — **[Oracle req #6]**
Body `{ rawToken, query }`. Validates token **without consuming** (type=NOMINATION, unused,
unexpired, not voided, `current_phase='NOMINATION'`) then returns top ~5 members by
`similarity(full_name, query)`. Controls:
- `query` min length **2**.
- Rate-limit by **both IP and token_hash** (locked, budget dropped): **12 successful searches /
  min per `token_hash`**, **30 requests / min per IP** (rolling; reuse `rate_limit_hits` infra,
  cf. `proxy.ts` 120/min admin baseline). Accepted: this throttles bulk scraping but does not
  hard-cap lifetime enumeration — acceptable given roster is names-only (mild sensitivity).
- Return **only** `{ member_id, full_name }` — no email/phone/member_code.
- UX: search on debounced submit, not every keystroke.

### 6.3 `/nominate/[token]` page
Parallel to `app/vote/[token]/page.tsx`. Typeahead (→ 6.2) with pick=matched / free-text=write-in
(if `allow_write_ins`), reason field, add up to `max_nominees_per_member`, submit (→ 6.1).

### 6.4 Route/page headers — **[Oracle req #7]**
`/vote/[token]` and `/nominate/[token]` set `Referrer-Policy: no-referrer` and
`Cache-Control: no-store` (global policy is `strict-origin-when-cross-origin`,
`next.config.ts:29-31` — tighten these two paths).

### 6.5 Dispatch link fix
`app/api/admin/tokens-dispatch/route.ts` currently links **all** magic links to
`/vote/${rawToken}` even for NOMINATION tokens (~lines 111-130). Branch on `tokenType`:
NOMINATION → `/nominate/${rawToken}`.

### 6.6 Admin settings
Extend `app/api/admin/settings/route.ts` to read/write `allow_write_ins` and
`max_nominees_per_member`.

---

## 7. Admin out-of-band entry (Decision 3)

- Admin "Add nomination" action, allowed **ONLY during `NOMINATION`** phase (not
  `NOMINATION_CLOSED`). Same matched/unmatched UI. Inserts via a **dedicated admin-gated RPC
  `private.admin_add_nomination` (locked — Decision 3, not a no-token variant of
  `submit_nomination`)** with `source = 'ADMIN'`; nominator NOT stored (nominee identity is
  public and admin-supplied). RPC canonicalizes matched `nominee_name` from `members.full_name`
  same as §5 step 6; CSRF-guarded admin route; REVOKE PUBLIC/anon/authenticated + GRANT service_role.
- **Accepted limitation:** `max_nominees_per_member` is enforceable only on the DIGITAL/token
  path; out-of-band count is manual admin discipline (can't link a paper nominee to a member
  without breaking anonymity). Oracle notes a quota-ledger alternative but agrees manual is
  acceptable under the trusted-admin model.

## 8. Admin adjudication (NOMINATION_CLOSED)

Two sections; **nothing auto-promotes** — every candidate is an explicit admin action:
1. **Matched** — grouped by `nominee_member_id` with counts; admin ticks to promote →
   creates a `candidates` row + a `nomination_adjudications` PROMOTE record (idempotent via
   `idx_adjudication_one_promote_per_nominee`).
2. **Unmatched write-ins** — live query `WHERE nominee_member_id IS NULL` over immutable rows
   (not a materialized snapshot — Oracle req #6 confirms this is auditable given immutability +
   separate decision log). Each shows top-3 closest roster members (`pg_trgm`) → Add-as-candidate /
   Merge / Discard, each recorded in `nomination_adjudications`.

## 9. Out of scope (this spec)
- Token **reissue** (void-and-reissue) → **Spec 2**.
- Proxy voting (docs-only, do NOT implement — standing user directive).
- SMS-OTP (deferred).

## 10. Migration ordering note
New migration runs **after** the CANONICAL sequence in `docs/TECHNICAL_GUIDE.md`. `schema.sql`
is NOT idempotent and must never be replayed on the provisioned DB — all changes here ship as a
new `migration_nomination_submission.sql`. Wipe/reseed checklist must also clear
`nomination_adjudications` (and `anonymous_nominations`, already covered by TRUNCATE).

## 11. Open questions for user
_None — all resolved._

RESOLVED: reason max = 2000; out-of-band uses dedicated `private.admin_add_nomination` RPC;
search anti-enumeration = rate-limit only (12/min per token_hash, 30/min per IP), hard budget dropped.

---

## 12. Requirements (OpenSpec delta format)

Normative requirements for this change. Scenarios double as test definitions. Applies against
the current `anonymous-election` capability set.

### Requirement: Nominator Anonymity
The system SHALL NOT persist, return, or log any identifier of the member who submitted a
nomination. `member_id` from the token MAY be read only within the submission transaction to
validate the token.

#### Scenario: No nominator identity on the row
- **GIVEN** a valid NOMINATION token belonging to member M
- **WHEN** `private.submit_nomination` inserts N nomination rows
- **THEN** no inserted `anonymous_nominations` row contains M's `member_id` or any nominator reference
- **AND** the RPC return value contains no nominator identity

#### Scenario: Coarse timestamp only
- **GIVEN** a nomination is submitted
- **THEN** the row records `submitted_date` as a DATE
- **AND** no high-resolution `created_at` timestamp is stored on `anonymous_nominations`

### Requirement: Nomination Phase Gate
The system SHALL accept token-based nominations only when `current_phase = 'NOMINATION'` and,
if configured, within `[nomination_start, nomination_end]`.

#### Scenario: Reject outside NOMINATION phase
- **GIVEN** `current_phase = 'NOMINATION_CLOSED'`
- **WHEN** `submit_nomination` is called with an otherwise-valid token
- **THEN** the RPC returns failure and inserts nothing

### Requirement: Token Single-Use Consumption
The system SHALL consume a NOMINATION token exactly once, in the same transaction as the
insert, and SHALL reject used, expired, or voided tokens.

#### Scenario: Reject already-used token
- **GIVEN** a NOMINATION token with `is_used = true`
- **WHEN** `submit_nomination` is called
- **THEN** the RPC returns failure and inserts nothing

#### Scenario: Reject voided token
- **GIVEN** a NOMINATION token with `voided_at IS NOT NULL`
- **WHEN** `submit_nomination` is called
- **THEN** the RPC returns failure and inserts nothing

### Requirement: Matched Nominee Canonicalization
When a nominee element carries a `nominee_member_id`, the system SHALL verify the member exists
and is active, and SHALL set `nominee_name` from `members.full_name`, ignoring client-supplied name.

#### Scenario: Client name is overridden for matched nominee
- **GIVEN** an input `{ nominee_member_id: Alice.id, nominee_name: "Bob" }`
- **WHEN** `submit_nomination` processes it
- **THEN** the stored `nominee_name` equals Alice's `full_name`

#### Scenario: Reject inactive/nonexistent matched member
- **GIVEN** a `nominee_member_id` that is inactive or missing
- **WHEN** `submit_nomination` processes it
- **THEN** the RPC returns failure and inserts nothing

### Requirement: Write-in Control
The system SHALL reject write-in nominees (`nominee_member_id IS NULL`) when
`election_settings.allow_write_ins = false`.

#### Scenario: Reject write-in when disabled
- **GIVEN** `allow_write_ins = false`
- **WHEN** a nominee with null `nominee_member_id` is submitted
- **THEN** the RPC returns failure and inserts nothing

### Requirement: Per-Submission Nominee Limit
The system SHALL reject a submission whose nominee count exceeds
`election_settings.max_nominees_per_member`, and SHALL de-duplicate nominees within a submission.

#### Scenario: Reject over-limit submission
- **GIVEN** `max_nominees_per_member = 1`
- **WHEN** a submission contains 2 distinct nominees
- **THEN** the RPC returns failure and inserts nothing

### Requirement: Nomination Row Immutability
The system SHALL reject any UPDATE or DELETE on `anonymous_nominations`.

#### Scenario: Block mutation
- **GIVEN** an existing nomination row
- **WHEN** an UPDATE or DELETE is attempted
- **THEN** the database raises an exception and the row is unchanged

### Requirement: Nomination Table Access Control
The system SHALL enable RLS on `anonymous_nominations` with no public SELECT policy; reads occur
only via the service role.

#### Scenario: Public cannot read raw nominations
- **GIVEN** an anonymous/public PostgREST client
- **WHEN** it queries `anonymous_nominations`
- **THEN** no rows are returned

### Requirement: RPC Execution Lockdown
The system SHALL revoke EXECUTE on `private.submit_nomination` and
`private.admin_add_nomination` from PUBLIC, anon, and authenticated, granting only service_role.

#### Scenario: anon cannot execute the RPC
- **GIVEN** the anon role
- **WHEN** it calls `submit_nomination`
- **THEN** execution is denied

### Requirement: Token-Gated Roster Search
The system SHALL validate a non-consuming search request's token (NOMINATION, unused, unexpired,
not voided, phase = NOMINATION), require query length ≥ 2, return only `{ member_id, full_name }`,
and rate-limit by IP and token_hash (12/min per token_hash, 30/min per IP).

#### Scenario: Throttle excessive searches per token
- **GIVEN** a token that has made 12 successful searches in the current minute
- **WHEN** it issues a 13th search
- **THEN** the endpoint returns HTTP 429

#### Scenario: Minimal fields only
- **WHEN** a search returns matches
- **THEN** each result contains only `member_id` and `full_name`

### Requirement: Token URL Leakage Prevention
The `/vote/[token]` and `/nominate/[token]` responses SHALL set `Referrer-Policy: no-referrer`
and `Cache-Control: no-store`, and raw tokens SHALL NOT appear in any log.

#### Scenario: No-referrer on token pages
- **WHEN** `/nominate/<token>` is served
- **THEN** the response carries `Referrer-Policy: no-referrer` and `Cache-Control: no-store`

### Requirement: Admin Out-of-Band Nomination
The system SHALL allow an authenticated admin to add a nomination via
`private.admin_add_nomination` only during the NOMINATION phase, recording `source = 'ADMIN'`
and no nominator identity.

#### Scenario: Reject out-of-band add outside NOMINATION
- **GIVEN** `current_phase = 'NOMINATION_CLOSED'`
- **WHEN** an admin calls `admin_add_nomination`
- **THEN** the call is rejected

### Requirement: Idempotent Candidate Promotion
The system SHALL create at most one PROMOTE candidate per matched `nominee_member_id`, recording
each decision in `nomination_adjudications` without mutating nomination rows.

#### Scenario: Duplicate promotion blocked
- **GIVEN** a matched nominee already promoted to a candidate
- **WHEN** an admin attempts to promote the same `nominee_member_id` again
- **THEN** the unique index rejects the duplicate PROMOTE
