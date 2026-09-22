# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

**Live-DB note (0.2.3):** the `REVOKE EXECUTE ON FUNCTION private.submit_paper_vote(VARCHAR, UUID) FROM PUBLIC, anon, authenticated;` statement was applied directly to the running Supabase database (the lockdown migration had already been run pre-patch); re-running the migration file is idempotent.

## [0.15.1] - 2026-09-21

Wave 10 **post-launch fixes and UX improvements** (`agent/wave10-fixes` + inline fixes). Mobile Tally Wizard shipped in v0.15.0; this patch adds dashboard integration, eligibility phase-gating, and Record/Spoil UX cleanup. **No DB migration, no schema change.** Requires a Vercel redeploy (`vercel --prod`).

### Added

- **Mobile Wizard QR code button:** admin dashboard header now has "📱 Mobile QR" button that shows a QR code modal linking to `/admin/mobile` for easy phone access.
- **Checked-in member marking:** mobile wizard search results now show "Checked-in" or "Voted" badge for already-processed members, with select button disabled to prevent duplicate check-ins.
- **Eligibility phase-gating (SETUP-only):** Voter Eligibility tab now shows read-only mode during non-SETUP phases (NOMINATION, VOTING, etc.). API rejects eligibility changes outside SETUP with 400 error. Toggle buttons, reason dropdown, note field, and save button all disabled when not in SETUP.

### Fixed

- **Phase detection:** mobile wizard now correctly reads `current_phase` from phase API response (was using wrong field name).
- **Unicode escapes:** replaced `\uXXXX` escapes with actual UTF-8 characters in mobile wizard components.
- **Tab order:** mobile wizard default tab is now Check-in during VOTING phase (most common action), Record otherwise.
- **Dashboard search lookahead:** both "Search & Issue Paper Ballot" (Tab 1) and "Voter Eligibility" (Tab 9) now have debounced live search (300ms, ≥2 chars) matching the mobile wizard pattern.

### Changed

- **Record/Spoil UX:** extracted QR scanner and Ballot ID field into shared "Ballot Lookup" section above both panes. Admin scans/types once, then decides Record or Spoil. Both buttons auto-disable when Ballot ID is empty.

## [0.13.1] - 2026-09-18

Paper-severance **app-layer reconciliation** (`agent/paper-severance-reconciliation`). The Wave 6 DB migration split paper ballots into two never-joined planes — `paper_ballots` (identity: `short_code`, `member_id`) and `anonymous_paper_blanks` (anonymous: `ballot_id`/QR) — but the admin app still called superseded RPCs and rendered pre-severance shapes, causing runtime failures and one member↔ballot co-location surface. **App/UI + docs only — no DB migration, no schema change.** Requires a Vercel redeploy (`vercel --prod`). Anonymity invariant re-certified by review (no `member_id`↔`ballot_id` co-location in any row/RPC/response/view).

### Fixed

- **Member search 500 (Phase 1):** `app/api/admin/members/route.ts` queried dropped columns against the severed schema; now reads the identity plane only and returns a `paperCheckIn {shortCode,status,checkedInAt,checkedInDate}` + `votingStatus` shape. Removed the member-row ballot-QR leak.
- **`DIGITAL_VOTED` misclassification:** paper check-in also sets `tokens.is_used`; status is now gated on `channel_sent==='DIGITAL'` so paper check-in no longer shows as a digital vote.
- **Superseded paper RPCs (Phase 2):** `paper-batch` → `generate_anonymous_blank_ballot_pool` (QR built from returned `ballot_ids[]`); `paper-ballot` → identity-only `issue_paper_ballot` (QR removed, returns `short_code`); `paper-invalid` → severed split (`spoil_paper_check_in` by `short_code` **xor** `void_anonymous_paper_blank` by `ballot_id`); `paper-void-unused` → `void_unused_anonymous_paper_blanks(p_admin_id, p_reason)` bulk void-all-unused (corrected against live DB).
- **Dashboard reconciliation:** issued-ballot modal is now an identity slip (`short_code` + member name/code, no QR); anonymous pool tiles render `ballot_id` QR sheets with no member identity; removed the dead "Assign on phone" mobile-assign feature (link/QR/handler/state) after the route deletion below.

### Removed

- **Forbidden member↔ballot assignment path (2C):** deleted `app/api/admin/paper-assign/route.ts` (called `issue_preprinted_paper_ballot(p_ballot_id, p_member_id, …)` — the arg set is itself a co-location of identity + ballot handle) and its `app/admin/mobile-assign/page.tsx` UI, plus all dashboard assign buttons/handlers. Per-member paper issuance is the identity-slip flow (`issue_paper_ballot`).

### Security

- **Anonymity invariant re-certified (@oracle full-diff review):** no durable row, RPC arg set, RPC return set, HTTP body, or rendered view co-locates `member_id`/member name/code with `ballot_id`/`candidate_id`. The anonymous pool sheet legitimately carries `ballot_id` + candidate choices (the physical ballot) with zero member linkage.

## [0.13.0] - 2026-09-17

Wave 7 — **Digital-channel severance (transient-reservation two-phase voting)** (`agent/v0.13.0-wave7-digital-severance`). Introduces an opt-in two-phase digital writer that separates token redemption from vote cast while preserving the no-colocation anonymity invariant and hard channel mutual exclusion with paper check-in. **Mixed change type:** one new DB migration plus API/UI updates; migration is backward-safe at apply time (`LEGACY` default) and requires explicit operator mode-switch to activate.

### Added

- **Terminal migration item 35:** `supabase/migration_wave7_digital_severance.sql` appended to CANONICAL run order after item 34 (Wave 6 paper severance). Adds transient-reservation digital primitives and mode-gating controls.
- **Election settings controls for digital severance:**
  - `election_settings.digital_write_mode` (`LEGACY` default, enum-checked `LEGACY | TWO_PHASE`)
  - `election_settings.digital_credential_ttl_minutes` (default `15`, CHECK `1..1440`)
- **Two-phase digital API contract (mode-gated):**
  - `POST /api/vote/redeem` (`{token}` → `{credential, ttlSeconds}`)
  - `POST /api/vote/cast` (`{credential, candidateId}` → `{receiptCode, ballotId}`)
  - `POST /api/vote/release` (`{token}`)
  - all three return HTTP `409 LEGACY_MODE` unless `digital_write_mode='TWO_PHASE'`

### Changed

- **Digital write path is operator-switchable.** Applying migration 35 does not change live behavior by itself; operators opt in with `UPDATE election_settings SET digital_write_mode='TWO_PHASE' WHERE id=1;` and can revert to `LEGACY`.
- **Legacy endpoint behavior in TWO_PHASE mode:** `POST /api/vote` remains the legacy single-call path, but returns HTTP `409 TWO_PHASE_REQUIRED` when `digital_write_mode='TWO_PHASE'`.
- **Admin member status model:** dashboard now surfaces **`RESERVED`** (amber, pulsing "in progress — resolves automatically") for members with a live digital reservation.

### Security

- **Reserve-don't-consume two-phase semantics:** redeem reserves the entitlement; cast finalizes the vote; unused reservations can be explicitly released or expire/sweep to free the token for re-redeem.
- **Anonymity invariant preserved in Wave 7 path:** no durable row / RPC arg / RPC return / audit row / screen co-locates identity handles (`token`/`member`/`short_code`) with vote handles (`ballot_id`/`candidate`/`credential`/`receipt`).
- **Paper/digital mutual exclusion (fail-closed, race-free):** `check_in_paper_voter` refuses paper check-in while a live DIGITAL reservation exists, and digital redeem refuses when the token is reserved by PAPER.

## [0.12.1] - 2026-09-16

Docs & hygiene follow-up to Wave 5 (`agent/wave5-docs-finalize`). **Docs + `.gitignore` only — no app/schema code changed; no redeploy, no live-DB change.**

### Documentation

- Finalized Wave 5 docs: `README.md` (Admin Dashboard Voter Eligibility tab + Purge Roster PII danger zone, expanded Privacy Model, migration-freshness pointer to `TECHNICAL_GUIDE`), `docs/USER_GUIDE.md` (Voter Eligibility tab reference + Purge danger-zone flow + DOB-never-stored data-minimization note), project `AGENTS.md` (env-gated `LOGIN_RATE_LIMIT_MAX`, live-DB Playwright UAT, `--reporter=list`, Wave 5 migration 30–33 note).
- **`docs/SECURITY.md` GDPR / Real-PII Readiness section** documenting the council NO-GO verdict (findings F1–F15 with GDPR articles + remediation track) and a **NOT-GDPR-ready / synthetic-data-only** status banner (real-PII deferred to v0.13.0 Security/Anonymity Wave).

### Security / Privacy

- **`/data/` and `/archives/` gitignored**; `data/members.csv` (real test email addresses) **untracked** (`git rm --cached`) to stop ongoing versioning. Full git-history purge deferred to the v0.13.0 real-data cutover.

## [0.12.0] - 2026-09-16

Wave 5 — **GDPR Privacy Subsystem** (`agent/wave5-privacy-design`). Voter-eligibility governance (general `voting_eligible` boolean + reason codes + source), DOB-free age derivation, two-channel eligibility enforcement (digital dispatch + paper issuance + vote-cast defense-in-depth), an in-DB never-truncated governance ledger, and a two-stage roster-PII purge. **Mixed change type:** three new DB migrations (30–32, plus adjudication RPC 33) applied via Supabase MCP (no redeploy); admin routes + dashboard UI (`app/admin/dashboard/page.tsx`) **require a Vercel redeploy** (`vercel --prod --yes`). Five roadmap decisions locked (see `docs/specs/2026-09-15-wave5-privacy-design.md`): (a) UNDETERMINED → ineligible/fail-closed (configurable); (b) general eligibility boolean + reason codes; (c) both channels enforced; (d) derived-boolean-only age (DOB never persisted); (e) reject-and-replace raw export by design (aggregate-only; council `cou-1`).

### Added

- **Governance processing-activity ledger** (`supabase/migration_wave5_governance_ledger.sql`, migration 30): `governance.processing_activity_ledger` (append-only, never-truncated — survives the disposable wipe) + `append_governance_event(...)` (11-arg) recording controller/purpose/lawful-basis/data-categories per GDPR Art. 30. Option A (in-DB) per design.
- **Voter-eligibility schema** (`supabase/migration_wave5_eligibility_schema.sql`, migration 31): `members.voting_eligible` / `eligibility_reason` / `eligibility_source` / `is_age_eligible`, CHECK-constrained reason (`ELIGIBLE`/`AGE_UNDER_MIN`/`NOT_A_MEMBER`/`MANUAL_ADMIN_HOLD`/`UNDETERMINED`/`INACTIVE_MEMBER`/`PURGED`) and source (`SYSTEM_DEFAULT`/`CSV_IMPORT`/`ADMIN_ADJUDICATION`/`SYSTEM_RECOMPUTE`/`PURGE`) with an eligible↔reason consistency invariant; append-only `eligibility_adjudications` audit table. 301 existing members backfilled `ELIGIBLE`/`SYSTEM_DEFAULT`.
- **Two-channel eligibility enforcement** (`supabase/migration_wave5_eligibility_enforcement.sql`, migration 32 — **final writer** for `submit_anonymous_vote`/`issue_paper_ballot`/`issue_preprinted_paper_ballot`): a token-eligibility trigger + eligibility gates in the ballot RPCs (defense-in-depth at cast), plus `purge_roster_pii(admin, stage, confirm)`.
- **Atomic eligibility adjudication RPC** (`supabase/migration_wave5_eligibility_adjudication.sql`, migration 33): `adjudicate_eligibility(...)` — member-locked members override + append-only audit row in one SECURITY-DEFINER transaction, with consistency/no-op/not-found guards; `is_age_eligible` preserved (factual, not adjudicated). Public wrapper `service_role`-only.
- **Admin routes**: `POST /api/admin/eligibility` (→ `adjudicate_eligibility`) and `POST /api/admin/purge` (→ `purge_roster_pii`), both `requireAdminWithCsrf` + `insertAuditLog`, mirroring the nominations-adjudicate pattern. Members listing now exposes the three eligibility fields.
- **Dashboard UI** (`app/admin/dashboard/page.tsx`): a **Voter Eligibility** tab (member search, eligibility badge/reason/source, per-row eligible/ineligible adjudication with reason locked to `ELIGIBLE` when eligible, note) and a **Purge Roster PII** danger zone (two-stage CONTACT/IDENTITY, type-`PURGE` confirmation, grounded gate-condition copy).

### Changed

- **DOB-free eligibility derivation on import** (`app/api/admin/members-import/route.ts`): age eligibility is computed in-memory at import and only the derived `is_age_eligible` boolean is persisted — **the DOB is never stored** (decision d). UNDETERMINED age (missing/invalid DOB) defaults to ineligible, configurable via `undetermined_eligibility_defaults_ineligible` (decision a).
- **VOTING token dispatch gated on eligibility** (`app/api/admin/tokens-dispatch/route.ts`): ineligible members are excluded with a structured `failures[]` (`code: VOTER_INELIGIBLE`) + `eligibilityFailedCount`. NOMINATION dispatch is not gated.

### Removed

- **`scripts/dispatch-tokens.js` retired** (`git rm`) — superseded by the eligibility-gated dispatch route; live references removed from `AGENTS.md`/`README.md`/`TECHNICAL_GUIDE`. Historical CHANGELOG/plan/spec references left intact.

### Security / Privacy

- **Raw personal-data export forbidden by design** (decision e, council `cou-1`): no application path exports raw `members`/`tokens`/`vote_audit_log`; aggregate export only (`scripts/export-results.js`). Raw extraction is an out-of-band, documented DBA procedure.
- **`member_code` anonymized at purge Stage 2 (IDENTITY)**; contact PII (email/phone) cleared at Stage 1 (CONTACT, gated on VOTING_CLOSED/COMPLETED); identity redaction gated on the 30-day dispute window. All purge actions governance-audited.

### Notes

- Every DB migration was UAT-proven by a rolled-back `DO`-block sentinel harness (`ENFORCEMENT_UAT_OK`, `ADJUDICATION_UAT_OK`) leaving live data unchanged. Canonical run order (items 30–33, with the migration-32 final-writer warning) is in `docs/TECHNICAL_GUIDE.md`.
- Documentation posture finalized: `docs/SECURITY.md` now includes an explicit GDPR/real-PII readiness section with a NO-GO status banner (synthetic-data-only until Security/Anonymity Wave v0.13.0).

## [0.11.1] - 2026-09-15

Wave 7 — **Data-Hygiene: wipe-list correctness + disposable-reuse runbook** (`agent/wave7-wipe-list`). Pre-go-live safety and documentation. **No app code changed** — `seed.sql` (a wipe fixture) + docs + one standalone archive script; **no Vercel redeploy, no live-DB change**. The original roadmap premise ("wipe doesn't clear `tokens`") was **stale** — `seed.sql` already truncated `tokens`/`ballots` and the one-vote guard was already present; the BACKLOG re-verify rule caught it. The real gap was five tables cleared only by a prose note.

### Fixed

- **`seed.sql` now truncates all election-scoped tables in one statement.** `supabase/seed.sql` previously truncated only 5 tables; `vote_audit_log`, `paper_ballot_batches`, `admin_sessions`, `phase_change_tokens`, and `rate_limit_hits` were cleared only by a prose instruction in the TECHNICAL_GUIDE — a footgun for anyone replaying from the `.sql` source. Expanded to a single 10-table `TRUNCATE … CASCADE` + `DELETE FROM members`. `admin_sessions` shares the CASCADE with `vote_audit_log` because `vote_audit_log.admin_id → admin_sessions` is `ON DELETE RESTRICT` (`migration_fix_admin_id_fk.sql`); a combined TRUNCATE is the only FK-valid path. **FK-safety proven** by a rolled-back `DO`-block UAT (no data wiped). The now-false "seed.sql does not clear these" claim was reconciled in `docs/TECHNICAL_GUIDE.md` and project `AGENTS.md`.

### Added

- **`scripts/export-results.js` — anonymous aggregate results archive.** One-command pre-wipe archive of the published tally (per-candidate counts + total) to `archives/` as JSON + CSV. Mirrors `app/api/results/route.ts` (requires phase `VOTING_CLOSED`/`COMPLETED`). **Exports no personal data** — queries only `election_settings`, `candidates`, and `ballots.candidate_id`; never `members`/`tokens`/`vote_audit_log`/`paper_ballots`. This is the compliance-safe default for the disposable model; governed raw-table export is deferred to Wave 5.
- **`seed.sql` purpose + run-order runbook** and a **"reusing one deployment across elections / organizations (disposable model)"** runbook in `docs/TECHNICAL_GUIDE.md`: the archive → wipe → reload cycle, per-election vs. global-config caveats (`ADMIN_SECRET`/`APP_BASE_URL`/sender are shared), and the "wiped-together = clean anonymity" property.

### Deferred

- **Wave 5 (GDPR) gains a governed raw-export decision.** Roadmap decision (e) + scope item 3: raw `members`/`tokens`/`vote_audit_log` export must be non-default, authorized, audit-logged, and documented with its risks + regulatory obligations + procedure. Captured in `docs/plans/2026-09-13-post-demo-roadmap.md` and memory (`mem_20260915_4u9s`).

## [0.11.0] - 2026-09-15

Wave 6 — **UX Polish Bundle** (`agent/wave6-ux-polish`). Five independent quality-of-life fixes across the admin dashboard, nomination flow, and paper-ballot printing. **Mixed change type:** four are app/UI (`app/admin/dashboard/page.tsx`, `app/nominate/[token]/page.tsx`) and **require a Vercel redeploy** (`vercel --prod --yes`); one is a DB-function-only change (`search_members_for_nomination`) applied via Supabase MCP that needs **no redeploy**.

### Fixed

- **Nomination short-prefix search now matches.** `private.search_members_for_nomination` used the bare pg_trgm `%` similarity operator, which scores a short prefix poorly against a long full name — e.g. typing `andr` matched only 1 of 8 `Andrew …` members. Replaced with a hybrid predicate `full_name ILIKE p_query || '%' OR p_query <% full_name` (word_similarity), ordered by `word_similarity DESC` — the `ILIKE` arm **guarantees** the exact-prefix case while `<%` keeps fuzzy/typo tolerance. Shipped as new terminal migration `supabase/migration_wave6_nomination_prefix_search.sql` (final writer, supersedes item 22's predicate); signature/return/guards/ACL preserved byte-identical. **Applied to the live DB via Supabase MCP; UAT-proven read-only** (`andr`: old 1/8 → new 8/8).
- **Nomination success message spacing** (`app/nominate/[token]/page.tsx`): explicit `{' '}` separator so "N nomination(s) recorded" renders correctly (minification-robust).

### Added

- **Member-picker typeahead on Assign Preprinted Ballot** (`app/admin/dashboard/page.tsx`): the raw Member-ID text input is now a debounced typeahead (reuses `GET /api/admin/members-manage`), mirroring the existing out-of-band nomination roster search. The Wave-2 `hasUnsavedWork` re-auth guard was extended so an in-progress search still counts as unsaved. Submit contract (`assignMemberId`/`assignBallotId`) unchanged.
- **Model A issued-ballot print layout** (`app/admin/dashboard/page.tsx`): the "Issued Paper Ballot" modal gained a **Print Ballot** button and a print-only (`hidden print:block`) block reusing Model B's existing `globals.css` ballot classes, so a singly-issued Model A ballot prints cleanly (parity with Model B). The `fixed`-overlay modal stays `print:hidden` (printing a fixed backdrop is unreliable).
- **Token Dispatch "Select All with Email"** (`app/admin/dashboard/page.tsx`, Tab 7): Select All now selects only members with a non-empty email; email-less rows are greyed (`opacity-60`), get a `NO EMAIL` badge and a disabled checkbox, and a live "N selectable / M without email" count is shown. The dispatch POST payload is filtered to exclude email-less members.

### Verified

- **Playwright route-mocked UAT GREEN** (`tests/wave6-dispatch-email.spec.ts`, zero DB mutation): 4 assertion groups — live count label, email-less rows disabled + `NO EMAIL` badge, Select All checks only email-having rows, and dispatch POST payload excludes email-less IDs. `1 passed`.
- **DB predicate UAT** proven read-only against live member data (old `%` vs new `ILIKE`/`<%`). `npm run build` + `npm run lint` clean (pre-existing 19 warnings only).

## [0.10.0] - 2026-09-15

Wave 4 — **Digital Voter Self-Verification (receipt-freeness preserved)** (`agent/wave4-self-verification`). Lets a digital voter confirm, on their own device, that their vote was **recorded** — without ever emailing a receipt and without revealing who they voted for. Closes a pre-existing coercion vector in the same pass. **App/API/UI change** — **requires a Vercel redeploy** (`vercel --prod --yes`). No DB migration (verification is a read path over existing `ballots` columns).

### Security

- **Removed the candidate-name disclosure from public verification.** `app/api/verify/route.ts` previously returned the cleartext candidate name to anyone holding a `ballot_id` once `current_phase != 'VOTING'`. That made any leaked/coerced identifier a transferable proof of *how* someone voted. The route now returns only `{ found, channel, cast_date }` (plus optional `receipt_match`) in **every** branch and phase — candidate is never selected or emitted. This was treated as an in-wave prerequisite because Wave 4 surfaces a self-verification identifier, which would otherwise amplify the leak (@oracle design ruling).
- **Verification by `receipt_code` (not `ballot_id`).** Digital self-verification uses the short `VC-…` receipt code the voter already sees post-vote; the digital `ballot_id` is **never** returned to the browser (`app/api/vote/route.ts` unchanged, still returns only `{ success, receiptCode }`). Receipt lookup is format-validated (`^VC-[0-9a-fA-F]{10}$`) then canonicalized to the stored form before an exact `.eq()` — case-insensitive for the voter, but with **no `ilike`/LIKE-wildcard path** (a `%` input can never reach the query and enumerate rows). Malformed codes return `{ found: false }`, not an error.

### Added

- **Device-local receipt affordances on the vote success screen** (`app/vote/[token]/page.tsx`): **Copy** and **Download/Print receipt** actions, all client-side (no server call, no email), with a "save this privately — it is not emailed to you" note. Receipt stays in ephemeral React state only — **no `localStorage` auto-persist** (avoids forensic residue on shared devices). Fake-receipt deniability was explicitly **excluded as out-of-scope** (YAGNI for this threat model, per @oracle).
- **Reframed `/verify` page** (`app/verify/page.tsx`) around "Confirm Your Vote Was Recorded": receipt code is the primary field, ballot-ID kept as a secondary paper-QR path (still auto-fills from `?ballot_id=`), candidate display removed, and reassurance copy stating the check confirms the vote was recorded — not who it was for.

### Verified

- **API UAT GREEN** against the live DB (read-only, no data mutated), using a real seeded digital receipt while the election was in phase `COMPLETED` — the exact condition under which the old code revealed the candidate. Cases: valid receipt → `{found, DIGITAL, cast_date}` **no candidate**; wrong-case receipt → still found (case-insensitive fix); nonexistent → `{found:false}`; `%` wildcard-injection attempt → `{found:false}` (regex guard); `ballot_id`+receipt → `receipt_match:true`, no candidate; no params → `400`; **`ballot_id`-only in `COMPLETED` phase → no candidate** (the leak, proven closed); candidate-field grep across every branch → clean. `/verify` SSR smoke: new framing renders, no candidate label. `npm run build` + `tsc --noEmit` + `npm run lint` clean (pre-existing warnings only).

## [0.9.0] - 2026-09-15

Wave 3 — **Paper-Ballot Integrity: token-reserve-at-issue (Model A)** (`agent/wave3-paper-token-reserve`). Closes a double-vote window where a Model A paper ballot could be issued while the member's digital voting token stayed live, allowing both a paper and a digital vote. **DB-function-only change (RPC bodies)** — applied via Supabase MCP; **no Vercel redeploy** (no app/API/UI code changed). Model B (`issue_preprinted_paper_ballot`) already reserved at handout; this brings Model A to parity.

### Security

- **Model A `issue_paper_ballot` now reserves the voting token at issue.** The function locks the member's `VOTING` token `FOR UPDATE` **before** inserting the paper ballot — the same lock order as `submit_anonymous_vote` — then marks it `is_used=TRUE, channel_sent='PAPER'`. A concurrent digital vote therefore cannot win the race and miss the uncommitted paper row: whichever path acquires the token-row lock first forces the other to fail its guard (paper issue → "already voted digitally"; digital vote → "already used or reserved for paper voting"). Token-state guard rejects issue when the token is already used (PAPER reservation or digital), and a `>1` non-voided-token check hard-fails as an integrity error before any write.
- **`spoil_paper_ballot` releases the reservation symmetrically.** The token-free branch now covers `status IN ('ISSUED','ISSUED_TO_VOTER')` (was `ISSUED_TO_VOTER` only), so spoiling a now-reserved `ISSUED` Model A ballot returns the member to eligible. The critical `channel_sent='PAPER'` predicate is retained — a genuine digital/`EMAIL` token is **never** cleared by a spoil.

### Verified

- DB UAT **GREEN** via a rolled-back (`RAISE EXCEPTION`) transactional harness against the live schema — no seed data mutated. Cases: reserve-at-issue (token→PAPER, no digital ballot row); digital-vote-blocked-after-issue; `submit_paper_vote` after reserved issue (one `PAPER` ballot, status `VOTED`); **spoil-frees-`ISSUED`** (token→`is_used=FALSE, used_at=NULL`); spoil-frees-`ISSUED_TO_VOTER` (Model B unregressed); **spoil does NOT free an `EMAIL` token** (synthetic bad fixture — the guard test); used-digital-token-blocks-paper-issue; paper-only member (no token, no-op reserve/free); and the multiple-non-voided-token integrity hard-fail. Concurrency (case 9) is guaranteed by the shared token-row `FOR UPDATE` lock ordering. The DB partial unique index `tokens_one_live_per_member_type` (`WHERE is_used=false AND voided_at IS NULL`) is defence-in-depth against a second *unused* live token.

### Source-of-truth / rebuild note

- The fix ships as a new terminal migration `supabase/migration_wave3_paper_token_reserve.sql`, now the **final writer** for `issue_paper_ballot` + `spoil_paper_ballot` (supersedes items 19/20). Added to the CANONICAL run order in `docs/TECHNICAL_GUIDE.md` as **item 28** — it MUST run last of the paper-ballot writers, or a rebuild would reintroduce the double-vote gap. Historical migrations were left immutable per project convention (no edit to part2).

## [0.8.1] - 2026-09-14

Discoverability fix for the mobile ballot-assignment feature (`agent/mobile-assign-link`). The `/admin/mobile-assign` wizard (shipped in 0.5.0) had **no navigational link anywhere in the app** — it was reachable only by typing the URL. UI-only change; **requires a Vercel redeploy**.

### Added

- **"Assign on phone" affordance in the admin dashboard header.** Two complementary controls, grouped with "Clear Admin Auth" as one secondary-action cluster: (1) a **text link** to `/admin/mobile-assign` (fast path when the admin is already on a phone/tablet), and (2) an on-demand **"Show QR"** toggle (collapsed by default) that lazily renders a QR of `${window.location.origin}/admin/mobile-assign` so an admin on a desktop can scan it with the phone they'll actually use, with the plain URL shown as selectable fallback text and an inline reminder that the phone needs its own mobile login. Additive header-only change to `app/admin/dashboard/page.tsx`; reuses the existing `qrcode` dependency and the file's `Image`+data-URL QR convention. Public homepage intentionally left unchanged (admin-only tool). No API/DB changes.

## [0.8.0] - 2026-09-14

Wave 2 — **Admin Session Security & In-Place Re-Auth** (`agent/wave2-admin-session`). Replaces absolute-only desktop admin sessions with a server-enforced **sliding 10-min idle window + 4-hour absolute cap**, adds a **differentiated 401 reason contract**, and introduces a **mid-task-safe in-place re-auth modal** that overlays the still-mounted dashboard so unsaved form state is never lost. **No DB migration** (reuses the existing `admin_sessions.revoke_reason` column). UI changes are included, so this release **requires a Vercel redeploy** (`vercel --prod --yes`) — not yet done.

### Added

- **In-place re-auth modal.** On a mutation 401, a focus-trapped modal (`role="dialog"`, Escape-locked, explicit "full login" escape) overlays the still-mounted dashboard so unsaved form input is preserved; re-auth mints a fresh session+CSRF (ASVS V7.2.4 rotation) and closes the modal with no auto-replay of the failed action. Reason-appropriate copy distinguishes idle vs 4-hour-cap expiry. Source: `app/admin/dashboard/page.tsx`.
- **Server-deadline session countdown.** A live countdown mirrors the server idle deadline with a ~2-min warning banner; a non-bumping 60s `/api/admin/me` poll proactively detects server-side expiry. Replaces the previous client-only 15-min inactivity timer (server is now authoritative).
- **`hasUnsavedWork` dirty-flag.** Drives the modal-vs-redirect branch: a background/passive 401 with unsaved work shows the modal (preserve state); with clean state it drops to a full login. 27 mutation call sites route their 401 to a central `handleSessionExpiry('mutation', reason)`.

### Security

- **Dual session timeout (desktop).** Sliding 10-min idle (`min(now+10min, created_at+4h)`) with a hard 4-hour absolute cap enforced server-side in `requireAdmin`/`getAdminSession`; idle is bumped only after auth+CSRF pass on a user-initiated mutation, never by the passive `/me` poll. Mobile is unchanged (12-min absolute, no sliding). Aligns with OWASP Session Management / ASVS v5 dual-timeout guidance.
- **Differentiated 401 reason contract.** 401 bodies carry `{ error, reason }` with `reason ∈ idle_expired | absolute_expired | unauthorized | revoked`, driving modal messaging. **Reason-bearing revoke:** expired sessions are revoked while **retaining `token_hash`** and storing a precise `revoke_reason`, so the differentiated reason survives repeated requests (previously a background `/me` poll that expired the session first nulled the hash, degrading the subsequent user mutation's reason to generic `unauthorized`). Revocation security is unchanged — a revoked row is still refused before any valid-session path (oracle-ratified: `token_hash` nulling was defense-in-depth, not the revocation boundary).
- **Session-fixation defense on re-auth.** Login revokes the prior session row before minting the new one; desktop cookie `maxAge=4h`; `Cache-Control: no-store` on login/`me`; `Clear-Site-Data` on logout and revoke-all; clickjacking headers (`CSP frame-ancestors 'none'`) retained.

### Verified

- Wave 2 UAT **GREEN** (`tests/wave2-session.spec.ts`, headless Playwright): **Scenario 1** — a mutation 401 after a forced absolute-cap expiry opens the re-auth modal on the still-mounted dashboard, preserves the unsaved field value, shows the 4-hour-limit copy, and re-auth closes the modal with state intact; **Scenario 2** — a forced idle expiry detected by the passive poll with clean state drops to the full login view. Expiry is forced deterministically by service-role backdating the session row keyed on the exact `admin_session` token hash. `npm run build` + `npm run lint` (0 errors / 19 baseline warnings) pass.

### Backlog (not in this wave)

- `__Host-` cookie prefix (breaks local http dev); concurrent-session view/terminate UI (revoke-all already exists).

## [0.7.0] - 2026-09-14

**Token Void & Reissue** (`agent/token-reissue`). Lets an admin void an unused voting/nomination token (recording a reason) and issue a fresh replacement link to the same member — for the common "member lost / never received their email link" case — without deleting audit history or reusing the dead token. UI changes are included, so this release **required a Vercel redeploy** (`vercel --prod --yes`, done). The DB migration below was **applied live to prod** via the Supabase MCP and its voided-token vote guard verified against the running instance.

### Added

- **Void & reissue route.** `POST /api/admin/tokens/reissue` (CSRF-guarded) voids a target unused token (setting `void_reason` + `voided_at`) and mints a replacement via the reissue RPC, linking the new token back through `reissued_from_token_id`. An empty/whitespace reason is **rejected** and the call is phase-gated (returns **409** when the election is not in a token-dispatchable phase). The replacement link is emailed via Resend; **send failures are surfaced as a `warning` while `success:true`** (the token is already reissued in-DB — the admin can re-dispatch). Emits audit entries. Source: `app/api/admin/tokens/reissue/route.ts`.
- **Token lineage + void columns.** `tokens` gains `void_reason`, `voided_at`, and `reissued_from_token_id` (self-FK, `ON DELETE NO ACTION`). A partial unique index enforces **one active token per member per type**, so a reissue cannot leave two live links. Source: `supabase/migration_token_reissue.sql`.

### Security

- **Voided tokens are vote-dead at the DB layer.** `private.submit_anonymous_vote` gains a voided-token guard: a voided (or expired / off-phase) token is rejected with `Voting phase is closed or expired.` and cannot insert a ballot, so a leaked or reissued-away link is inert independent of the app layer. Verified live end-to-end (API R1–R9 10/10; UI void → reissue → new link renders ballot, hash chain intact; a real email to a live inbox produced a working reissued link).

### Verified

- Full Spec 2 UAT **GREEN**: API curl matrix R1–R9 (10/10), UI U1–U4 (token rows render, empty-reason rejected, phase-gate 409 in modal, happy-path void & reissue with DB chain confirmed — old token voided with reason, new token VOTING-active with real SHA-256 hash and `reissued_from_token_id` set). Real-email test passed (reissued link opened the ballot page; first send landed in spam).
- Migration applied live via Supabase MCP (`apply_migration`) → `{success:true}`; voided-token vote guard **tested against known-bad input** (voided token → 0 ballots inserted, phase-closed rejection).

### Run order

- `supabase/migration_token_reissue.sql` — adds `tokens.void_reason` / `voided_at` / `reissued_from_token_id`, the single-active partial unique index, the reissue RPC, and the voided-token guard in `submit_anonymous_vote`. Idempotent. Run after Spec 1 / the base rebuild. Added as item 27 in the CANONICAL run order (`docs/TECHNICAL_GUIDE.md`).

## [0.6.0] - 2026-09-13

Wave 0.2 — **Member Management Integrity** (`agent/wave0-member-mgmt`). Adds phase-gated single-member add and activate/deactivate through DB RPCs, hardens both CSV import paths against re-import duplication, and locks the roster once voting opens. UI changes are included, so this release **requires a Vercel redeploy** (`vercel --prod --yes`). The DB migration below was **applied live to prod** via the Supabase MCP and its phase guard verified against the running instance.

### Added

- **Single-member add.** `POST /api/admin/members-manage` (CSRF-guarded) creates one member via the `create_member` RPC — Name required; Email, Phone, Member Code optional (an `M-<hex>` code is generated when omitted). Duplicate `member_code`/`email`/`phone` returns **409** (`MEMBER_UNIQUE_CONFLICT`, SQLSTATE 23505). Emits a `MEMBER_CREATED` audit entry. Dashboard **Tab 6** gains a style-matched Add-Member form.
- **Roster lock UI.** The dashboard Add form and Activate/Deactivate controls are disabled from **VOTING** onward (`rosterLocked` derived from existing `phaseInfo` state) with a "Roster locked — voting has started" note.

### Changed

- **Phase-gated roster edits (route + DB).** New `assert_electorate_editable()` guard permits member edits only in `SETUP` / `NOMINATION` / `NOMINATION_CLOSED`. Enforced in both the API routes and the `create_member` / `set_member_active` RPCs (no table trigger — `seed.sql` and migrations insert directly and stay exempt). `PATCH` activate/deactivate now routes through `set_member_active` so the gate applies.
- **Import keyed on `member_code`.** Both `scripts/import-members.js` and the dashboard `members-import` POST now upsert on **`member_code`** (was `email` in the CLI). Against a **non-empty** roster, rows lacking a `member_code` are **refused** (prevents the old random-code duplication); the dashboard import is additionally phase-gated. Initial empty-roster bulk load still accepts and generates codes. Dropped members are still **not** auto-deactivated (deactivate manually — members are never hard-deleted, since `tokens.member_id` / `paper_ballots.member_id` are `ON DELETE CASCADE`).

### Verified

- `@verifier` standard: **PASS** — `npm run build` clean, `npm run lint` 0 errors (19 warnings, baseline).
- Migration applied live via Supabase MCP (`apply_migration`) → `{success:true}`. Phase guard **tested against known-bad input**: calling `create_member` during the live `COMPLETED` phase was rejected with 0 rows inserted (`guard_test_rows=0`).

### Run order

- `supabase/migration_member_mgmt_phase_gate.sql` — private/public `assert_electorate_editable` + `create_member` + `set_member_active`, service_role-only grants. Idempotent `CREATE OR REPLACE`. Run after `seed.sql` (references `election_settings` id=1). Added as item 26 in the CANONICAL run order (`docs/TECHNICAL_GUIDE.md`).

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
