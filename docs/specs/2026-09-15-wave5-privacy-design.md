# Spec — Wave 5: GDPR Privacy Subsystem

Status: DRAFT (design gate — awaiting user approval before `writing-plans`)
Branch: `agent/wave5-privacy-design`
Date: 2026-09-15
Inputs:
- Brainstorming pass — 5 gating decisions locked with user (see §2).
- `@council` review of decision (e) (session `ses_f5a506929ffefeuY6WWUaQaN9o`) — verdict **REJECT-AND-REPLACE** (2 of 3 responders, unanimous among responders).
- `@oracle` schema + enforcement design (session `ses_f5a452425ffeG2i74rWtpPCUMs`) — source-grounded; all structural claims below trace to its verified reads.
- Three follow-up sub-decisions resolved with user: anonymize `member_code` (yes); retire `scripts/dispatch-tokens.js` (yes); governance-ledger substrate = **Option A (in-DB, never-truncated)**.

---

## 1. Goal

Add a privacy/eligibility subsystem to the (single-election, single-tenant, disposable-reuse)
anonymous election system, covering three scope items:

1. **Configurable voter eligibility** — a general `voting_eligible` gate (age as first reason
   code), enforced on **both** digital and paper channels.
2. **PII retention/purge** — an admin-triggered, audited two-stage roster-PII purge.
3. **Governed data lifecycle** — forbid-by-design raw export; a wipe-surviving governance
   ledger; and an extended definition of "wipe/erasure" covering filesystem, object storage,
   and backups.

Scope items 2 and 3 also close **two pre-existing defects** surfaced by council, folded into
this wave by user direction (see §7).

## 2. Locked decisions (gate — do not revisit without user sign-off)

| # | Decision | Resolution |
|---|----------|------------|
| a | Default stance for UNDETERMINED eligibility before VOTING | **Ineligible (fail-closed)**, exposed as a **configurable** setting (`undetermined_eligibility_defaults_ineligible`, default `TRUE`). |
| b | General override vs age-specific | **General** `voting_eligible` bool + **reason codes** + `eligibility_source`. Age is the first populated reason. |
| c | Channels | **Both** — enforced at digital dispatch AND paper issuance (and, defense-in-depth, at vote cast). |
| d | Raw DOB vs derived boolean | **Derived boolean only** — compute `is_age_eligible` in memory at import; **never persist DOB**. |
| e | Raw export/retention policy | **REJECT-AND-REPLACE / forbid-by-design** — no app code path to export/retain raw identity/linkage data past `VOTING_CLOSED`. App keeps only the anonymous aggregate export. |

### 2.1 Sub-decisions
- **`member_code` anonymization:** YES — Stage-2 purge anonymizes `member_code` in addition to
  `full_name` (both are real-person identifiers). Purge is a terminal-phase action; no
  incremental voter-facing UX impact (see §9).
- **`scripts/dispatch-tokens.js`:** RETIRE — the admin route + DB trigger backstop become the
  single canonical digital-dispatch path. Remove the script, its AGENTS.md Commands-table row,
  and any doc references.
- **Governance-ledger substrate:** **Option A** — in-DB, never-truncated `governance` schema
  table. Record shape designed so a later upgrade to out-of-DB WORM (Option B) is additive.

## 3. Threat model (authoritative)

- **Admin is trusted for correctness; NOT trusted to be the immutability root.** Adversary set:
  the PUBLIC, OTHER VOTERS, and a **holder of the `SUPABASE_SERVICE_ROLE_KEY`** who could
  `pg_dump`/dashboard-export or drop guards. The service role **bypasses RLS by design**
  (`lib/supabase-server.ts:10-16`), so eligibility and purge guarantees CANNOT rely on RLS —
  they live in `SECURITY DEFINER` RPCs plus DB triggers.
- **Deanonymization topology (council, source-verified):** `tokens.member_id` is the *weakest*
  linkage (participation only). The *stronger* vectors are single-table:
  `paper_ballots(ballot_id, member_id, candidate_id)` (`schema.sql:97-108`) and
  `vote_audit_log(member_id, ballot_id, candidate_id, details)` (`schema.sql:119-128`) each
  carry the full **member → ballot → choice** triple; `ballots.ballot_id` is the same HMAC
  value as `paper_ballots.ballot_id` (`schema.sql:98`). Therefore raw retention/export is
  governed as **one linkage bundle**, never a per-column toggle — and is forbidden in-app.
- The one hard anonymity guarantee: **no anonymous-domain row may become linkable to the member
  who cast it.** The disposable wipe is what makes this hold; anything that survives the wipe
  must carry **no voter linkage**.

## 4. Scope item 2 — Configurable voter eligibility

### 4.1 Schema — `election_settings` (single row `id=1`)

```sql
ALTER TABLE election_settings
  ADD COLUMN IF NOT EXISTS age_requirement_enabled BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS minimum_voting_age SMALLINT,
  ADD COLUMN IF NOT EXISTS undetermined_eligibility_defaults_ineligible BOOLEAN NOT NULL DEFAULT TRUE,
  ADD CONSTRAINT election_settings_minimum_voting_age_check
    CHECK (minimum_voting_age IS NULL OR minimum_voting_age BETWEEN 0 AND 130),
  ADD CONSTRAINT election_settings_age_requirement_config_check
    CHECK (age_requirement_enabled = FALSE OR minimum_voting_age IS NOT NULL);
```

### 4.2 Schema — `members`

```sql
ALTER TABLE members
  ADD COLUMN IF NOT EXISTS voting_eligible   BOOLEAN NOT NULL DEFAULT TRUE,
  ADD COLUMN IF NOT EXISTS eligibility_reason TEXT   NOT NULL DEFAULT 'ELIGIBLE',
  ADD COLUMN IF NOT EXISTS eligibility_source TEXT   NOT NULL DEFAULT 'SYSTEM_DEFAULT',
  ADD COLUMN IF NOT EXISTS is_age_eligible   BOOLEAN,             -- nullable: NULL = not assessed
  ADD COLUMN IF NOT EXISTS has_voted         BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE members
  ADD CONSTRAINT members_eligibility_reason_check CHECK (eligibility_reason IN (
    'ELIGIBLE','AGE_UNDER_MIN','NOT_A_MEMBER','MANUAL_ADMIN_HOLD',
    'UNDETERMINED','INACTIVE_MEMBER','PURGED')),
  ADD CONSTRAINT members_eligibility_source_check CHECK (eligibility_source IN (
    'SYSTEM_DEFAULT','CSV_IMPORT','ADMIN_ADJUDICATION','SYSTEM_RECOMPUTE','PURGE')),
  ADD CONSTRAINT members_eligibility_consistency_check CHECK (
    (voting_eligible = TRUE  AND eligibility_reason  = 'ELIGIBLE') OR
    (voting_eligible = FALSE AND eligibility_reason <> 'ELIGIBLE'));
```

- **Reason codes as `TEXT` + `CHECK`** (not a Postgres enum, not a lookup table): smallest
  migration-owned vocabulary, no join in the hot-path gate, easy to evolve.
- **`has_voted`** is required by the purge (§5): today vote state lives only in linked
  `tokens`/`paper_ballots`; the purge must preserve a voted-flag on the durable member shell.

### 4.3 `eligibility_adjudications` (election-scoped, wiped with the election)

Append-only during an election; member-linked (this is NOT the wipe-surviving ledger). FK
`admin_id → admin_sessions(id) ON DELETE RESTRICT` (matches `migration_fix_admin_id_fk.sql:49-60`).
Records old/new (`voting_eligible`, `eligibility_reason`, `eligibility_source`, `is_age_eligible`)
+ note + `created_at`. Added to the `seed.sql` TRUNCATE list (§6.3).

### 4.4 Import / adjudication without DOB persistence (decision d)

`members-import` (`app/api/admin/members-import/route.ts`) is extended to accept a transient
`dob`/`date_of_birth` column, parse it **in memory only**, compute `is_age_eligible` against
`minimum_voting_age`, and persist **only** the booleans/codes — never a DOB column, log, error,
or archive. Age reference date = `election_settings.voting_start::date`. Policy:

| Condition | `is_age_eligible` | `voting_eligible` | `eligibility_reason` |
|-----------|:---:|:---:|---|
| age disabled | `NULL` | `TRUE` | `ELIGIBLE` |
| age ≥ min | `TRUE` | `TRUE` | `ELIGIBLE` |
| age < min | `FALSE` | `FALSE` | `AGE_UNDER_MIN` |
| DOB missing/invalid, default=ineligible | `NULL` | `FALSE` | `UNDETERMINED` |
| DOB missing/invalid, default=eligible | `NULL` | `TRUE` | `ELIGIBLE` |

If `age_requirement_enabled` and `voting_start` is null, reject import/adjudication unless the
admin supplies a one-time as-of date (not persisted).

### 4.5 Enforcement — defense-in-depth, both channels (decision c)

Route pre-check (nice errors) **+** DB backstop (survives service-role scripts / `CREATE OR
REPLACE` regressions). Gate points:

1. **Digital dispatch** — `app/api/admin/tokens-dispatch/route.ts` requires `voting_eligible`
   for `type='VOTING'`; **plus** a `BEFORE INSERT ON tokens` trigger rejecting a VOTING token
   for an ineligible/inactive member. (This trigger is what lets us retire the standalone
   dispatch script — §2.1.)
2. **Digital vote cast** — add an eligibility re-check inside `private.submit_anonymous_vote`
   after token lookup (catches a token issued *before* a later admin hold).
3. **Paper issuance (Model A)** — `private.issue_paper_ballot`.
4. **Preprinted / mobile assign** — `private.issue_preprinted_paper_ballot`
   (via `app/api/admin/paper-assign/route.ts`).

**Caller failure contract** (admin APIs): `{ error, code:"VOTER_INELIGIBLE", eligibilityReason,
eligibilitySource }`. Bulk dispatch keeps its count shape + adds `eligibilityFailed` and a
structured `failures[]`. Dashboard/mobile receive **data only** (`votingEligible`,
`eligibilityReason`, `eligibilitySource`, `isAgeEligible`) — visuals are @designer-owned. Do NOT
overload the existing `votingStatus` channel-state field to mean legal eligibility.

## 5. Scope item 1 — PII purge

Service-role-only RPC `private.purge_roster_pii(p_admin_id, p_stage, p_confirm)` + public
wrapper (granted service_role only). Never hard-deletes members (CASCADE FKs on
`tokens.member_id`, `paper_ballots.member_id` — `schema.sql:48-57`, `97-108`).

- **Stage 1 — contact purge @ `VOTING_CLOSED`/`COMPLETED`:** null `email`+`phone`; set
  `has_voted` from used VOTING tokens ∪ VOTED paper ballots. Idempotent.
- **Stage 2 — identity anonymization after ~30-day dispute window** (`voting_end`+30d):
  set `full_name = 'Redacted member <id8>'`, `member_code = 'PURGED-<id12>'`, null contacts,
  `is_age_eligible = NULL`, `voting_eligible = FALSE`, `eligibility_reason = 'PURGED'`,
  `eligibility_source = 'PURGE'`. Keeps member shell + `has_voted` only.
- **Audit:** voter-linked event to `vote_audit_log` only while within the election/dispute
  window; a **non-linkage summary** (stage, actor label, counts, phase, timestamp — no ids/PII)
  to the governance ledger (§7).

## 6. Scope item 3 — Forbid-by-design raw export

- **No app route, script, button, scheduled job, or "download raw archive" feature** exports or
  retains raw `members`/`tokens`/`paper_ballots`/`paper_ballot_batches`/`vote_audit_log`/
  `admin_sessions` (or `ballots` joined with any) past `VOTING_CLOSED`. The shipped aggregate
  export (`scripts/export-results.js`) remains the ONLY export path.
- **Legally-compelled raw preservation** is an **exceptional out-of-band manual DBA action**
  (pg_dump / dashboard), on written controller instruction under documented legal process,
  encrypted, time-limited, controller-owned artifact + controller-owned erasure — logged only as
  a **non-linkage** governance-ledger event. This is documentation, not a feature.
- Rationale: an in-app gated button's only advantage (audit trail) is illusory against the
  service-key holder who would abuse it, while its existence downgrades a deterministic
  `TRUNCATE`-based erasure guarantee into a procedure-dependent one.

## 7. Folded pre-existing defects

### 7.1 Defect #1 — governance/RoPA record does not survive the wipe
`vote_audit_log` (the only accountability record today) is TRUNCATEd by `seed.sql` (TRUNCATE
bypasses the append-only row triggers). **Fix — Option A:** new `governance.processing_activity_ledger`:

```sql
CREATE SCHEMA IF NOT EXISTS governance;
CREATE TABLE governance.processing_activity_ledger (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  event_type TEXT NOT NULL,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  actor_admin_id UUID,           -- NO FK (admin_sessions is wiped); label only
  actor_label TEXT,
  controller_name TEXT, organization_ref TEXT, processing_purpose TEXT,
  lawful_basis TEXT, data_categories TEXT[], data_subject_categories TEXT[],
  retention_policy TEXT,
  event_summary JSONB NOT NULL DEFAULT '{}'::jsonb,
  previous_hash CHAR(64), record_hash CHAR(64) NOT NULL,
  CONSTRAINT governance_no_voter_linkage CHECK (
    event_summary::text !~* '(member_id|memberId|ballot_id|ballotId|token|email|phone|full_name|member_code)')
);
```

- **Never-truncated:** excluded from `seed.sql`; protected by `UPDATE`/`DELETE`/**`TRUNCATE`**
  triggers (statement-level TRUNCATE trigger rejects truncation); hash-chained; **no FK** to any
  wiped/election-scoped table; **no voter linkage** (CHECK).
- **Records (summaries only):** `ROPA_DECLARED`, `ELIGIBILITY_POLICY_CONFIGURED`,
  `ROSTER_IMPORTED_SUMMARY`, `ELIGIBILITY_ADJUDICATION_SUMMARY`, `TOKENS_DISPATCHED_SUMMARY`,
  `CONTACT_PII_PURGED`, `IDENTITY_PII_ANONYMIZED`, `AGGREGATE_RESULTS_EXPORTED`, `WIPE_STARTED`,
  `WIPE_COMPLETED`, `RAW_RETENTION_OUT_OF_BAND_DECLARED`.
- Record shape is WORM-export-ready so upgrading to Option B later is additive.

### 7.2 Defect #2 — wipe is DB-only; artifacts survive
`seed.sql` truncates DB tables only. **Extend the "wipe/erasure" definition** (mostly runbook,
minimal code):
- **Filesystem `archives/`** (`export-results.js:102`): write aggregate exports under
  `archives/<election-run-id>/`, log SHA-256 to the ledger; before reusing the deployment for a
  different org, move or delete prior-org archives. **No raw exports are ever written.**
- **Object storage:** if used, wipe runbook deletes the election/org bucket/prefix.
- **Supabase PITR/backups:** **app code cannot surgically erase these** — erasure completes at
  retention expiry or by project destruction. Record purge timestamp + retention setting +
  expected expiry + operator confirmation in the ledger. Do not pretend code erases backups.

## 8. Migrations & sequencing

Append to the CANONICAL run order (`docs/TECHNICAL_GUIDE.md`) after current item 29:

30. `migration_wave5_governance_ledger.sql` — `governance` schema, ledger, hash-chain helpers,
    append-only + anti-TRUNCATE triggers, grants. No FKs to election-scoped tables.
31. `migration_wave5_eligibility_schema.sql` — `election_settings` + `members` columns,
    `eligibility_adjudications`, constraints, indexes, append-only guard.
32. `migration_wave5_eligibility_enforcement.sql` — **must be the FINAL writer** for
    `private.submit_anonymous_vote`, `private.issue_paper_ballot`,
    `private.issue_preprinted_paper_ballot`, changed public wrappers, the VOTING-token insert
    backstop trigger, and `purge_roster_pii`.

**Hazards:** (a) enforcement migration must run after the current final paper-ballot writer or a
later `CREATE OR REPLACE` silently drops the eligibility checks; (b) changing an RPC's return
columns may need `DROP FUNCTION` + recreate; (c) any new member-linked table must be in the
TRUNCATE list before the `DELETE FROM members`.

### 8.3 `seed.sql` update

Add `eligibility_adjudications` to the TRUNCATE list (11 tables). **Do NOT** add
`governance.processing_activity_ledger`.

## 9. UX surface (for the @designer lane, later)

- **New:** a conditional **"Voter Eligibility"** adjudication tab (only when
  `age_requirement_enabled`), and a **"Purge roster PII"** admin control with confirmation. Both
  are @designer-owned; dashboard is a do-not-flatten page.
- **No incremental voter-facing UX:** `/verify` and `/vote/[token]` key off ballot_id/token, not
  `member_code`; purge is terminal-phase and admin-only. Post-purge roster rows simply render the
  synthetic `Redacted member …` / `PURGED-…` values.

## 10. Route order for build (post-approval)

`writing-plans` → `@oracle` already consulted (design) → `@designer` (eligibility tab + purge
control) → `@fixer` (migrations, RPC/route wiring, import/dispatch changes, script retirement) →
DB-function UAT (orchestrator, rolled-back harness) + `@verifier` (build/lint) + Playwright UAT.

## 11. Open items to resolve during `writing-plans`
- Exact dispute-window constant (30 days assumed) — confirm with user/policy.
- Whether NOMINATION-token dispatch is ever gated by `voting_eligible` (default: NO — voting only).
- Hash-chain helper detail for the governance ledger (per-row `record_hash` inputs).
