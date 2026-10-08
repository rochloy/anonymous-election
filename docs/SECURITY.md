# Security & Privacy Model

## Anonymity Guarantee (Honest Statement)

This system guarantees **anonymity against other voters and the public**. It does **not** guarantee anonymity against the administrator.

### What is protected
- One voter cannot see another voter's choice.
- Public results show aggregate counts, not voter identities or stored receipt codes. A caller may check whether a code they supply was recorded; that lookup does not reveal the selected candidate.
- The receipt-code lookup lets a voter verify their own vote was counted, without revealing their identity.

### What is NOT protected
The administrator (or anyone holding the `SUPABASE_SERVICE_ROLE_KEY`, or Supabase support staff) has the technical ability to correlate votes to voters via:
1. **Transaction timestamps**: the `submit_anonymous_vote` RPC updates `tokens.used_at` and inserts a `ballots` row in the same transaction. The millisecond-precision `used_at` can be joined to the ballot insertion time.
2. **Query logs**: Supabase's Postgres logs capture RPC parameters (`p_token_hash`, `p_candidate_id`) in plaintext. The `p_token_hash` directly identifies the voter.

### Mitigation commitments
- The administrator has committed, in writing, not to run correlation queries.
- Database query logs are escrowed with a third party and not directly accessible to the admin.
- The `private` schema and `REVOKE EXECUTE FROM anon` prevent direct RPC invocation by non-admin clients.

### If you need stronger anonymity
If the threat model includes a curious or coerced administrator, this architecture is insufficient. Use a blind-signature or mixnet architecture instead, where no single component can link identity to vote.

## Security Controls Implemented
- **Admin route auth (current model)**: admin login (`/api/admin/login`) authenticates with a request-body secret against `ADMIN_SECRET`, then issues an HttpOnly `admin_session` cookie; authenticated admin mutations require CSRF validation (`admin_csrf` cookie + `x-csrf-token` header).
- **Rate limiting (per-surface semantics):** confirmed limiter denials are HTTP 429 on all covered surfaces. Limiter unavailability/fault handling is route-specific: admin login is fail-closed (503), general admin proxy + legacy vote + admin member search are fail-open on limiter fault, and nomination submit/search are fail-closed (503).
- **RPC in private schema**: `submit_anonymous_vote` and `submit_paper_vote` are in the `private` schema, not exposed via PostgREST. `REVOKE EXECUTE FROM anon, authenticated`.
- **CSPRNG receipts**: receipt codes generated with `gen_random_bytes` (Postgres CSPRNG) inside the RPC, with 5-attempt retry on collision.
- **Paper tally fix**: paper votes insert a `ballots` row with `channel='PAPER'`, so they enter the canonical tally.
- **No live turnout during voting**: `/api/admin/stats` hides turnout counts while phase is `VOTING` (anti-coercion).
- **Receipt-free public verification (v0.10.0)**: `/api/verify` confirms only that a vote was **recorded** (`{found, channel, cast_date}`) and never returns the chosen candidate in any phase. Prior to v0.10.0 it revealed the candidate name once phase left `VOTING`, which turned any leaked or coerced `ballot_id` into a transferable proof of *how* someone voted; that disclosure is removed. Digital self-verification uses the voter's `VC-…` receipt code (the `ballot_id` is never returned to the browser); paper voters may verify by their `PB-…` receipt or by the ballot ID printed on their ballot (PB- accepted since 2026-10-08, `migration_f4_verify_paper_receipts.sql` — previously a PB- receipt was format-rejected before the ballot lookup, yielding a false "not found"). Receipt lookup is format-guarded (`^(VC|PB)-[0-9A-F]{10}$`) and canonicalized before an exact match, with no `ilike`/wildcard path (anti-coercion / receipt-freeness).
- **Token in URL path**: magic links use `/vote/<token>` not `/vote?token=<token>`, avoiding access-log and Referer leakage.
- **Random member codes**: seed uses random 8-char codes, not sequential `MEM-001`..`MEM-300`.
- **Opaque, unguessable ballot IDs**: ballot IDs are pure-random opaque payloads — `PAPER:<64-hex>` (paper) / `DIGITAL:<64-hex>` (digital), 256 CSPRNG bits with **no** member/candidate/timestamp embedded — closing the Tier-1 deanonymization leak. A former HMAC signature layer (`payload || '.' || <hmac-sig>`) was removed 2026-10-08 (`migration_drop_ballot_hmac.sql`): it gated nothing — every consumer exact-match looks the ID up in the server-only `anonymous_paper_blanks` pool, and the public verification path never checked the signature — so a leaked signing key had no exploitable ballot-stuffing path. Unguessability rests entirely on the 256-bit random payload, which is retained.
- **URL-based QR payload**: QR codes encode `${APP_BASE_URL}/verify?ballot_id=<id>` so native phone cameras recognize them as actionable links. The ballot ID is already printed as plain text on the physical ballot, so encoding it in a URL introduces no new exposure. The `/verify` endpoint only queries the anonymous `ballots` table — voter identity is never revealed.

## Wave 5 Security / Privacy Additions (v0.12.0)

- **Eligibility fail-closed enforcement:** `UNDETERMINED` eligibility is treated as ineligible by default, with eligibility checks enforced at dispatch + cast paths (defense-in-depth).
- **Age-derived-only model:** age eligibility is derived and stored as a boolean (`is_age_eligible`); DOB is not persisted.
- **Aggregate-only result export posture:** application-supported export is aggregate tally only (no default raw roster/token/audit export endpoint).
- **Append-only governance/adjudication ledger:** governance and adjudication records are append-only, with anti-TRUNCATE protection for governance ledger retention.

## Wave 10 Security Additions (v0.15.1)

- **Eligibility phase-gating (SETUP-only):** eligibility changes are rejected outside SETUP phase (API returns 400, UI shows read-only mode). Prevents eligibility toggling during VOTING/NOMINATION which could suppress votes or create disputes over already-cast ballots.

## Accepted Residuals

### Election-day limiter/runbook assumptions

- No fictional automatic paging/notification is assumed unless separately configured and tested.
- No implicit WAF dependency is assumed for limiter-fault handling.
- Limiter fallback does **not** recover a broad Supabase outage; if DB commit paths are unavailable, online entitlement/check-in finalization must pause per `docs/ELECTION_DAY_RATE_LIMITER_RUNBOOK.md`.

### Admin role separation (Decision E) — deferred

The system does not implement role separation among administrators. There is a single shared
admin credential (`ADMIN_SECRET`), and every authenticated admin can access all admin surfaces —
including the participation view (who has voted, via which channel, and coarse time — **never how
they voted**), PII purge, and ballot-keyed correction. A dedicated `dispute-resolution` role and a
per-view access log were designed (`docs/specs/2026-09-17-v0.13.0-anonymity-design.md` §7) but
**deliberately deferred** (`docs/plans/2026-09-17-decision-e-rbac-backlog.md`).

**Why this is an accepted, proportionate residual:**
- Role separation is a **least-privilege / defense-in-depth** measure, not the substantive
  anonymity control. The substantive control is the identity↔vote linkage severance, which does
  not depend on it.
- No admin surface exposes voter *choice*; the residual concerns *who can see participation
  metadata and run privileged actions*, not confidentiality of the vote.
- The current deployment operates with a single trusted admin principal and no differentiated
  admin duties, so RBAC would separate nothing today. GDPR Art. 25/32 measures are met by the
  severance plus organizational controls proportionate to a small, trusted operator team.

**Revisit trigger:** the deployment becomes multi-admin with separated duties (e.g. a scrutineer
who resolves disputes but must not run PII purge). At that point role separation becomes a genuine
control and should be built (design + additive-implementation notes in the backlog doc above).

## GDPR / Real-PII Readiness

> ## ⚠️ Status: PARTIALLY REMEDIATED — do not treat as real-PII clearance.
> The v0.13.x Security/Anonymity Wave (paper severance + digital severance + app-layer
> reconciliation) has **shipped**: F2, F3, F3b, and F15 remediations are live in production.
> **F4 least-privilege public reads are now deployed/evidenced (M1+M2 + route cutover),** and
> F11 is closed by the 2026-10-05 leak-hardening deployment. F14 remains partial: script Tier-2
> shipped, style Tier-3 (`style-src 'unsafe-inline'`) still open. **F1 is an accepted residual by
> explicit repository-owner decision:** branches/tags are clean and older commits remain
> SHA-reachable by design choice because the exposed rows were synthetic test data.
> Keep synthetic-only posture until independent real-PII go/no-go review.

The Wave 5 GDPR council review returned a **NO-GO** for real-PII deployment. v0.12.0 was functionally complete for workflow/UAT and synthetic datasets, but not compliant/safe enough for production personal-data processing. The v0.13.x wave resolved the architectural NO-GO findings (F2/F3/F3b) via the paper-plane severance and digital-channel severance; the remaining findings below must be closed and verified before loading real personal data.

### Findings summary

| ID | Severity | GDPR article | Area / file | Risk summary | Planned remediation |
|---|---|---|---|---|---|
| F1 | Critical | Art.17 | repo hygiene (`/data`, `/archives`) | **Historical finding (accepted residual):** roster-like rows and archives were committable, and test rows became part of public git history. | Accepted as-is by repository-owner decision. The exposed rows contained **test email addresses — real, deliverable mailboxes used for testing, not synthetic strings** — accepted on that basis by the owner; refs were purged/rewritten, legacy SHA reachability is intentionally not further pursued (no Support purge request, no repo recreation). |
| F2 | Critical | Art.9 / Art.25 | `paper_ballots`, `vote_audit_log` | Same-row storage of `member_id` and `candidate_id` creates a plaintext identity↔vote register. | Option C architectural linkage-break in v0.13.0 (remove direct joinability). |
| F3 | Critical | Art.9 | `submit_anonymous_vote` flow | Vote writer receives token-hash + candidate together and writes ballot + token update in one transaction; privileged observers can correlate. | v0.13.0 redesign to split trust boundaries and unlink identity from vote write path. |
| F3b | Critical | Art.9 | service-role/admin observability logs | Admin/service-role/query-log visibility can deanonymize transaction-level identity↔choice linkage. | v0.13.0 anonymity hardening + logging posture changes (Options B+C package). |
| F4 | Critical | Art.25 | public read boundary (`/api/verify`, `/api/results`, `/api/election/status`, `/api/candidates`) | **Historical risk (closed):** public routes previously depended on service-role-backed reads. **Current status:** cutover to anon-key F4 RPCs is deployed; hosted M1+M2 posture and anon-key probe were reported PASS after M2. | Keep no-direct-table-SELECT posture; preserve narrow forward policy-restoration gate if rollback needed; maintain residual-risk disclosure for direct anon-key RPC reachability. |
| F11 | Medium | Art.5(1)(c) | token dispatch dry-run logging | **Historical risk (closed):** dry-run logs contained member identifiers and link payloads. **Current status:** deployed redaction logs aggregate count only. | Keep category-only logging discipline and generic public errors. |
| F14 | Medium | Art.25 | CSP policy | **Historical risk:** permissive script/style CSP. **Current status:** Tier-2 script nonce policy shipped (`script-src 'self' 'nonce-…' 'strict-dynamic'`, no script `'unsafe-inline'`/`'unsafe-eval'` in prod); Tier-3 style hardening still open (`style-src 'unsafe-inline'`). | Finish Tier-3 style policy when operationally approved. |
| F15 | High | Art.25 | `supabase/schema.sql` replay risk | Executing `schema.sql` regresses the vote writer to the pre-v0.3.0 leaky payload, restores the three removed `PUBLIC FOR SELECT` policies, undoes Wave 6 paper severance, and omits ~70 objects that exist only in later migrations. **Until 2026-10-07 the only mitigation was "final-writer discipline" — a comment in the file, i.e. documentation, not a guard.** Severity raised from Medium: this threatens synthetic demos as well as real data, and is independent of whether real PII is loaded. | **Mechanically disarmed 2026-10-07.** The file now opens a transaction and raises immediately, so nothing commits regardless of client error-handling. Proven against three execution paths (no `ON_ERROR_STOP`, `ON_ERROR_STOP=1`, single-batch console paste), with a control run confirming the unguarded file builds 8 tables and the leaky writer on a properly-privileged PostgreSQL 17. **Resolved 2026-10-08:** the file was replaced by the consolidated verified baseline (snapshot at item 50) — the fresh-rebuild path is restored, and the standing security-invariant suite (`npm run test:db-security`) guards it. |
| F16 | Medium | Art.5(1)(e) / Art.17 | wipe scope (`wipe_election_data`) | **Found 2026-10-07.** The hosted database contained a `backup_wave6` schema (5 tables, 65 rows) created during the Wave 6 severance migration, holding **pre-severance rows with `member_id`, `ballot_id` and `candidate_id` co-located** — `vote_audit_log` (29 rows) and `paper_ballots` (24 rows). Neither `wipe_election_data` nor `purge_roster_pii` references that schema, so the wipe's fail-closed post-wipe assertions verified the 18 `public` tables as empty while this data survived untouched. Concrete instance of the "wipe ≠ erasure" false assurance. | **Residual data removed 2026-10-07** (`DROP SCHEMA backup_wave6 CASCADE`, backed up first; linkage was already orphaned — `public.members` held 0 rows and 0 of the backup `member_id`s resolved). **Structural fix shipped 2026-10-08** (`migration_wipe_schema_coverage.sql`, item 50): the wipe assertion now rejects any unexpected non-system schema outright and dynamically asserts emptiness over every table in the application schemas, with an explicit must-exist survivor allowlist (`election_settings`, the governance ledger). |

### Remediation track

The v0.13.x Security/Anonymity Wave **shipped** (paper + digital severance, split audit tables, no-colocation triggers, final-writer discipline). Current closeout posture before any real-PII load:

- **F4 — least-privilege public-read boundary (CLOSED for this scope):** public routes use anon-key `f4_*` RPCs, M1+M2 are reported hosted-applied, the hosted read-only M2 verifier returned success, hosted anon-key probe reported `PASS stage=ALL` after M2, and orchestrator public-route empty-SETUP smoke passed 7/7.
- **F11 — dry-run log redaction (CLOSED and deployed):** token-dispatch dry-run logs aggregate count only; no names, emails, member codes, tokens, or links.
- **F14 — CSP tightening (PARTIAL):** Tier-2 script nonce policy shipped; Tier-3 style hardening remains open.
- **F1 — git-history residual (ACCEPTED):** refs are clean; older SHA-reachable commits are accepted by explicit repository-owner decision. The exposed rows contained **test email addresses — real, deliverable mailboxes used for testing, not synthetic strings**; the owner accepted the residual on that basis. No GitHub Support purge request or repository recreation will be pursued.
- **F15 — `schema.sql` replay risk (RESOLVED 2026-10-08):** the stale day-one file was mechanically disarmed 2026-10-07, then replaced by the consolidated verified baseline (snapshot at item 50); the fresh-rebuild path is restored and guarded by the standing security-invariant suite.
- **F16 — wipe scope hole (DATA REMOVED, STRUCTURAL FIX SHIPPED 2026-10-08):** the `backup_wave6` residue was dropped; the wipe assertion now covers all application schemas dynamically and rejects unexpected schemas outright (`migration_wipe_schema_coverage.sql`, item 50).

Production use remains restricted to **synthetic data only** pending a separate real-PII go/no-go review, including an explicit decision on the remaining F14 Tier-3 style-CSP risk. F4 closure alone is not GDPR or real-PII clearance.

### F4 residual risk notes (post-closeout transparency)

- `public.f4_verify_ballot(text, text)` remains directly callable with the anon key by design.
- Next.js proxy throttling covers `/api/admin/*` only; no independent direct-PostgREST RPC rate-limit control is currently evidenced.
- `/verify` lookup semantics are intentionally bounded to `{found, channel, cast_date}` (and optional `receipt_match`), not selected candidate and not stored receipt disclosure.
- Digital receipt codes use a random 5-byte suffix (`VC-<10 hex>` ≈ 40-bit space). A caller may supply a ballot ID or guess a matching receipt; resistance to repeated enumeration through the directly callable RPC has not been established. Successful verification reveals existence, channel, and cast date (and optional pair match), never the selected candidate. This does not assert a demonstrated brute-force exploit.

### Recurrence-prevention evidence (throwaway-clone guard test, 7/7)

This section records an empirical guard check run in a throwaway clone this session (real repo history untouched):

- **Controls present:**
  - `.gitignore` blocks `*.csv`, `*.tsv`, `*.xlsx`, `*.xls`, `*.ods`, and `/data/`, `/archives/`, `/exports/`.
  - `.githooks/pre-commit` guard active when enabled via `git config core.hooksPath .githooks`.
  - GitHub secret scanning: **enabled**.
  - GitHub secret-scanning push protection: **enabled**.
- **Proven blocks (known-bad):**
  - real-looking email in a tracked file,
  - force-added `.csv`,
  - international phone pattern.
- **Proven allows (known-good):**
  - placeholder-domain email (`@example.com`) is allowed (guard is not blanket-blocking all emails).
- **Confirmed gaps (empirical):**
  - local-format phone such as `09171234567` passes,
  - bare personal name passes,
  - `--no-verify` bypasses the hook entirely,
  - hook activation is per-clone (`core.hooksPath` must be set in each fresh clone or the guard is inert).
- **Scope caveat:** GitHub secret scanning and push protection target credential-like secret patterns, **not** personal-data/roster semantics. PII defense here depends on `.gitignore` + the local pre-commit hook.
- **Allow-list exclusions:** the hook does not content-scan `package-lock.json`, `.githooks/pre-commit`, `safe-log.test.ts`, or `scripts/test-precommit-guard.sh` — the last two deliberately contain synthetic fixtures that must look real to prove the guard fires. Verified narrow: identical fixture content committed under any other path is still blocked.
- **Repeatable check:** `scripts/test-precommit-guard.sh` re-runs the seven guard cases.

## Personal-data leak controls (2026-10-05 audit)

Audit scope: git history/working tree, server logs, public API responses, database grants, deployed client bundles, and third-party services.

**Verified clean at audit time:** deployed client bundles contain no Supabase keys, no `service_role`, no non-placeholder emails and no public source maps; `/.env` and `/.git/config` return 404; admin APIs return 401 unauthenticated; public APIs return only designed fields (`/api/verify` never returns the candidate; `/api/results` returns aggregates + a receipt found-flag). All 19 `public` tables have RLS enabled with no `anon`/`authenticated` SELECT, and there are no views. `public.rls_auto_enable()` is an event-trigger function (not callable via RPC).

**Controls added:**
- **Category-only server logging** (`lib/safe-log.ts`): `logError(context, err)` logs only a developer-fixed context string, a validated error code (SQLSTATE / PostgREST), a category derived from that code (e.g. `integrity`, `permission`, `api_schema`, `network`, `runtime`) and an allow-listed error kind. **No error message text** is ever logged — nor `details`, `hint`, `cause` or stacks — so names, emails, tokens or row values cannot reach the logs even when they appear in a database message. Full error text remains in Supabase's own access-restricted logs for diagnosis. Covered by `safe-log.test.ts` (`npm run test:safe-log`).
- **Generic public error responses:** public routes no longer return raw database/exception messages.
- **Explicit public columns:** `/api/election/status` returns only the columns its consumers read.
- **Audit-log RPC lock-down** (migration item 42): `insert_audit_log` / `compute_audit_log_hash` were executable by `anon` (forged audit rows were possible); now `service_role` only.
- **Git guard:** `.gitignore` excludes `*.csv`, `*.tsv`, `*.xlsx`, `*.xls`, `*.ods` and `/exports/`; `.githooks/pre-commit` blocks staged data files and added lines containing real-looking emails or phone numbers (matched values are never printed). Enable once per clone: `git config core.hooksPath .githooks`. The hook is a **backstop, not proof**: it scans added text lines only, can miss unscannable binary files outside the blocked types, and is bypassable with `--no-verify`.

**Third-party retention (outside this app's control — operational controls only):**
- **Resend** retains sent emails (recipient address, member name and voting/nomination link) per its own retention policy.
- **Vercel** runtime logs retain whatever the app logs (now sanitized) for the plan's log-retention window.
- **Supabase** Postgres/API logs capture RPC parameters (see "What is NOT protected" above).
- **GitHub** publicly shows commit author emails for every commit.
- Local Playwright output (`playwright-report/`, `test-results/`) can contain dashboard data; both are gitignored — delete after UAT runs against real data.
