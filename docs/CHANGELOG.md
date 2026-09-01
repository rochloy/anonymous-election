# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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