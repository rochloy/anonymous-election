# Technical Guide

## Architecture Overview

Anonymous Election System is a Next.js 16 (App Router) application with Supabase (PostgreSQL) backend. It implements a two-domain architecture:

- **Identity Domain** (`members`, `tokens`): Who is eligible, who has voted
- **Anonymous Domain** (`ballots`, `candidates`): What was voted, receipt codes
- **Paper Ballot Domain** (`paper_ballots`, `vote_audit_log`): Issued ballot tracking + audit

All writes go through `SECURITY DEFINER` RPCs in the `private` schema. Service-role key is server-only (`lib/supabase-server.ts`), never bundled to client.

---

## Project Structure

```
anonymous-election/
├── app/
│   ├── admin/
│   │   ├── dashboard/
│   │   │   └── page.tsx          # Admin dashboard (8 tabs)
│   │   └── phase/
│   │       └── confirm/
│   │           └── page.tsx      # Email confirmation landing page
│   ├── api/
│   │   ├── admin/
│   │   │   ├── auth.ts           # requireAdmin() + requireAdminWithCsrf() + getAdminSession()
│   │   │   ├── login/            # POST /api/admin/login (creates HttpOnly cookie session)
│   │   │   ├── logout/           # POST /api/admin/logout (destroys session)
│   │   │   ├── me/               # GET /api/admin/me (session validation)
│   │   │   ├── candidates/       # CRUD candidates
│   │   │   ├── members/          # Search members
│   │   │   ├── members-import/   # CSV bulk import
│   │   │   ├── members-manage/   # List/activate/deactivate
│   │   │   ├── paper-assign/     # Assign preprinted ballot
│   │   │   ├── paper-ballot/     # Issue paper ballot
│   │   │   ├── paper-batch/      # Generate blank ballots
│   │   │   ├── paper-invalid/    # Spoil ballot
│   │   │   ├── paper-void-unused/# Void unused ballots
│   │   │   ├── paper-vote/       # Record paper vote
│   │   │   ├── phase/            # Phase control (3-level confirmation)
│   │   │   ├── stats/            # Dashboard stats
│   │   │   └── tokens-dispatch/  # Email voting/nomination tokens
│   │   ├── auth/verify-token/    # Token validation (minimal response)
│   │   ├── candidates/           # Public candidate list
│   │   ├── election/status/      # Public phase + schedule
│   │   ├── results/              # Public results
│   │   ├── verify/               # Vote verification
│   │   └── vote/[token]/         # Digital voting UI
│   ├── verify/page.tsx           # Public vote verification
│   └── vote/[token]/page.tsx     # Digital voting
├── lib/
│   ├── supabase-server.ts        # Service-role client singleton
│   ├── api-errors.ts             # Standardized error responses (generic in prod)
│   ├── input-validation.ts       # Length limits, email/phone validation
│   ├── audit-log.ts              # insertAuditLog() with hash chaining
│   └── config-validation.ts      # Module-load config validation
├── proxy.ts                      # Distributed rate limiter via Supabase RPC
├── supabase/
│   ├── schema.sql                # Base schema (tables, RLS, RPCs)
│   ├── seed.sql                  # 4 candidates, 300 members, phase=VOTING
│   ├── migration_paper_ballots.sql
│   ├── migration_public_wrappers.sql
│   ├── migration_fix_gen_random_bytes.sql
│   ├── migration_fix_service_role_grants.sql
│   ├── migration_option_e_paper_ballots_part1.sql
│   ├── migration_option_e_paper_ballots_part2.sql
│   ├── migration_phase_control.sql
│   ├── migration_admin_sessions.sql          # NEW: admin_sessions table
│   ├── migration_rate_limit.sql              # NEW: rate_limit_hits + check_rate_limit()
│   ├── migration_token_expiry.sql            # NEW: tokens.expires_at
│   ├── migration_phase_token_admin.sql       # NEW: phase_change_tokens.admin_session_id
│   └── migration_audit_log_hash_chain.sql    # NEW: audit log hash chaining
└── scripts/
    └── import-members.js
```

---

## Election Phases

### Phase Enum (Ordered)

| Order | Phase | Description | Allowed Next |
|-------|-------|-------------|--------------|
| 1 | `SETUP` | Initial configuration | `NOMINATION` |
| 2 | `NOMINATION` | Candidates can be nominated | `NOMINATION_CLOSED` |
| 3 | `NOMINATION_CLOSED` | Nominations closed, candidates finalized | `VOTING` |
| 4 | `VOTING` | Active voting period | `VOTING_CLOSED` |
| 5 | `VOTING_CLOSED` | Voting ended, tallying | `COMPLETED` |
| 6 | `COMPLETED` | Final results published | *(terminal)* |

**Defined in:** `supabase/schema.sql` (election_phase enum), `app/api/admin/phase/route.ts` (VALID_TRANSITIONS)

### Phase Transitions

**API Layer** (`app/api/admin/phase/route.ts`):
- `VALID_TRANSITIONS` map enforces sequential order
- Three-level confirmation for forward transitions:
  1. Admin clicks "Advance to X" → sends email with confirmation link
  2. Admin clicks email link → hits `/admin/phase/confirm` → calls `action: 'confirm'` with token
  3. OR admin returns to dashboard, types "CONFIRM" → calls `action: 'execute'`
- Reset action (`action: 'request_reset'` → `verify_reset_token` → `execute_reset`) allows `COMPLETED → SETUP` for testing. **This only flips `current_phase` to `SETUP` — it deletes no ballots, tokens, members, or nominations.** The only data wipe is the destructive reseed (see "Election Lifecycle & Reuse" below).
- Legacy direct `action: 'reset'` endpoint **removed** (SEC-02)

**DB Layer** (`supabase/migration_phase_control.sql`):
- Trigger `validate_phase_transition` blocks:
  - `COMPLETED → anything except COMPLETED or SETUP`
  - `VOTING_CLOSED → VOTING` (cannot reopen voting)
- All other transitions allowed at DB level

---

## Election Dates

### Schema Fields (`election_settings` table)

| Column | Type | Purpose |
|--------|------|---------|
| `nomination_start` | TIMESTAMPTZ | Nomination period opens |
| `nomination_end` | TIMESTAMPTZ | Nomination period closes |
| `voting_start` | TIMESTAMPTZ | Voting period opens |
| `voting_end` | TIMESTAMPTZ | Voting period closes |

### Behavior

| Date | Used By |
|------|---------|
| `nomination_start` / `nomination_end` | Display only (admin dashboard, public `/api/election/status`) |
| `voting_start` / `voting_end` | Display only + **vote RPC** (`cast_vote`) checks `voting_end` to reject votes after expiry |

**Critical:** Dates are **informational/display only**. They do **not** automatically advance phases. Phase transitions require manual admin action via the dashboard.

The vote RPC (`private.cast_vote`) checks `voting_end` and rejects votes if `NOW() > voting_end`, but the phase stays `VOTING` until an admin manually clicks "Advance to VOTING_CLOSED".

### Admin UI

- **Election Settings tab** → "Election Dates" pane
- Controlled form with 4 datetime-local inputs
- "Save Dates" button calls `POST /api/admin/phase` with `action: 'update_dates'`
- Updates `election_settings` table, logs to `vote_audit_log` as `ELECTION_DATES_UPDATED`

---

## Admin Dashboard (8 Tabs)

| Tab | Route | Features |
|-----|-------|----------|
| 1 | Search & Issue Paper Ballot | Search members, issue paper ballots with QR |
| 2 | Preprinted Ballots | Generate blank ballots, assign via QR scan, void unused |
| 3 | Record / Spoil Vote | Record paper votes via QR, mark ballots spoiled |
| 4 | Election Settings | Phase control (3-level), dates, reset election |
| 5 | Candidates | CRUD (name, statement, photo, active) |
| 6 | Members Management | CSV import (email optional), activate/deactivate |
| 7 | Token Dispatch | Send voting/nomination tokens via email |
| 8 | Audit Log | Filterable, paginated view of all actions |

---

## Development Setup

### Prerequisites
- Node.js 24+ (via nvm)
- npm
- Supabase project with migrations applied

### Install
```bash
npm install
```

### Run Dev Server
```bash
npm run dev
```

### Build
```bash
npm run build
```

### Lint
```bash
npm run lint
```

### Security Commands
```bash
npm run audit        # npm audit --audit-level=high
npm run sbom         # Generate CycloneDX SBOM
npm run security:check  # Run both audit + sbom
```

### Database Migrations — CANONICAL run order (run in Supabase SQL Editor in order)

This is the authoritative end-to-end sequence for a **fresh destructive rebuild + re-seed**
(oracle-reconciled 2026-09-03). Replay every file below, in order. `seed.sql` runs **LAST**.

1. `supabase/schema.sql`
2. `supabase/migration_paper_ballots.sql`
3. `supabase/migration_fix_paper_rpcs.sql`
4. `supabase/migration_public_wrappers.sql`
5. `supabase/migration_fix_gen_random_bytes.sql`
6. `supabase/migration_fix_service_role_grants.sql`
7. `supabase/migration_admin_sessions.sql`
8. `supabase/migration_rate_limit.sql`
9. `supabase/migration_token_expiry.sql`
10. `supabase/migration_option_e_paper_ballots_part1.sql`
11. `supabase/migration_option_e_paper_ballots_part2.sql`
12. `supabase/migration_phase_control.sql`
13. `supabase/migration_phase_token_admin.sql`
14. `supabase/migration_audit_log_hash_chain.sql`
15. `supabase/migration_enforce_token_expiry.sql`      # has OLD leaky digital payload — MUST precede opaque fix
16. `supabase/migration_configurable_token_ttl.sql`   # additive: election_settings.voting_token_ttl_hours
17. `supabase/migration_lock_public_vote_wrappers.sql`
18. `supabase/migration_drop_legacy_paper_vote_overload.sql`
19. `supabase/migration_opaque_ballot_ids.sql`         # v0.3.0 — final writer: opaque submit_anonymous_vote / issue_paper_ballot / generate_blank_paper_ballot_batch
20. `supabase/migration_fix_spoil_frees_token.sql`     # v0.3.0 — final writer: spoil_paper_ballot frees reserved digital token
21. `supabase/seed.sql`                                # LAST of the base rebuild — sets phase=VOTING, inserts candidates/members
22. `supabase/migration_nomination_submission.sql`    # Nomination feature: submit_nomination + search + admin_add_nomination + anonymous_nominations lockdown (references election_settings id=1, so runs after seed)
23. `supabase/migration_nomination_hardening.sql`      # SEC-02b/SEC-03 rate-limit hardening: REVOKE check_rate_limit + cleanup_rate_limit_hits + created_at index (runs after migration_rate_limit.sql AND migration_nomination_submission.sql)
24. `supabase/migration_nomination_public_wrappers.sql` # public wrappers for search_members_for_nomination / submit_nomination / admin_add_nomination — WITHOUT these the nomination HTTP flow silently returns empty (private schema is not PostgREST-exposed). Runs after migration_nomination_submission.sql
25. `supabase/migration_fix_admin_id_fk.sql`           # repoints vote_audit_log.admin_id + nomination_adjudications.admin_id FKs from members(id) -> admin_sessions(id) ON DELETE RESTRICT (admin identity is a session id, not a member); adds admin_sessions revoke-not-delete columns (revoked_at/revoke_reason, token_hash nullable); vote_audit_log append-only trigger; atomic private+public adjudicate_nomination RPC. Runs after both admin_sessions (item 7) and nomination_submission (item 22) exist
26. `supabase/migration_member_mgmt_phase_gate.sql`    # Wave 0.2 — member-management phase gate + RPCs: private/public assert_electorate_editable (edits allowed only in SETUP/NOMINATION/NOMINATION_CLOSED), create_member (single-add, generates M-<hex> when member_code absent, 23505 MEMBER_UNIQUE_CONFLICT on dup), set_member_active (phase-gated activate/deactivate). service_role-only grants. Runs after seed.sql (references election_settings id=1)
27. `supabase/migration_token_reissue.sql`             # v0.7.0 Token Void & Reissue — adds tokens.void_reason / voided_at / reissued_from_token_id (self-FK ON DELETE NO ACTION), partial unique index enforcing one active token per member per type, the reissue RPC, and a voided-token guard in submit_anonymous_vote (voided token rejected with 'Voting phase is closed or expired.'). Idempotent. Runs after the base rebuild
28. `supabase/migration_wave3_paper_token_reserve.sql` # v0.9.0 Wave 3 Paper-Ballot Integrity — FINAL writer for issue_paper_ballot + spoil_paper_ballot (supersedes items 19/20 for these two). Model A issue_paper_ballot now locks the VOTING token FOR UPDATE *before* inserting the paper ballot (same lock order as submit_anonymous_vote) and reserves it (is_used=TRUE, channel_sent='PAPER'), closing the double-vote gap; adds a >1-non-voided-token integrity guard. spoil_paper_ballot frees the reserved token for status IN ('ISSUED','ISSUED_TO_VOTER') (was ISSUED_TO_VOTER only), keeping the channel_sent='PAPER' guard so a genuine digital/EMAIL token is never cleared. Idempotent. MUST run last of the paper-ballot writers.
29. `supabase/migration_wave6_nomination_prefix_search.sql` # v0.11.0 Wave 6 — FINAL writer for search_members_for_nomination (supersedes the matching predicate in item 22). Replaces the single pg_trgm `%` similarity predicate with a hybrid `full_name ILIKE p_query || '%' OR p_query <% full_name` (word_similarity), ordered by word_similarity DESC — guarantees short-prefix matches (e.g. 'andr' → all 'Andrew …') that the bare `%` operator missed, while keeping fuzzy tolerance. Signature/return/SECURITY DEFINER/search_path and all token+phase guards preserved byte-identical; CREATE OR REPLACE retains the item-22 REVOKE/GRANT ACL. Idempotent. Runs after item 22 (must be the LAST writer for search_members_for_nomination).
30. `supabase/migration_wave5_governance_ledger.sql` — wipe-surviving governance/RoPA ledger (governance schema; excluded from seed.sql).
31. `supabase/migration_wave5_eligibility_schema.sql` — eligibility columns + eligibility_adjudications.
32. `supabase/migration_wave5_eligibility_enforcement.sql` — **MUST be the final writer** for submit_anonymous_vote / issue_paper_ballot / issue_preprinted_paper_ballot; adds token-eligibility trigger + purge_roster_pii. Re-running any earlier writer for those RPCs after this re-opens the eligibility gap.
33. `supabase/migration_wave5_eligibility_adjudication.sql` — atomic `adjudicate_eligibility` RPC + public wrapper (members override + append-only `eligibility_adjudications` audit in one transaction). Independent of the item-32 writers; safe to run after 32.
34. `supabase/migration_wave6_paper_severance.sql` — **v0.13.0 Wave 6 — FINAL writer for the entire paper plane.** Structurally severs the paper identity plane from the anonymous ballot plane (clears the council real-PII NO-GO: C1 `vote_audit_log` register, C2 shared `ballot_id` join; C3 timing-correlation is an accepted deferred residual). Adds immutable `election_settings.paper_ballot_layout` (SEPARATE_SLIP default / SINGLE_SHEET, immutable once phase ∈ VOTING/VOTING_CLOSED/COMPLETED) + token reservation columns; creates the member-blind `anonymous_paper_blanks` pool and split audit tables (`participation_audit` identity-only, `ballot_audit_log` ballot-only, each with a CHECK rejecting the opposite plane's handles); repurposes `paper_ballots` as identity-only (drops `ballot_id`/`candidate_id`, migrates legacy history); retro-scrubs `vote_audit_log` vote handles + installs a no-colocation CHECK/trigger + append-only trigger (SEC-18 hash chain preserved); replaces the matched-pair paper RPCs with split writers (`check_in_paper_voter` identity-only, `generate_anonymous_blank_ballot_pool`, `submit_paper_vote` returning `{success,message,receipt_code}` only, `correct_paper_vote`, `spoil_paper_check_in`, `void_anonymous_paper_blank`, `paper_pool_reconciliation`); deprecated matched-pair RPCs (`issue_paper_ballot`, `issue_preprinted_paper_ballot`, `generate_blank_paper_ballot_batch`) fail closed with a `superseded` message. Requires `admin_sessions`, `tokens.voided_at`, Wave 5 eligibility columns, and `private.hmac_sign/hmac_verify/generate_short_code`. **IRREVERSIBLE** (retro-scrub NULLs + `DROP … CASCADE`); not idempotent across a partial failure. Runs after items 30–33.
35. `supabase/migration_wave7_digital_severance.sql` — **v0.13.0 Wave 7 — FINAL writer for the digital vote plane.** Adds transient-reservation two-phase digital voting (redeem → cast → optional release), `election_settings.digital_write_mode` (`LEGACY` default / `TWO_PHASE` opt-in), and `election_settings.digital_credential_ttl_minutes` (default 15, CHECK 1..1440). Apply is backward-safe (stays LEGACY until explicitly switched).

**EXCLUDED (do NOT run — superseded / rollback / obsolete):**
- `supabase/migration_option_e_paper_ballots.sql` — superseded monolith (use part1 + part2); also carries the old leaky digital payload.
- `supabase/migration_option_e_paper_ballots_rollback.sql` — destructive revert, not part of forward rebuild.
- `supabase/migration_add_ballot_id_column.sql` — obsolete old-DB repair; `schema.sql` already creates `ballots.ballot_id`.

> **CRITICAL (v0.3.0 / v0.9.0):** item 19 must be the LAST migration to (re)define
> `submit_anonymous_vote` and `generate_blank_paper_ballot_batch`, and **item 28
> (`migration_wave3_paper_token_reserve.sql`) must be the LAST to (re)define
> `issue_paper_ballot` and `spoil_paper_ballot`** (it supersedes items 19/20 for those two).
> Do NOT re-run `migration_enforce_token_expiry.sql` (item 15), the Option E monolith,
> or items 19/20's `issue_paper_ballot`/`spoil_paper_ballot` after item 28 — item 15 or the
> monolith would reintroduce the leaky digital payload, and re-running 19/20 last would
> reintroduce the paper-ballot double-vote gap Wave 3 closed.
> **CRITICAL (Wave 5):** item 32 must be the LAST migration to (re)define
> `submit_anonymous_vote`, `issue_paper_ballot`, and `issue_preprinted_paper_ballot`.
> Do NOT re-run earlier writers for those RPCs after item 32, or the eligibility gates
> are silently removed.
> **CRITICAL (v0.13.0 / Wave 6):** item 34 is the LAST writer for the **entire paper
> plane** and must run after items 30–33. It supersedes the paper portions of items 11
> (`migration_option_e_paper_ballots_part2.sql` paper writers / blank batch), 19
> (`migration_opaque_ballot_ids.sql` `issue_paper_ballot` / `generate_blank_paper_ballot_batch`),
> 20 (`migration_fix_spoil_frees_token.sql`), 28 (`migration_wave3_paper_token_reserve.sql`),
> and 32 (`migration_wave5_eligibility_enforcement.sql` `issue_paper_ballot` /
> `issue_preprinted_paper_ballot`). Do NOT re-run any of those paper writers after item 34
> — doing so reintroduces the matched-pair `ballot_id`↔identity co-location Wave 6 severed
> (re-opening the council real-PII NO-GO). The digital `submit_anonymous_vote` writer chain
> (items 19/32) is unaffected by Wave 6.
> **CRITICAL (v0.13.0 / Wave 7):** item 35 is the LAST writer for the **digital vote plane**.
> It introduces operator-gated two-phase endpoints while keeping `LEGACY` as default at
> migration-apply time. Switching modes is operational (`digital_write_mode`) and reversible
> (`TWO_PHASE` ↔ `LEGACY`) without reapplying migrations.
> **Wipe cleanup:** `seed.sql` truncates all election-scoped tables in one CASCADE —
> including `vote_audit_log`, `paper_ballot_batches`, `admin_sessions`,
> `phase_change_tokens`, and `rate_limit_hits`. `admin_sessions` shares the CASCADE with
> `vote_audit_log` because `vote_audit_log.admin_id -> admin_sessions` is `ON DELETE
> RESTRICT` (`migration_fix_admin_id_fk.sql`); truncating them together is the only
> FK-valid path. (Wave 7 closed the earlier gap where these five tables were cleared only
> by prose instruction.)

### Election Lifecycle & Reuse (Wipe / Multi-Election / Re-Import)

**Single-election design.** The schema holds exactly one election at a time: `election_settings`
is a single row (`id = 1`) and no table carries an `election_id`. All ballots, tokens, members,
and nominations belong to "the" election. There is no in-app "new election" that preserves prior
history.

**The only real data wipe is the destructive reseed.** The in-app **Reset Election** (Settings
tab, three-fold confirmation) *only* sets `current_phase = 'SETUP'`
(`app/api/admin/phase/route.ts`, `execute_reset`) — it deletes **no** ballots, tokens, members, or
nominations. To actually clear data you replay the CANONICAL run order above; `seed.sql` performs
the full wipe in one statement (`TRUNCATE candidates, tokens, anonymous_nominations, ballots,
paper_ballots, paper_ballot_batches, vote_audit_log, phase_change_tokens, admin_sessions,
rate_limit_hits CASCADE; DELETE FROM members;`). This runs from the
Supabase SQL Editor / MCP, **never** from the app UI.

### Wipe / erasure is more than the DB

`seed.sql` clears DB tables only. A complete erasure ALSO requires:
- **Filesystem:** delete/move prior-org files under `archives/` (aggregate exports only — no raw exports exist by design).
- **Object storage:** delete the election/org bucket or prefix if used.
- **Supabase PITR/backups:** cannot be surgically erased by app code; completes at retention expiry or via project destruction. Record purge timestamp + retention window + expected expiry in the governance ledger.
- **Raw retention:** forbidden in-app. Any legally-compelled raw preservation is a manual out-of-band DBA action on written controller instruction, logged as a `RAW_RETENTION_OUT_OF_BAND_DECLARED` ledger event (no voter linkage).

**What `seed.sql` is for, and how to run it.** `seed.sql` is the disposable **test/demo
fixture**, not a provisioning tool: one run resets the database to a single known state —
4 candidates, 300 synthetic members, phase = `VOTING`. It is destructive and non-idempotent
(every run wipes first). Run order for a full destructive rebuild:

1. **Set the HMAC key separately, outside any transaction** (it uses `ALTER SYSTEM`, which
   cannot run inside a transaction block):
   ```sql
   ALTER SYSTEM SET app.ballot_hmac_key = '<32+ char key>';
   SELECT pg_reload_conf();
   ```
2. Run `schema.sql`, then every migration in the **CANONICAL run order above** — all tables
   `seed.sql` truncates must already exist.
3. Run `seed.sql` **last**. It wipes all election-scoped tables, then loads the fixture and
   sets phase = `VOTING`.

For a **go-live** run you deviate from step 3: keep the wipe but **skip `seed.sql`'s inserts**
and set phase = `SETUP`, then import real members (see "Option B" below). As written, `seed.sql`
leaves you in test/demo state (VOTING + 300 fake members), never go-live state.

**Going live (first real election) — the "Option B" wipe.** Run the destructive reseed once before
any real votes. It is required both to purge all test data *and* because the v0.3.0 opaque-ballot-ID
anonymity fix cannot be applied retroactively — pre-existing plaintext ballot IDs must be wiped. This
is a one-time go-live prerequisite, not an ongoing operation.

**Reusing one deployment across elections or organizations (disposable model).** Because there
is no `election_id` and no tenant concept, one deployment holds exactly one election's data at a
time — so the *same* application can serve different elections over time **and** different
organizations, provided they are **strictly serial (never concurrent) and no history is retained**.
The reuse cycle is:

1. **Archive the result first — before wiping, which is irreversible.** Run
   `node scripts/export-results.js` (env sourced first: `NEXT_PUBLIC_SUPABASE_URL`,
   `SUPABASE_SERVICE_ROLE_KEY`) to write the anonymous aggregate tally (per-candidate counts +
   total) to `archives/` as JSON + CSV. It requires a published phase (`VOTING_CLOSED` or
   `COMPLETED`) and exports **no personal data** — only `candidates` and `ballots.candidate_id`
   — so the archive is safe to keep indefinitely. **Do not export the raw `members`, `tokens`,
   or `vote_audit_log` tables** as a routine archive step: retaining that personal / participation
   data re-creates the PII store the wipe exists to eliminate and carries data-protection
   obligations (lawful basis, retention limit, per-org segregation, right-to-erasure). If a
   specific election legally requires raw retention, that is a **governed** operation deferred to
   the Wave 5 privacy design — see the roadmap — not this archive step.
2. **Wipe + reload for the next election/org:** replay the CANONICAL run order; for a real
   election use the Option B wipe (above), then import that election's real members and dispatch
   tokens.
3. **Per-election vs. global config.** Election *data* is fully per-election, but deployment
   identity is **not**: `ADMIN_SECRET`, `APP_BASE_URL`, and the email sender (`FROM_EMAIL` /
   Resend) are shared across every election on that deployment. If a different organization needs
   different email branding or base URL, change those env vars and redeploy between elections.
   Rotating `app.ballot_hmac_key` per election is good hygiene (not strictly required — a full
   wipe means old ballot IDs no longer resolve).

Anonymity note: in this disposable model the secret-ballot guarantee stays clean **because
everything is wiped together** — there is no cross-election linkage left behind. Selective
archiving of raw linkage tables (`tokens.member_id` records who voted) would undermine that,
which is the second reason step 1 exports the aggregate only.

**"Keep members, reset votes only" is unsafe.** Technically you could truncate just the
vote-domain tables (`ballots, paper_ballots, tokens, anonymous_nominations, vote_audit_log,
paper_ballot_batches`) and leave `members`, but re-importing onto a populated `members` table is
unsafe (see below); prefer the clean reseed.

**Member management is phase-gated (Wave 0.2).** All roster edits — single-add, activate/deactivate,
and CSV import — are only permitted while `current_phase` is `SETUP`, `NOMINATION`, or
`NOMINATION_CLOSED`. From `VOTING` onward the roster is **locked**: the dashboard disables the controls
(`rosterLocked` state) and the DB `assert_electorate_editable()` guard rejects any write. `seed.sql` and
migrations insert members directly and are intentionally exempt (no table trigger — the gate lives in the
RPCs and API routes).

**Single-member add.** `POST /api/admin/members-manage` (CSRF-protected) calls the `create_member` RPC.
`member_code` is the authoritative identity key; when omitted an `M-<hex>` code is generated. Duplicate
`member_code`/`email`/`phone` returns **409** (`MEMBER_UNIQUE_CONFLICT`, SQLSTATE 23505). Activate/deactivate
(`PATCH`) routes through `set_member_active` so the same phase gate applies. **Dropped members are never
deleted** (`tokens.member_id` / `paper_ballots.member_id` are `ON DELETE CASCADE`) — deactivation is the
correct "remove".

**Member re-import hardening (Wave 0.2).** Both import paths now key on `member_code` (not `email`):
- `scripts/import-members.js` and the dashboard `members-import` POST upsert on the **`member_code`**
  conflict key.
- Against a **non-empty** roster, any incoming row **lacking a `member_code` is refused** (prevents the
  old random-`M-<hex>` duplication). The initial empty-roster bulk load still accepts code-less rows and
  generates codes.
- The dashboard import POST is additionally **phase-gated** (rejected once `VOTING` opens).
- CSV import can accept an optional `dob`/`date_of_birth` column for eligibility derivation; DOB is parsed in-memory only and is never stored.
- Still true: members **dropped from a new CSV are not auto-deactivated** — deactivate them explicitly via
  the dashboard (or an `admin_add`-style flow). Re-import updates/inserts; it does not prune.

Rule of thumb: initial bulk load onto an **empty** roster; thereafter prefer **single-add** and explicit
**deactivate** over bulk re-import. A full roster swap for a new cycle still uses the destructive
wipe-and-reseed.

### Environment Variables (`.env.local`)
```
NEXT_PUBLIC_SUPABASE_URL
NEXT_PUBLIC_SUPABASE_ANON_KEY
SUPABASE_SERVICE_ROLE_KEY
APP_BASE_URL
RESEND_API_KEY
FROM_EMAIL
ADMIN_SECRET
ADMIN_EMAIL          # Optional: recipient for phase confirmation emails
```

---

## Testing

### Automated UAT Suite
```bash
npx playwright test tests/uat.spec.ts --reporter=line --workers=1
```
36 tests covering: auth, tab navigation, phase change (3-fold), reset election (3-fold), token dispatch, public pages, API security.

### Manual UAT
See `docs/UAT_MANUAL_TESTING.md` for comprehensive voter/admin manual testing scenarios.

### Build Verification
```bash
npm run build  # Includes TypeScript type-check
npm run lint
```

### Security Commands
```bash
npm run audit        # npm audit --audit-level=high
npm run sbom         # Generate CycloneDX SBOM (sbom.json)
npm run security:check  # Run both audit + sbom
```

---

## Security Features (v0.2.0+)

### Digital write mode (Wave 7 two-phase toggle)

Migration item 35 adds two `election_settings` controls:

- `digital_write_mode` — enum-checked `LEGACY` (default) or `TWO_PHASE`
- `digital_credential_ttl_minutes` — reservation credential TTL (`1..1440`, default `15`)

**Operator toggle (no automatic cutover on migration apply):**

```sql
UPDATE election_settings
SET digital_write_mode = 'TWO_PHASE'
WHERE id = 1;
```

Rollback path is symmetric (`SET digital_write_mode='LEGACY'`).

### Two-phase digital endpoint contract (Wave 7)

When `digital_write_mode='TWO_PHASE'`:

- `POST /api/vote/redeem` — `{ token }` → `{ credential, ttlSeconds }`
- `POST /api/vote/cast` — `{ credential, candidateId }` → `{ receiptCode, ballotId }`
- `POST /api/vote/release` — `{ token }` (explicitly releases an unused reservation)

Mode gates:

- In `LEGACY` mode, `/api/vote/redeem|cast|release` fail closed with HTTP `409` (`LEGACY_MODE`)
- In `TWO_PHASE` mode, legacy `POST /api/vote` returns HTTP `409` (`TWO_PHASE_REQUIRED`)

Semantics are **reserve-don't-consume**: redeem reserves entitlement, cast finalizes consumption, and an uncast reservation can be released (or expire/sweep) to free the token for retry.

### Authentication & Session Management
- **HttpOnly cookie-based admin auth** (`lib/audit-log.ts`, `app/api/admin/auth.ts`)
  - `POST /api/admin/login` — validates secret, creates session in `admin_sessions`, sets HttpOnly cookie
  - `POST /api/admin/logout` — destroys session, clears cookie
  - `GET /api/admin/me` — validates session cookie
  - 30-minute session TTL, stored in `admin_sessions` table with SHA-256 token hash
  - **No localStorage secret storage** (eliminates XSS theft vector)

- **CSRF Protection** (double-submit cookie pattern)
  - Non-HttpOnly `admin_csrf` cookie + `x-csrf-token` header
  - `requireAdminWithCsrf()` on all state-changing admin APIs
  - Dashboard `apiFetch()` wrapper auto-includes CSRF token

### Rate Limiting (Distributed)
- **Supabase RPC `check_rate_limit()`** (`proxy.ts`, `migration_rate_limit.sql`)
  - Sliding window with atomic increments
  - Admin APIs: 120 req/min per IP (prod), 1000/min (dev)
  - Vote API: 5 req/min per IP
  - Member search: 30 req/min per IP
  - Replaces in-memory Map (bypassed in serverless)

### Token Security
- **Voting tokens**: configurable expiry, default 7 days (`tokens.expires_at`; see Configurable voting token TTL below)
- **Nomination tokens**: 24-hour expiry
- **Phase change tokens**: 1-hour expiry, bound to admin session (`admin_session_id` FK)
- **Reset election tokens**: 1-hour expiry, bound to admin session
- **Three-fold confirmation** for phase changes and reset:
  1. Request → email sent
  2. Click email link → token verified
  3. Type CONFIRM/RESET → final dialog → execute

### Voter Authentication & Proxy-Voting (Threat Model & Limitations)

The system provides two voting channels with deliberately different identity-assurance levels:

- **Digital channel (magic link):** A one-time link is emailed to each member's registered address (`tokens.token_hash`, validated at `POST /api/auth/verify-token` and `POST /api/vote`). Authentication is **possession-based** — anyone holding the link can cast that member's vote. There is no device binding, IP check, or re-authentication. If a member forwards their link, the recipient can vote as them.
- **Paper channel (in-person):** On voting day the admin scans a preprinted ballot's QR and assigns it to a member (`POST /api/admin/paper-assign` → `private.issue_preprinted_paper_ballot`), binding identity in person and locking that member's digital token. This is the **high-assurance** channel.

**What is and isn't preventable:**
- *Involuntary impersonation* (stolen/intercepted link) is mitigated by single-use tokens, expiry, and delivery only to the registered address.
- *Voluntary delegation* (a member willingly handing over their means to vote) **cannot be prevented on any remote channel** — the member can always forward a link, relay a one-time code, or share a device. The only true defense is in-person identity verification, i.e. the paper channel.

**Accepted limitation:** The digital channel is possession-based by design (low friction). For votes requiring a defensible guarantee that each ballot was cast by the correct person, use the **paper channel**. Routing votes through an out-of-band email that names voter + candidate is explicitly **rejected**: it would destroy ballot anonymity (a plaintext, correlated who-voted-for-whom record in an uncontrolled mailbox) while only weakly and spoofably deterring proxy voting.

**Deferred hardening option (NOT implemented):** If the digital channel must become proxy-resistant while remaining remote, add an **at-cast-time one-time code delivered over a second channel** (SMS to the registered phone — an email link plus an email OTP share one inbox and add no real security). The code would be validated in the identity/auth layer *before* the anonymous ballot insert, preserving anonymity. This requires collecting member phone numbers and an SMS provider, and still cannot defeat voluntary delegation. Adopt only if proxy voting proves a demonstrated risk.

### Audit Logging (Tamper-Evident)
- **Hash chaining** (`migration_audit_log_hash_chain.sql`, `lib/audit-log.ts`)
  - `record_hash` = SHA-256(action|admin_id|member_id|details|previous_hash|created_at)
  - `previous_hash` links to prior record
  - `insert_audit_log()` RPC with fallback to direct insert
  - `admin_id` populated from session (no more `null`)

### Input Validation & Sanitization
- **Length limits** (`lib/input-validation.ts`): candidate name 255, statement 5000, photo URL 2048, etc.
- **CSV formula injection sanitization**: prefixes `=`, `+`, `-`, `@`, `\t`, `\r` with `'`
- **Photo URL validation**: HTTPS only, scheme validation
- **Email/phone validation**: format + length checks

### Error Handling
- **Generic errors in production** (`lib/api-errors.ts`)
  - `apiError()` returns "Internal server error" in prod, detailed in dev
  - Server-side logging only

### Config Validation
- **Module-load validation** (`lib/config-validation.ts`)
  - Required env vars checked
  - APP_BASE_URL format validated (HTTPS in prod)
  - FROM_EMAIL format validated
  - Production: ADMIN_SECRET ≥32 chars, no weak secrets, APP_BASE_URL not localhost

### Security Headers
- **CSP, HSTS, X-Frame-Options, X-Content-Type-Options, Referrer-Policy, Permissions-Policy** (`next.config.ts`)

### Rate Limiting (Distributed)
- Admin APIs: 120 req/min per IP (prod)
- Vote API: 5 req/min per IP
- Member search: 30 req/min per IP
- Via `check_rate_limit()` RPC

### Token Expiry
- Voting: default 7 days (configurable — see below)
- Nomination: 24 hours
- Phase change/reset: 1 hour

#### Configurable voting token TTL
- Stored in `election_settings.voting_token_ttl_hours`
- Admin-editable via `PATCH /api/admin/settings`
- Bounded to `1..2160` hours by API validation and DB CHECK constraint
- Default: `168` hours (7 days)

### Config Validation
- Fails fast in production on missing/invalid env vars
- ADMIN_SECRET ≥32 chars, no weak secrets
- APP_BASE_URL HTTPS in prod

---

## Deployment

### Vercel (Recommended)
1. Connect GitHub repo
2. Add environment variables
3. Deploy

### Docker
```dockerfile
FROM node:24-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build
CMD ["npm", "start"]
```

### Production Checklist
- [ ] All 15 migrations applied in Supabase
- [ ] `ADMIN_SECRET` set and secure (≥32 chars)
- [ ] `RESEND_API_KEY` and `FROM_EMAIL` configured
- [ ] `APP_BASE_URL` set to production URL (HTTPS)
- [ ] `ADMIN_EMAIL` set for phase confirmation emails
- [ ] Rate limiting tested
- [ ] HTTPS enforced
- [ ] Security headers verified
- [ ] `npm run security:check` passes

---

## Key Files Reference

| File | Purpose |
|------|---------|
| `lib/supabase-server.ts` | Service-role client singleton |
| `proxy.ts` | Distributed rate limiter for admin/vote APIs |
| `app/api/admin/auth.ts` | `requireAdmin()`, `requireAdminWithCsrf()`, `getAdminSession()` |
| `lib/api-errors.ts` | Standardized error responses |
| `lib/input-validation.ts` | Length limits, email/phone validation |
| `lib/audit-log.ts` | `insertAuditLog()` with hash chaining |
| `lib/config-validation.ts` | Module-load config validation |
| `app/admin/dashboard/page.tsx` | Admin UI (8 tabs) |
| `app/api/admin/phase/route.ts` | Phase control + dates API |
| `supabase/schema.sql` | Base schema |
| `supabase/migration_phase_control.sql` | Phase tokens + DB triggers |
| `supabase/migration_audit_log_hash_chain.sql` | Audit log hash chaining |
| `supabase/migration_rate_limit.sql` | Rate limiting RPC |
| `supabase/migration_admin_sessions.sql` | Admin sessions table |
| `supabase/migration_token_expiry.sql` | Token expiry column |
| `supabase/migration_phase_token_admin.sql` | Phase token admin binding |
