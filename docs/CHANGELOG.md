# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

**Live-DB note (0.2.3):** the `REVOKE EXECUTE ON FUNCTION private.submit_paper_vote(VARCHAR, UUID) FROM PUBLIC, anon, authenticated;` statement was applied directly to the running Supabase database (the lockdown migration had already been run pre-patch); re-running the migration file is idempotent.

## [0.5.0] - 2026-09-12

Feature release bundling two independently-developed capabilities plus their security remediation: **printable A6 / 6-up paper-ballot sheets** (`agent/paper-ballot-ux`) and **mobile-phone admin ballot assignment** (`agent/mobile-assign`). Both merged together at release. UI changes are included, so this release **requires a Vercel redeploy** (`vercel --prod --yes`) — unlike the 0.4.x RPC-only hotfixes. The two DB migrations below were **applied live to prod** during the security review and verified against the running instance.

### Added

- **Printable A6 4-up and 6-up paper-ballot sheets** (`agent/paper-ballot-ux`, `d7c5e01`). The dashboard batch-print flow gains a selectable **"Ballots per sheet: 4 (A6) | 6"** control, chunking ballots into print pages with cut-line guides and corrected pagination. Print previews verified by the user for both densities. Files: `app/admin/dashboard/page.tsx`, `app/globals.css` (print `@media` rules, cut-line styling).
- **Mobile-phone admin ballot assignment** (`agent/mobile-assign`, `5a6d5d7`). A phone-optimized wizard (`/admin/mobile-assign`) lets an admin use their phone as a paper-ballot assignment client: mobile login → QR scan → search-by-name → mandatory confirm → assign → auto-clear, with a live session countdown and a "log out everywhere" control. New: `app/admin/mobile-assign/page.tsx`, `app/api/admin/sessions/revoke-all/route.ts` (CSRF-guarded kill switch), `lib/ballot.ts` (client-safe strict ballot-ID validation).
- **Scoped admin sessions.** `admin_sessions` gains a `scope` column (`'desktop'` default, `'mobile'` for phone logins, CHECK-constrained). Mobile-scoped sessions get a shorter **12-minute** absolute TTL (vs 30-minute desktop); `/admin/mobile-assign` requires a `scope='mobile'` session, so a long-lived desktop session cannot be reused on the phone to bypass the shorter TTL. `/api/admin/login` accepts `scope`, returns `expiresAt`; `/api/admin/me` returns `{authenticated, expiresAt, scope}`. Source: `supabase/migration_admin_session_scope.sql`.

### Security

- **BLOCKER — missing phase gate on paper assignment (found in review, ora-1).** `issue_preprinted_paper_ballot` enforced no election phase, unlike the digital-vote RPC. Paper ballots could be assigned in any phase (e.g. `COMPLETED`). Fix: added a `VOTING`-phase gate (plus a `voting_end` cutoff check) that mirrors the digital path. Verified live — the RPC in `COMPLETED` phase returns `success:false, "Paper ballots can only be assigned during the VOTING phase."` with no mutation. Source: `supabase/migration_paper_assign_phase_gate.sql`.
- **BLOCKER — FK regression writing `admin_sessions.id` into a members-FK column (found in review, ora-1).** The RPC wrote `p_admin_id` (an `admin_sessions.id`) into `paper_ballots.issued_by`, which is FK'd to `members(id)` — a guaranteed FK violation that would break every assignment. Fix: **stop writing `issued_by`**; admin attribution is preserved in `vote_audit_log.admin_id` (correctly FK'd to `admin_sessions`). Source: `supabase/migration_paper_assign_phase_gate.sql`.
- **Fail-closed login rate limiting.** `/api/admin/login` gains a login-specific limiter (`admin-login:<ip>`, 5 attempts / 60s) that returns **429 before** the secret is checked and **fails closed** on limiter error — brute-force hardening independent of the general `/api/admin/*` proxy limiter.
- **Minimal member projection for assignment.** `/api/admin/members?mode=assign` returns only `{id, member_code, full_name, votingStatus}` — no email, phone, or QR data reaches the phone client.

### Verified

- `@verifier` standard run on the combined tree: **PASS** — lint 0 errors (19 warnings, baseline), `npm run build` clean, `/admin/mobile-assign` and `/api/admin/sessions/revoke-all` present in build output.
- Both migrations applied to the live Supabase instance via the Supabase MCP (`apply_migration`) → `{success:true}`; phase gate and `admin_sessions.scope` column confirmed live.

### Run order

- `supabase/migration_admin_session_scope.sql` — adds `admin_sessions.scope` (idempotent `ADD COLUMN IF NOT EXISTS` + CHECK). Run any time after `admin_sessions` exists.
- `supabase/migration_paper_assign_phase_gate.sql` — `CREATE OR REPLACE` of `issue_preprinted_paper_ballot`; **supersedes** the definition in `migration_fix_preprinted_shortcode_cast.sql`. Run after it. Applying it is a no-op replace against the already-patched prod DB.

### Known follow-ups (BACKLOG)

- `paper_ballots` actor columns (`issued_by, recorded_by, spoiled_by, voided_by`) and `paper_ballot_batches.generated_by` remain FK'd to `members(id)` rather than `admin_sessions`. All currently NULL (data-safe). Repointing them to `admin_sessions` — mirroring the `vote_audit_log.admin_id` / `nomination_adjudications.admin_id` fix from 0.4.3 — is deferred to a future migration.

## [0.4.4] - 2026-09-12

Bug fix: the pre-printed paper-ballot **assign** RPC (`issue_preprinted_paper_ballot`, Model B) contained two latent defects that only surfaced live during a full-lifecycle demo when assigning a pre-printed ballot to a voter. Both were fixed via `CREATE OR REPLACE FUNCTION` applied directly to the shared Supabase instance (prod) and verified by a successful live assignment; the function signature was unchanged, so no application code or Vercel redeploy was required.

### Fixed

- **Ambiguous `ballot_id` column reference (`93b9d8a`).** Inside `issue_preprinted_paper_ballot`, an unqualified `ballot_id` in a WHERE/RETURN context was ambiguous between the `paper_ballots.ballot_id` column and the function's context, raising `column reference "ballot_id" is ambiguous` and aborting every assignment. Fix: qualify the reference. Source: `supabase/migration_fix_preprinted_ambiguous_ballot_id.sql`.
- **`short_code` type mismatch in the success `RETURN QUERY` (`b7f5708`).** `paper_ballots.short_code` is `character varying(14)` but the function declares `RETURNS TABLE(... short_code text)`; the success path returned the raw `varchar` column, so Postgres raised `structure of query does not match function result type`. (The error path already returned a `text` literal, masking the defect until a *successful* assign was attempted.) Fix: cast `v_ballot.short_code::TEXT` in the success `RETURN QUERY`. Source: `supabase/migration_fix_preprinted_shortcode_cast.sql`.

### Verified

- Live assignment succeeded end-to-end: pre-printed ballot `JG2U-BFY4-QLA0` → `ISSUED_TO_VOTER`, reserving its token (`is_used=TRUE`, `channel_sent='PAPER'`); a paper vote was then recorded against it (`status=VOTED`). The full SETUP→COMPLETED demo completed on prod with a consistent final tally.

### Run order

- Two new idempotent `CREATE OR REPLACE FUNCTION` files (`supabase/migration_fix_preprinted_ambiguous_ballot_id.sql`, `supabase/migration_fix_preprinted_shortcode_cast.sql`) supersede the corresponding function body in `supabase/migration_option_e_paper_ballots_part2.sql`; run them after it. Applying them is a no-op replace against a DB already patched live.

## [0.4.3] - 2026-09-05

Bug fix: admin-attributed audit logging and nomination adjudication were broken by a wrong foreign-key target. Found during a full-lifecycle demo, root-caused with oracle (ora-1), remediated via **Plan C**, and verified with a live SQL smoke test against the shared Supabase instance (prod).

### Fixed

- **`admin_id` FK pointed at `members(id)` but the app supplies an `admin_sessions.id`.** `getAdminSession()` returns the `admin_sessions` PK, so every non-null `admin_id` insert into `vote_audit_log` and `nomination_adjudications` FK-violated. Effects: (1) **100% of admin-attributed audit logging silently failed** (both the `insert_audit_log` RPC and the `lib/audit-log.ts` direct-insert fallback hit the FK; callers ignored the returned error → `vote_audit_log` stayed empty); (2) nomination adjudication (PROMOTE/MERGE/DISCARD) returned 400, and because PROMOTE inserted a `candidates` row **before** the failing adjudication insert, it **orphaned candidates** (retries duplicated them). Pre-existing schema-level defect, unrelated to any data wipe.
- **Remediation (Plan C, oracle ora-1):** repoint both `admin_id` FKs → `admin_sessions(id) ON DELETE RESTRICT` (not `SET NULL` — `admin_id` is hashed into the SEC-18 tamper-evident chain, so nulling it post-insert would forge apparent tampering). RESTRICT forces a **revoke-not-delete** session lifecycle: `admin_sessions` gains `revoked_at` + `revoke_reason`, `token_hash` becomes nullable and is scrubbed on revoke; `app/api/admin/logout` and `auth.ts` (`requireAdmin` expiry path + `getAdminSession`) switch `DELETE` → revoke `UPDATE` and reject revoked sessions. Nomination adjudication is made **atomic** via a single `SECURITY DEFINER` RPC (`adjudicate_nomination`, private + locked-down public wrapper) that performs candidate creation + adjudication + audit in one transaction, so a failure can no longer orphan a candidate and audit is hard-failed in-transaction. A `vote_audit_log` append-only trigger (`BEFORE UPDATE OR DELETE`) hardens the hash chain (TRUNCATE still bypasses it for the wipe procedure).
- **Verified (live SQL smoke test):** atomic PROMOTE commits candidate + adjudication + hashed audit row, all correctly linked (`admin_id` = session); a duplicate PROMOTE raises `23505` (→ 409) **without** orphaning a candidate; `UPDATE`/`DELETE` on `vote_audit_log` is rejected; deleting a referenced `admin_sessions` row is blocked by RESTRICT. `npm run build` passes (TypeScript clean).

### Run order

- New file `supabase/migration_fix_admin_id_fk.sql` added as **CANONICAL run order item 25** (runs after `migration_admin_sessions.sql` item 7 and `migration_nomination_submission.sql` item 22). The inline `REFERENCES members(id)` on `admin_id` was stripped from `schema.sql` and `migration_nomination_submission.sql` (the fix migration is now the authoritative FK source). Deferred follow-ups (audit-log advisory lock, audit fallback hard-fail, `admin_principals` multi-admin) tracked in `docs/plans/2026-09-05-admin-id-fk-backlog.md`.

## [0.4.2] - 2026-09-05

Security hotfix: the v0.4.1 nomination public wrappers were executable by `anon`/`authenticated`. Found during the post-release live-DB verification checklist (oracle ora-2 caveat A), fixed live against the shared Supabase instance (prod) and re-verified.

### Security

- **SEC-06 (HIGH) — nomination public wrappers were anon-executable.** `migration_nomination_public_wrappers.sql` (v0.4.1) created `public.search_members_for_nomination`, `public.submit_nomination`, and `public.admin_add_nomination` and granted `service_role`, but never REVOKEd PostgreSQL's default `PUBLIC` EXECUTE grant. Because these wrappers live in the PostgREST-exposed `public` schema, any holder of the public anon key could invoke them directly. `admin_add_nomination` has no internal authorization (it relies on the Next.js admin-secret gate), so `POST /rest/v1/rpc/admin_add_nomination` with the anon key allowed **nomination stuffing**; the token-gated wrappers were similarly reachable. Fix: `REVOKE EXECUTE ... FROM PUBLIC, anon, authenticated` on all three public wrappers, re-asserting `service_role` — mirroring `migration_lock_public_vote_wrappers.sql`. The `private` counterparts were already correctly locked in `migration_nomination_submission.sql`. Applied live via Supabase MCP; `has_function_privilege` confirms `anon=false, authenticated=false, service_role=true` on all three.

### Run order

- No new file. The REVOKE/GRANT block is appended to `supabase/migration_nomination_public_wrappers.sql` (CANONICAL run order item 24 / AGENTS.md item 15); the file remains idempotent and self-contained.

## [0.4.1] - 2026-09-05

Hotfix: the v0.4.0 nomination flow was inert over HTTP. Caught during Playwright UAT and fixed live against the shared Supabase instance (prod), then verified end-to-end.

### Fixed

- **Nomination HTTP flow silently returned empty** — `migration_nomination_submission.sql` created `search_members_for_nomination`, `submit_nomination`, and `admin_add_nomination` only in the `private` schema, which is not PostgREST-exposed. `supabaseServer.rpc('<fn>')` resolved against `public` (function not found) and the routes' `.schema('private').rpc(...)` fallback also failed (private unexposed), so both routes swallowed the error to an empty result: roster search returned `{results: []}` for every query and submit would have failed identically. The private function logic itself was correct (direct call returned matches). Fix: `supabase/migration_nomination_public_wrappers.sql` adds `public` SQL SECURITY DEFINER wrappers (`SET search_path = public, private`) forwarding to each private RPC, plus `GRANT EXECUTE ... TO service_role` — mirroring `migration_public_wrappers.sql`. No application code change (routes already call `public` first). Applied live via Supabase MCP; UAT confirmed search + submit + token-consumption + anonymity-preserving row insert end-to-end.

### Run order

- Run `supabase/migration_nomination_public_wrappers.sql` **after** `migration_nomination_submission.sql` (CANONICAL run order item 24 / AGENTS.md item 15).

## [0.4.0] - 2026-09-04

Adds the anonymous **nomination submission** flow (token-gated write-in + roster-search nominations, admin adjudication) plus the oracle security-review follow-ups. Ships with two DB migrations (`migration_nomination_submission.sql`, `migration_nomination_hardening.sql`) that land at the next destructive wipe — see run order below.

### Added

- **Nomination submission flow**: token-gated `POST /api/nominate` (write-in + up to the configured `max_nominees_per_member` picks) and `POST /api/nominate/search` (trigram roster search, minimal id+name fields, non-consuming token check). Anonymous by construction — `submit_nomination` reads `tokens.member_id` only to validate/consume the token and **never** writes any nominator identity onto `anonymous_nominations`. Admin out-of-band `admin_add_nomination` (source=`ADMIN`) and an adjudication panel (PROMOTE/MERGE/DISCARD). `anonymous_nominations` is RLS-locked + append-only (immutability trigger). Verified anonymity-invariant-holds by oracle review.

### Security

Oracle security review of the nomination RPCs found the anonymity invariant intact (no CRITICAL/HIGH); the following defense-in-depth follow-ups (1 MED + 4 LOW + one cleanup) are folded in:

- **SEC-01** (MED) `/api/nominate` and `/api/nominate/search` now **fail closed** (`503`) when the `check_rate_limit` RPC errors, instead of continuing unlimited.
- **SEC-02** (LOW) the per-token rate-limit identifier is now `nominate_search_tok:<HMAC_SHA256(secret, tokenHash)>` (secret = `RATE_LIMIT_SECRET` ?? `ADMIN_SECRET`), so the stored identifier is no longer a direct join key back to `tokens.token_hash`.
- **SEC-02b** new `private.cleanup_rate_limit_hits(older_than_seconds)` (SECURITY DEFINER, explicit `search_path`, service_role only) globally reclaims stale `rate_limit_hits` rows that per-identifier cleanup leaves behind, plus a standalone `idx_rate_limit_hits_created_at` index (the existing composite index leads with `identifier`).
- **SEC-03** (LOW) `EXECUTE` on `check_rate_limit(TEXT, INT, INT)` revoked from `PUBLIC`, `anon`, `authenticated`; only `service_role` retains it. (Lives in the new hardening migration, not the already-applied `migration_rate_limit.sql`.)
- **SEC-04** (LOW) API-boundary validation on the nominate/search routes: nominee count capped at 3, `reason` ≤ 2000, write-in name ≤ 100, search query ≤ 100, and `nominee_member_id` UUID-format-checked before it reaches a Postgres `::UUID` cast (avoids malformed-input 500s). Mirrors the DB-side caps as defense-in-depth.
- **SEC-05** (LOW) `submit_nomination` reads `election_settings` with `FOR SHARE`, so an admin phase-cutover `UPDATE` blocks until the in-flight submission commits — closing the read-phase / insert race without leaving partially-committed nominations.

### Run order (CRITICAL)

- Run `supabase/migration_nomination_submission.sql` **after** the CANONICAL sequence, then `supabase/migration_nomination_hardening.sql` **after** both that and `migration_rate_limit.sql`. Best applied at the second destructive wipe (Option B); not on production now.

## [0.3.0] - 2026-09-03

Closes the Tier 1 public-deanonymization hole in ballot IDs and fixes the spoil/reissue token lock. **Requires a destructive DB wipe + re-seed before any real votes** — existing plaintext ballot IDs cannot be retroactively anonymized.

### Security

- **Opaque ballot IDs (Tier 1 anonymity fix)**: `ballot_id = private.hmac_sign(payload)` where `hmac_sign` returns `payload || '.' || signature` — the payload half is **publicly visible** (only signed, not encrypted) and ballot IDs appear on the public verify page. The generated payloads embedded linkable identifiers in cleartext: digital `submit_anonymous_vote` emitted `<member_id>:<candidate_id>:<epoch>:<rand>` (any member of the public could read *who voted for whom*); legacy `issue_paper_ballot` emitted `PAPER:<member_id>:…`; `generate_blank_paper_ballot_batch` emitted `PAPER:BLANK:<batch_id>:<index>:…`. `supabase/migration_opaque_ballot_ids.sql` redefines all three RPCs to emit pure-random opaque payloads (`'DIGITAL:'|'PAPER:' || encode(gen_random_bytes(32),'hex')`) with **no** member/candidate/batch identifiers and **no** timestamp. `hmac_sign`/`hmac_verify` are unchanged (paper RPCs still HMAC-verify ballot IDs downstream); `candidate_id` is dropped from the digital payload because `ballots.candidate_id` already stores it. Design reviewed by oracle.

### Fixed

- **Spoiling a handout-reserved paper ballot now frees the digital token**: `issue_preprinted_paper_ballot` reserves the member's `VOTING` token (`is_used=TRUE, channel_sent='PAPER'`) at handout. `spoil_paper_ballot` marked the ballot `SPOILED` but never released that reservation, so a re-assign was rejected with "Member has already voted digitally." `supabase/migration_fix_spoil_frees_token.sql` redefines `spoil_paper_ballot` to reset the reserved token (`is_used=FALSE`) — only for `ISSUED_TO_VOTER` ballots (never `VOTED`, which the status guard already forbids), idempotently.

### Run order (CRITICAL)

- `migration_opaque_ballot_ids.sql` and `migration_fix_spoil_frees_token.sql` must run **LAST** — after `migration_enforce_token_expiry.sql`, `migration_fix_paper_rpcs.sql`, and Option E part2. In particular, **do not re-run `migration_enforce_token_expiry.sql` after `migration_opaque_ballot_ids.sql`** — it redefines `submit_anonymous_vote` with the old leaky payload and would reintroduce the digital deanonymization hole.
- **Re-seed cleanup**: the truncate/wipe must also clear `vote_audit_log` and `paper_ballot_batches` (in addition to `ballots`, `paper_ballots`, `tokens`), or stale rows survive the re-seed.



Adds admin-configurable voting-link validity (token TTL) and documents the voter-authentication / proxy-voting threat model.

### Added

- **Configurable voting-token TTL**: the voting magic-link validity window is now admin-editable instead of hardcoded at 7 days. New `election_settings.voting_token_ttl_hours` column (default `168`h = 7 days, bounded `1..2160`h by API validation + a DB `CHECK` constraint); new `GET`/`PATCH /api/admin/settings` route (`requireAdmin` / `requireAdminWithCsrf`, audit-logged as `SETTINGS_UPDATED`, returns the authoritative DB value); a "Voting Link Validity" control in the dashboard Election Settings tab (reuses the existing `apiFetch` CSRF mechanism). `app/api/admin/tokens-dispatch/route.ts` now reads the configured TTL once per dispatch (applied to `VOTING` only; nomination stays 24h; fails fast on a real settings-query error, benign fallback `168`) and reflects it in the email expiry text; the effective TTL is recorded in the dispatch audit log. Migration `supabase/migration_configurable_token_ttl.sql` is additive/non-destructive (no re-seed required).

### Docs

- **Proxy-voting threat model documented** (`docs/TECHNICAL_GUIDE.md`): digital magic-links are possession-based (a forwarded link can be used by the recipient); *voluntary* delegation cannot be prevented on any remote channel; the paper channel provides in-person identity assurance and is the high-assurance path; an out-of-band "name + candidate" email is explicitly rejected (it would destroy ballot anonymity); at-cast-time SMS OTP is recorded as a deferred hardening option, not implemented.

## [0.2.4] - 2026-09-01

Removes the orphaned legacy RPC overload that v0.2.3 locked down.

### Removed

- **Dead `submit_paper_vote(VARCHAR, UUID)` overload dropped**: `supabase/migration_drop_legacy_paper_vote_overload.sql` drops the orphaned `(p_member_code VARCHAR, UUID)` overload of `private.submit_paper_vote`. It was a historical artifact — the design voted by `member_code` but the implementation switched to `ballot_id` (TEXT), and because `CREATE OR REPLACE` keys on argument types the TEXT version created a second function instead of replacing it. Verified dead: the sole call site (`app/api/admin/paper-vote/route.ts`) passes `p_ballot_id`, and no migration recreates the VARCHAR signature. Private schema, not PostgREST-exposed.

## [0.2.3] - 2026-09-01

Follow-up hardening after the v0.2.2 token-expiry enforcement (SEC-06): closes two gaps where tokens or RPC access were left inconsistent with the new policy.

### Fixed

- **CLI-issued tokens had no expiry**: `scripts/dispatch-tokens.js` and `scripts/test-digital-vote.js` inserted `VOTING` tokens without `expires_at`, unlike the API route (`app/api/admin/tokens-dispatch/route.ts`). After the SEC-06 migration, `NULL` expiry is treated as expired, so CLI-issued tokens were born-invalid (and the test script would reject its own vote). Both scripts now set `expires_at = now + 7 days` to match the API path.

### Security

- **Legacy RPC overload left executable (#3 follow-up)**: `supabase/migration_lock_public_vote_wrappers.sql` revoked only `private.submit_paper_vote(TEXT, UUID)`; a legacy `(VARCHAR, UUID)` / `p_member_code` overload retained the PostgreSQL `PUBLIC` default, leaving `anon`/`authenticated` with `EXECUTE`. Added an explicit `REVOKE` for that signature. Verified live via `has_function_privilege`.

### Notes

- The `submit_paper_vote(VARCHAR, UUID)` overload appears to be dead/legacy code (the active path uses the `(TEXT, UUID)` / `p_ballot_id` signature). It is now locked but not dropped; a `DROP` is deferred pending confirmation that nothing calls it.

## [0.2.2] - 2026-09-01

Correctness and security-hardening follow-ups from a design-alignment review: fixes broken digital voting, enforces token expiry end-to-end (SEC-06), tightens phase-token binding (SEC-07), closes a vote-choice information leak, and locks down direct RPC access.

### Fixed

- **Digital voting could not load candidates (#2)**: `app/vote/[token]/page.tsx` populated its candidate list from the `verify-token` response, which never returned candidates, so the ballot was always empty. The page now fetches `GET /api/candidates` after successful token verification.
- **Admin dashboard render loop / lint failure**: the inactivity auto-logout timer was React state (`setInactivityTimer` inside `resetInactivityTimer`, with the timer in an effect dependency array), causing a cascading re-render loop; `handleLogout` was also referenced before declaration. The timer handle is now a `useRef`, and `handleLogout`/`resetInactivityTimer` are declared after state so they reference setters safely.
- **Token expiry not enforced (SEC-06 completion)**: `expires_at` (voting 7 days / nomination 24 h) was stored but never checked. Expiry is now enforced at the route layer (`app/api/auth/verify-token/route.ts`, `app/api/vote/route.ts`) and, defense-in-depth, inside the `private.submit_anonymous_vote` RPC under its row lock (`supabase/migration_enforce_token_expiry.sql`).
- **Phase confirmation tokens not fully bound (SEC-07 hardening)**: `app/api/admin/phase/route.ts` now re-checks the pending token's `admin_session_id` and `expires_at` at the `execute`/`execute_reset` steps (not just at issuance), and the `cancel` action can delete a pending token even after it has been marked used.
- **Vote-choice information leak (#7)**: `app/api/verify/route.ts` no longer returns `candidate_name` while the election is in the `VOTING` phase, so a receipt lookup cannot reveal how someone voted before voting closes.

### Security

- **Direct RPC access lockdown (#3)**: `supabase/migration_lock_public_vote_wrappers.sql` revokes the PostgreSQL default `PUBLIC` (plus `anon`/`authenticated`) `EXECUTE` on all public vote/ballot wrapper functions and their `private` counterparts (including the Option E wrappers and `private.submit_anonymous_vote`), and adds `ALTER DEFAULT PRIVILEGES ... REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC` future-proofing so these SECURITY DEFINER RPCs cannot be invoked directly with the anon key via PostgREST.

### Chore

- Replaced 6 `no-explicit-any` usages in `tests/uat.spec.ts` with precise types.

### Notes

- The two SQL migrations must be run manually in the Supabase SQL Editor: `migration_lock_public_vote_wrappers.sql` after the public + Option E part 2 wrapper migrations, and `migration_enforce_token_expiry.sql` after `migration_token_expiry.sql` and Option E part 2. Existing `VOTING` tokens with `expires_at IS NULL` become invalid under the new policy — backfill before running if such tokens exist.

## [0.2.1] - 2026-09-01

Bug-fix release addressing issues found during post-v0.2.0 acceptance testing, including a SEC-05 regression that blocked CSV member import for phone numbers.

### Fixed

- **CSV import phone regression (SEC-05)**: `sanitizeCell` prefixed values starting with `+` with a single quote to prevent CSV formula injection, which corrupted phone numbers (country codes start with `+`) and caused "Invalid phone format" errors. The `phone` column now skips sanitization in both the API route (`app/api/admin/members-import/route.ts`) and the CLI importer (`scripts/import-members.js`); all other columns remain sanitized.
- **Phase confirmation email link CSRF error**: `confirm`/`verify_reset_token` actions are now handled before the auth/CSRF gate in `app/api/admin/phase/route.ts`, so clicking the confirmation email link no longer fails.
- **Three-fold confirmation integrity**: the email link only marks its token used (no phase change); phase changes occur solely via the `execute` action. Old tokens are invalidated when a new request is made, and used tokens are deleted after execution.
- **Concurrent phase-change/reset prevention**: added a guard plus a `cancel` action and Cancel/Continue UI for pending (used or unused) confirmation tokens, with a 1-hour `used_at` filter on pending detection.
- **Current Phase card auto-update**: the admin dashboard now refreshes stats after execute/execute_reset/cancel so the top-right Current Phase card updates without a manual reload; phase fetch uses `no-store`.
- **Verify page Ballot ID field**: removed `ballotId` from a `useEffect` dependency array in `app/verify/page.tsx` that was clearing user input.
- **Reset confirmation text validation**: `confirmText` limit corrected to `{min:5,max:7}` (`RESET`=5, `CONFIRM`=7) in `lib/input-validation.ts`.

### Changed

- **Admin rate limit**: raised from 10 to 120 req/min in production (`proxy.ts`) to accommodate legitimate multi-call dashboard usage; dev remains 1000/min.

### Chore

- Added `test-results/` and `playwright-report/` to `.gitignore` and untracked previously committed Playwright output.

## [0.2.0] - 2026-08-19

Major security hardening release implementing 21 security findings (SEC-01 through SEC-21) across authentication, authorization, input validation, audit logging, and configuration hardening. All changes validated by 36 automated UAT tests and comprehensive manual testing guide.

### Added

**Security Hardening (21 findings)**

- **SEC-01**: HttpOnly cookie-based admin authentication with 30-minute sessions, replacing localStorage secret storage
- **SEC-02**: Removed legacy direct reset endpoint that bypassed three-fold confirmation
- **SEC-03**: Distributed rate limiting via Supabase RPC (admin: 10/min, vote: 5/min, search: 30/min) replacing in-memory Map
- **SEC-04**: Admin identity tracking in audit logs via session IDs and IP addresses
- **SEC-05**: CSV formula injection sanitization (prefixes `=`, `+`, `-`, `@`, `\t`, `\r` with `'`)
- **SEC-06**: Token expiry for voting (7 days) and nomination (24 hours) tokens
- **SEC-07**: Phase change tokens bound to requesting admin session
- **SEC-08**: Security headers (CSP, HSTS, X-Frame-Options, X-Content-Type-Options, Referrer-Policy, Permissions-Policy)
- **SEC-09**: Generic error messages in production via centralized `api-errors` utility
- **SEC-10**: CSRF protection via double-submit cookie pattern (non-HttpOnly CSRF cookie + `x-csrf-token` header)
- **SEC-11**: Member search rate limiting (30 req/min per IP)
- **SEC-12**: Candidate photo URL validation (HTTPS only, scheme validation)
- **SEC-13**: Configuration validation at module load (APP_BASE_URL, FROM_EMAIL, required env vars, production hardening)
- **SEC-14**: Vote API rate limiting (5 req/min per IP)
- **SEC-15**: Minimized verify-token response (no candidate list leakage)
- **SEC-16**: Input length limits on all text fields (candidates, members, tokens, phases)
- **SEC-17**: Admin dashboard auto-logout on 15-minute inactivity
- **SEC-18**: Tamper-evident audit logs with SHA-256 hash chaining (RPC + fallback)
- **SEC-19**: Text/plain email alternatives for all HTML emails (phase change, reset, token dispatch)
- **SEC-20**: Production config hardening (strong secrets, HTTPS enforcement, weak secret detection)
- **SEC-21**: Dependency scanning and SBOM generation (`npm run audit`, `npm run sbom`, `npm run security:check`)

**Admin Dashboard Enhancements**

- Phase Control with three-fold confirmation (email link → type CONFIRM → final dialog)
- Reset Election with three-fold confirmation (email link → type RESET → final dialog)
- Token Dispatch for voting/nomination tokens with expiry display
- Candidates CRUD with photo URL validation
- Members Management with activate/deactivate
- Audit Log Viewer with filters (action, member, date range, pagination)
- Election Dates management (nomination/voting start/end)

**Database Migrations (5 files)**

- `admin_sessions` table for cookie-based sessions
- `rate_limit_hits` table + `check_rate_limit()` RPC function
- `tokens.expires_at` column with indexes
- `phase_change_tokens.admin_session_id` foreign key
- `vote_audit_log` hash chaining columns + `insert_audit_log()` / `compute_audit_log_hash()` RPCs

**Testing & Documentation**

- 36 automated UAT tests covering auth, tabs, phase change, reset, token dispatch, public pages, API security
- Manual UAT testing guide (`docs/UAT_MANUAL_TESTING.md`) for voters and admins
- Security audit report with 21 findings mapped to OWASP Top 10 2025

### Changed

- Admin authentication: localStorage → HttpOnly cookie + JWT-style sessions
- Phase change flow: legacy direct reset removed, three-fold confirmation enforced
- Rate limiting: in-memory → distributed Supabase RPC
- Audit logs: `admin_id` now populated, hash chaining for tamper evidence
- Error responses: generic in production, detailed in development
- Email templates: added text/plain alternatives
- Config validation: fails fast in production on missing/invalid env vars

### Security

- Eliminated admin secret exposure in localStorage (XSS theft vector)
- Eliminated phase/reset bypass via legacy endpoint
- Eliminated CSV formula injection risk
- Eliminated token indefinite validity
- Eliminated audit log repudiation (admin identity + hash chain)
- Eliminated CSRF on state-changing admin actions
- Eliminated information leakage via error messages
- Eliminated weak configuration in production

### Fixed

- Hydration mismatch on admin dashboard (suppressHydrationWarning + mounted state)
- Admin auth bypass on mount (now verifies with server)
- CSV import email required for paper voting members (now optional)
- Phase transition DB trigger now allows COMPLETED → SETUP for admin reset

### Deprecated

- `x-admin-secret` header authentication (legacy, replaced by cookie sessions)

---

## [0.1.0] - 2026-08-11

First functional release. Privacy-first voting system for a 300-member community electing a Committee Head, with digital (magic-link) and paper ballot channels.

### Added

**Core voting system**
- Two-domain Supabase schema: identity (`members`, `tokens`) vs anonymous (`ballots`, `candidates`)
- `SECURITY DEFINER` RPCs in `private` schema (`submit_anonymous_vote`, `submit_paper_vote`) — not exposed via PostgREST, `REVOKE EXECUTE FROM anon, authenticated`
- CSPRNG receipt codes generated inside the RPC with 5-attempt retry on collision (`gen_random_bytes`)
- Token-in-URL-path delivery (`/vote/<token>`) — avoids access-log/Referer leakage
- Random 8-char member codes (not sequential/guessable)
- Admin route authentication via `x-admin-secret` header + per-IP rate limiting (10 req/min)

**Paper ballot workflow**
- `paper_ballots` table with HMAC-signed ballot IDs (`PAPER:<uuid>:<timestamp>:<hmac>`)
- `vote_audit_log` table for issue/record/spoil audit trail
- Private RPCs: `issue_paper_ballot`, `submit_paper_vote`, `submit_paper_invalid`
- Public wrapper functions forwarding to private RPCs
- Admin dashboard: issue paper ballot (with printable QR), record vote (via in-app scanner or short code), spoil ballot (with reason)
- QR codes encode URL payload (`${APP_BASE_URL}/verify?ballot_id=<id>`) — native phone cameras (iOS/Android) recognize as tappable links
- In-app `html5-qrcode` scanner with `extractBallotId()` helper (handles both URL and legacy raw-text QR)
- Human-readable short code fallback (e.g. `VEK8-T48G-GQU0`)

**Public pages**
- Home page (`/`) with live election phase badge, nomination/voting period display, token entry
- Vote page (`/vote/[token]`) — token verification, candidate selection, receipt code display
- Verify page (`/verify`) — public vote verification with URL auto-fill (`?ballot_id=` query param pre-fills form), receipt code match for digital votes
- Results page (`/results`) — public results with receipt lookup, vote bars, percentages (published only after `VOTING_CLOSED` or `COMPLETED` phase)

**Admin APIs**
- `GET /api/admin/members` — member search with voting status (ELIGIBLE / DIGITAL_VOTED / PAPER_ISSUED / PAPER_VOTED), QR regeneration
- `POST /api/admin/paper-ballot` — issue paper ballot with 512px PNG QR
- `POST /api/admin/paper-vote` — record paper vote (defensive URL extraction if full verify URL pasted)
- `POST /api/admin/paper-invalid` — spoil ballot with reason
- `GET /api/admin/stats` — turnout (hides live turnout during active voting — anti-coercion)

**Public APIs**
- `GET /api/candidates` — active candidate list
- `GET /api/election/status` — election phase + schedule
- `POST /api/auth/verify-token` — token validation
- `POST /api/vote` — digital vote submission
- `GET /api/verify` — ballot lookup by ballot_id
- `GET /api/results` — published results + receipt lookup

**Documentation**
- `docs/SECURITY.md` — honest threat model (anonymity vs admin, mitigation commitments)
- `README.md` — quick start + privacy model summary

**Scripts**
- `scripts/dispatch-tokens.js` — sends magic-link emails via Resend (self-contained, dotenv)
- `scripts/import-members.js` — imports members from CSV

### Security

- Anonymity guaranteed against other voters and the public; admin has technical ability to correlate (documented honestly in `docs/SECURITY.md`)
- No live turnout during active voting (anti-coercion)
- Paper votes enter canonical tally (`ballots` row with `channel='PAPER'`)
- `service_role` GRANTs on `paper_ballots` + `vote_audit_log` (fixes silent ELIGIBLE mislabel)
- `pgcrypto` search_path fix for Supabase Cloud (extension lives in `extensions` schema)

### Deprecated

- `middleware.ts` → `proxy.ts` (Next.js 16 convention; `middleware` file convention is deprecated)
