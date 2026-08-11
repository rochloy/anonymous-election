# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
