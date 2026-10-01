# Blueprint — Anonymous Election System

**Project:** Anonymous Election System
**Version:** v0.15.3 (main @ 1e890e3)
**Deployed:** Vercel (production, CLI-deployed)
**Document date:** 2026-10-01
**Note:** Corrected after a code-grounded accuracy review (2026-10-01).

Four sections in one document: **1. PRD** (Product Requirements) · **2. SDD** (Solution Design) · **3. Wireframes** (UI/UX) · **4. Master Prompt** (reproduction context).

---

# Section 1: Product Requirements Document (PRD)

## 1.1 Product Overview

A privacy-first voting system for a ~300-member community electing a Committee Head. It runs a single election per deployment and supports two ballot channels:

- **Digital voting** — single-use magic-link tokens emailed to members (via Resend), cast at `/vote/<token>`.
- **Paper voting** — in-person check-in issuing an *identity slip* (short code + member name), plus an *anonymous pre-printed ballot pool* whose QR codes carry no member identity. The system deliberately never links a member to a specific ballot.

Voter anonymity is guaranteed **against other voters and the public**. It is honestly *not* cryptographically guaranteed against an all-powerful admin holding the service-role key — this limitation is documented, not hidden (see `docs/SECURITY.md`).

## 1.2 Problem Statement

The community needs a secret-ballot election where:

1. Members can vote either remotely (from their email) or in person (paper ballot on election day).
2. No observer — other voter, public, or casual database browser — can learn *who voted for whom*.
3. Election staff can run check-in, ballot recording, and spoiling from desktop or phone under time pressure.
4. The outcome is verifiable (each voter can confirm their vote was recorded) without revealing vote content.
5. Data-protection obligations (GDPR-style minimization, adjudication audit, retention/purge) are met structurally, not by policy alone.
6. The deployment can be reused for a *future* election or a *different* organization — strictly serially — with no cross-election residue.

## 1.3 Goals

| # | Goal |
|---|------|
| G1 | One member, one vote — enforced across *both* channels with mutual exclusion. |
| G2 | Persistent anonymity: no durable record co-locating member identity with a ballot handle or candidate. |
| G3 | Admin-operable end-to-end without SQL: phase control, roster, candidates, tokens, paper ops, reporting. |
| G4 | Tamper-evident accountability for every admin action and governance event. |
| G5 | Results published only after voting closes (anti-coercion); per-voter receipt verification. |
| G6 | Clean single-command re-provisioning for the next election (data wipe + reseed) with governance continuity. |

## 1.4 Functional Requirements

MoSCoW priority: **MUST** (must have), **SHOULD** (should have), **MAY** (nice to have). Requirements marked ✅ are shipped as of v0.15.3.

### Election lifecycle

| ID | Requirement | Priority | Status |
|----|-------------|----------|--------|
| FR-01 | The system MUST run exactly one election per deployment at a time: `election_settings` is a single row (`id=1`); no table carries an `election_id`. Reuse across elections/organizations is strictly serial via a destructive wipe. | MUST | ✅ |
| FR-02 | The system MUST enforce an ordered phase machine: `SETUP → NOMINATION → NOMINATION_CLOSED → VOTING → VOTING_CLOSED → COMPLETED`, validated at both the API layer (`VALID_TRANSITIONS`) and the DB layer (`validate_phase_transition` trigger). | MUST | ✅ |
| FR-03 | Phase transitions and election reset MUST require three-fold confirmation: (1) request → confirmation email, (2) email link click verifies the token, (3) typed `CONFIRM`/`RESET` → final dialog → execute. | MUST | ✅ |
| FR-04 | Admin reset (`COMPLETED → SETUP`) changes *only* the phase — it MUST NOT delete ballots, tokens, members, or nominations. | MUST | ✅ |
| FR-05 | Election dates (nomination/voting start/end) MUST be admin-configurable. Dates are informational; they MUST NOT auto-advance phases. `voting_end` MUST be enforced by the vote RPC. | MUST | ✅ |
| FR-06 | The system MUST provide an in-app, SETUP-only, atomic, governance-logged **Danger Zone database wipe** (`private.wipe_election_data`) with escalating typed confirmation (`WIPE` → `DELETE ALL DATA`), leaving schema and HMAC key untouched and revoking all admin sessions. | MUST | ✅ (v0.15.2+) |
| FR-07 | A SQL-Editor reseed MUST remain available as the full-rebuild path (canonical 39-item migration run order; `seed.sql` is item 21 — last of the base rebuild, with later migration items applied after it). | MUST | ✅ |

### Membership & eligibility

| ID | Requirement | Priority | Status |
|----|-------------|----------|--------|
| FR-10 | Members MUST be addable singly (name required; email/phone/member_code optional; auto-generated `M-<hex>` code when absent) with duplicate `member_code`/`email`/`phone` rejected (409). | MUST | ✅ |
| FR-11 | Members MUST be bulk-importable from CSV (`full_name` required; email/phone/member_code/dob optional) and exportable as a minimal-field CSV. Import onto a non-empty roster MUST key on `member_code` and refuse codeless rows (strict mode). | MUST | ✅ |
| FR-12 | CSV import SHOULD offer an explicit **append mode**: codeless rows with email/phone are inserted with generated codes; contactless codeless rows are held for review (never silently inserted) with an Add button + soft name-match warning. | SHOULD | ✅ (v0.15.3) |
| FR-13 | Members are NEVER hard-deleted; removal MUST be deactivation (reactivation symmetric). | MUST | ✅ |
| FR-14 | All roster edits MUST be phase-gated: allowed in SETUP/NOMINATION/NOMINATION_CLOSED; locked from VOTING onward (API + DB guard `assert_electorate_editable()`). | MUST | ✅ |
| FR-15 | An opt-in **Allow adding members during voting** setting (default off, warning-labeled) MAY unlock create-only addition during VOTING for late in-person registration. | MAY | ✅ (Wave 9) |
| FR-16 | When the **Voter Age Requirement** is enabled, age eligibility MUST be derived at import time from a `DOB` (or asserted via an "Age eligible" checkbox — XOR with DOB; both → 400). The DOB is NEVER stored; only the derived `is_age_eligible` boolean persists. Missing/invalid DOB → `UNDETERMINED`, failing closed unless configured otherwise. | MUST | ✅ |
| FR-17 | Admins MUST be able to adjudicate per-member eligibility (`ELIGIBLE`/`AGE_UNDER_MIN`/`MANUAL_ADMIN_HOLD`/`UNDETERMINED`/…) with reason code + note via an atomic, audited RPC — SETUP phase ONLY; read-only in later phases. | MUST | ✅ (Wave 5 / v0.15.1 gate) |
| FR-18 | Eligibility MUST be enforced at dispatch AND at cast (defense-in-depth), on both digital and paper channels. | MUST | ✅ (Wave 5) |
| FR-19 | Members MUST be exportable as a minimal-field CSV (member_code, name, email, phone, active, eligibility) — the only sanctioned raw-PII export; the event is governance-logged as `MEMBER_DATA_EXPORTED`. | SHOULD | ✅ (v0.15.3) |

### Nominations

| ID | Requirement | Priority | Status |
|----|-------------|----------|--------|
| FR-20 | Members MUST be able to submit nominations via a token-gated page (trigram/prefix roster search or write-in, up to `max_nominees_per_member`). The nominator's identity MUST never be written to `anonymous_nominations` (token read only to validate/consume). | MUST | ✅ (v0.4.0) |
| FR-21 | Admins MUST be able to review and adjudicate nominations (PROMOTE/MERGE/DISCARD) via a single atomic RPC (no orphaned candidates). | MUST | ✅ (v0.4.3) |

### Digital voting

| ID | Requirement | Priority | Status |
|----|-------------|----------|--------|
| FR-30 | Each member MUST receive a unique, single-use, expiring magic link (`/vote/<token>`); token hashes are stored, not plaintext. Default voting-token TTL 168h, admin-configurable 1–2160h; nomination tokens 24h. | MUST | ✅ |
| FR-31 | Casting MUST be atomic: validate token → generate CSPRNG receipt code → insert anonymous ballot → mark token used, inside `private.submit_anonymous_vote`. A voided/expired/off-phase token MUST be rejected at the DB layer. | MUST | ✅ |
| FR-32 | The ballot ID on the ballot row MUST be opaque: `private.hmac_sign(payload)` = `payload || '.' || sig`, payload = `'DIGITAL:'/'PAPER:' || encode(gen_random_bytes(32),'hex')` — NO member/candidate/batch identifiers, NO timestamp. | MUST | ✅ (v0.3.0) |
| FR-33 | An opt-in **two-phase digital write mode** (redeem → cast → release, TTL-bound `DVC-` credentials) SHOULD be available and operator-switchable (`digital_write_mode` `LEGACY`/`TWO_PHASE`); the default remains LEGACY. Unused reservations MUST be releasable/expirable to free the token. | SHOULD | ✅ (v0.13.0 Wave 7) |
| FR-34 | Admins MUST be able to void & reissue an unused token with a mandatory reason; voided tokens are permanently dead (DB guard) and one active token per member per type is DB-enforced. | MUST | ✅ (v0.7.0) |
| FR-35 | Digital voters SHOULD receive a device-local receipt (`VC-…` code) they can copy/print, usable at `/verify` — with NO candidate disclosure at any phase and NO server email of the receipt. | SHOULD | ✅ (v0.10.0) |

### Paper voting

| ID | Requirement | Priority | Status |
|----|-------------|----------|--------|
| FR-40 | The system MUST maintain two **severed paper planes**: an identity plane (`paper_ballots`: `short_code` + `member_id`, no `ballot_id` column) and an anonymous ballot plane (`anonymous_paper_blanks`: `ballot_id` + status, member-blind — no member/voter columns exist). Audit is likewise split: `participation_audit` (identity-only) and `ballot_audit_log` (ballot-only), each with a CHECK rejecting the opposite plane's handles. | MUST | ✅ (v0.13.0 Wave 6) |
| FR-41 | Paper check-in MUST issue an identity slip (short code + member name, no QR) and consume/reserve the member's voting entitlement; entitlement lazy-provisioning MUST cover members without a prior token. | MUST | ✅ (Wave 8) |
| FR-42 | Admins MUST be able to generate a pool of 1–1000 anonymous pre-printed blanks with QR codes encoding `${APP_BASE_URL}/verify?ballot_id=<id>` (tappable by native phone cameras), printable as sheets (A6 4-up / 6-up), at QR **EC level Q** (zxing/iOS-Safari detectability). | MUST | ✅ |
| FR-43 | Staff MUST be able to record a paper vote (scan QR / enter ballot ID + candidate) via `submit_paper_vote`, and spoil/void ballots (`SPOILED`, `VOIDED_UNUSED`); these confirm-time RPCs are the security boundary. | MUST | ✅ |
| FR-44 | The system MUST provide scan-time validation (`GET /api/admin/paper-ballot-status` → `{exists, status}` only, member-blind) rejecting unknown/foreign/already-used QRs before the confirm screen. | MUST | ✅ (v0.15.2) |
| FR-45 | Status vocabularies MUST remain distinct: anonymous blanks (`anonymous_paper_blanks`) use `AVAILABLE / CAST / VOIDED`, while identity slips (`paper_ballots` / `paper_ballot_status`) use `AVAILABLE / ISSUED / ISSUED_TO_VOTER / VOTED / SPOILED / VOIDED_UNUSED / MISSING`. | MUST | ✅ |
| FR-46 | Paper and digital MUST be mutually exclusive per member, fail-closed and race-free (shared token-row `FOR UPDATE` lock ordering; paper check-in refuses a live DIGITAL reservation and vice versa). Spoiling an issued ballot MUST release the reservation — but never a genuine digital/`EMAIL` token. | MUST | ✅ (v0.9.0 / Wave 6) |
| FR-47 | Dispute path for a stuck digital reservation resolved to paper (Procedure C: physical blank surrender → spoil for dispute history → explicit token re-enable → paper flow) MUST exist and MUST be fail-closed (spoil never auto-releases a digital reservation). | MUST | ✅ (documented) |

### Admin surfaces

| ID | Requirement | Priority | Status |
|----|-------------|----------|--------|
| FR-50 | A desktop dashboard (`/admin/dashboard`) MUST provide nine persistent tabs: Search & Issue Paper Ballot • Preprinted Ballots • Record / Spoil Vote • Election Settings • Candidates • Members Management • Token Dispatch • Nominations • Voter Eligibility, plus a phase-gated Reporting tab. | MUST | ✅ |
| FR-51 | A Mobile Wizard (`/admin/mobile`) MUST provide phase-gated Check-in / Record / Spoil modes with QR scanning (`Html5QrcodeScanner`), a 📷 Photo fallback (downscale ≤1200px), scan-time validation, a 12-minute absolute session with countdown, and dark theme. | MUST | ✅ (v0.15.0–v0.15.2) |
| FR-52 | Dashboard SHOULD mirror operation messages into a fixed-position auto-dismissing toast (`role="status"`) so feedback is visible on long pages. | SHOULD | ✅ (v0.15.3) |
| FR-53 | Reporting (VOTING+ phases) MUST show admin-only anonymous aggregates (checked-in, paper recorded, digital votes, per-candidate tally), with progress CSV export; results CSV export MUST be locked until voting closes. | MUST | ✅ |

### Public surfaces

| ID | Requirement | Priority | Status |
|----|-------------|----------|--------|
| FR-60 | Public pages MUST exist: `/` (status/phase/dates), `/vote/[token]`, `/verify` (receipt-code primary, ballot-ID secondary), `/results` (locked until VOTING_CLOSED), `/nominate/[token]`. | MUST | ✅ |
| FR-61 | `/verify` MUST never reveal the voted candidate — it returns only existence/channel/cast-date (+optional receipt match) in every phase. | MUST | ✅ (v0.10.0) |
| FR-62 | During active voting, turnout counters MUST be hidden on public status and `/api/admin/stats`; privileged admin Reporting still exposes aggregate counts/tallies during VOTING (operational trade-off accepted). | MUST | ✅ |

## 1.5 Non-Functional Requirements

| ID | Requirement | Priority | Status |
|----|-------------|----------|--------|
| NFR-01 | **Anonymity invariant** (core, security): no durable row, RPC argument set, RPC return set, HTTP body, or rendered view co-locates member identity (`member_id`/name/code) with a vote handle (`ballot_id`/`candidate_id`/credential/receipt). v0.13.1 re-certification covered schema/app co-location controls; it does not eliminate timestamp/query-log correlation residuals documented in `docs/SECURITY.md`. | MUST | ✅ |
| NFR-02 | **Fail-closed defaults (where implemented):** eligibility unknown/UNDETERMINED defaults to denial, and unknown/invalid paper ballot IDs are denied by record/void RPCs; rate-limiter failure behavior is per-surface (not globally fail-closed). | MUST | ✅ |
| NFR-03 | **Secrets**: service-role key never bundled to client; admin secret never stored client-side (HttpOnly cookie sessions); env config validated at module load (production fails fast; `ADMIN_SECRET` ≥32 chars; `APP_BASE_URL` HTTPS in prod). | MUST | ✅ |
| NFR-04 | **Session security**: admin cookie sessions — desktop sliding 10-min idle + 4h absolute cap; mobile 12-min absolute; CSRF double-submit on all state-changing admin APIs; session-fixation defense on re-login; differentiated 401 reasons. | MUST | ✅ |
| NFR-05 | **Rate limiting** distributed via Supabase RPC (serverless-safe): admin proxy 120 req/min, vote 5 req/min, member search 30 req/min, login 5 attempts/min. Current limiter-error policy is mixed by surface: login fails closed; admin proxy, vote, and member search fail open. (per-surface failure policy is being revised in OpenSpec change rate-limit-failure-policy) | MUST | ✅ |
| NFR-06 | **Tamper-evidence**: `vote_audit_log` hash-chained (SHA-256, SEC-18) and append-only (trigger); `governance.processing_activity_ledger` append-only, hash-chained, survives wipes. | MUST | ✅ |
| NFR-07 | **HTTP hardening**: per-request CSP with nonce + `strict-dynamic` (`blob:` in img-src for file-scan), HSTS, frame-ancestors none, nosniff, Referrer/Permissions policies. | MUST | ✅ |
| NFR-08 | **Performance**: scale is a 300-member community — all flows are O(single-digit round-trips); search is debounced (300 ms, ≥2 chars); scanner decode loops are client-side. No horizontal perf work required beyond serverless-correct rate limiting. | SHOULD | ✅ |
| NFR-09 | **Deployability**: Vercel CLI only (`vercel --prod`); `git push` does NOT deploy; rollback via `vercel rollback <url>`. Stateless app; all state in Supabase. | MUST | ✅ |
| NFR-10 | **Dependency hygiene**: `npm run audit` (high), CycloneDX SBOM (499 components, all permissive licenses; SBOM snapshot 2026-09-25), `npm run security:check`. | SHOULD | ✅ |
| NFR-11 | **Data protection**: GDPR-style Art. 30 governance ledger; two-stage roster PII purge (contact fields after close; identity anonymization after 30-day dispute window); wipe/erasure runbook covering DB + filesystem + object storage + backup retention. | MUST | ✅ (Wave 5) |

## 1.6 Out of Scope

- Cryptographic end-to-end verifiability or admin-proof zero-knowledge anonymity (the admin/service role can correlate by construction — documented honestly).
- Multi-election concurrency or tenant isolation (one deployment = one election; reuse is strictly serial).
- Proxy-voting prevention on the digital channel (possession-based by design; voluntary delegation is unpreventable remotely; SMS-OTP second channel is a recorded, deferred option — not implemented).
- Raw roster/token/audit export as a routine function (only the sanitized Members CSV and anonymous aggregate results are exportable).
- Automated phase advancement from clock time (phases are admin-driven by design).
- Fake-receipt deniability / coercion-resistance beyond hidden-turnout + receipt-minimality (explicitly excluded at v0.10.0 — YAGNI for this threat model).

## 1.7 Success Metrics

| Metric | Target |
|--------|--------|
| Double-vote attempts (cross-channel) | 0 succeed (DB-enforced) |
| Anonymity violations (member↔ballot co-located rows) | 0 — structural CHECK constraints make them unwritable |
| Ballot ID identifier leakage | 0 — payloads pure-random since v0.3.0 |
| Election day admin task time (check-in / record / spoil) | single scan + confirm per action on mobile |
| Full-lifecycle UAT | Playwright suite A–L + API negatives green before go-live |
| Audit completeness | every admin mutation emits a hash-chained audit row; every governance event a ledger row |


---

# Section 2: Solution Design Document (SDD)

## 2.1 System Context

```
                        ┌─────────────┐
                        │   Members    │  voters (digital magic-link or paper)
                        └──────┬───────┘
                               │ HTTPS
        ┌──────────────────────┼──────────────────────┐
        │                      │                      │
   ┌────▼─────┐         ┌──────▼──────┐        ┌──────▼──────┐
   │  Public  │         │    Voter    │        │    Admin    │
   │  pages   │         │ vote/verify │        │ dashboard / │
   │ /,/results│        │ /nominate   │        │ mobile wiz  │
   └────┬─────┘         └──────┬──────┘        └──────┬──────┘
        └──────────────────────┼──────────────────────┘
                               │ all HTTPS, Vercel edge
                    ┌──────────▼──────────┐
                    │  Next.js 16 app     │  proxy.ts: CSP nonce + rate-limit
                    │  (Vercel serverless)│  API routes (service-role)
                    └──────────┬──────────┘
              ┌────────────────┼─────────────────┐
              │                │                 │
       ┌──────▼──────┐  ┌──────▼───────┐  ┌──────▼──────┐
       │  Supabase   │  │   Resend     │  │   Browser   │
       │  Postgres   │  │  (magic-link │  │ camera /    │
       │  (private   │  │  + confirm   │  │ photo scan  │
       │  RPCs, RLS) │  │  emails)     │  │ (html5-qr)  │
       └─────────────┘  └──────────────┘  └─────────────┘
```

External actors: **Members** (voters), **Admin staff** (election committee), **Supabase** (data + auth-grant boundary), **Resend** (email delivery). No other services.

## 2.2 Component Architecture

Layered, with the *security boundary at the RPC layer*:

| Layer | Component | Responsibility |
|-------|-----------|----------------|
| Presentation | `app/` (pages, dashboard, mobile wizard, public) | Renders UI; no secrets; CSRF auto-attach |
| Transport/edge | `proxy.ts` | Per-request CSP nonce + `strict-dynamic`, distributed rate-limit pre-check |
| API | `app/api/**` route handlers | Auth (`requireAdmin`/`requireAdminWithCsrf`), input validation, orchestrate RPCs |
| Lib | `lib/` (`supabase-server`, `api-errors`, `input-validation`, `audit-log`, `config-validation`, `ballot`) | Shared server-side primitives; service-role client singleton (server-only) |
| Data/DB | Supabase `private` schema RPCs (`SECURITY DEFINER`) | Atomic multi-step mutations for core voting/check-in/reporting flows; anonymity enforcement; eligibility gates |
| Public DB | `public` wrapper functions | Thin forwards to private RPCs, `service_role`-only grants, PostgREST-exposed |

**Key invariants:**
- Core vote/check-in mutations are RPC-driven, but some route handlers still perform direct table writes (for example: admin login session creation, member post-create eligibility update, phase/date updates, and audit inserts).
- `service_role` key lives only in `lib/supabase-server.ts` (never in client bundles, never in `.env.local` as a DB password).
- Anonymous and identity planes are *separate tables* with *split audit*; no view joins them.

## 2.3 Data Model — Severed Planes

```
IDENTITY PLANE (who)                    ANONYMOUS PLANE (what)
─────────────────────                   ─────────────────────
members                                 candidates
  id, member_code, full_name,             id, name, statement, photo
  email, phone, is_active,                is_active
  voting_eligible, eligibility_reason,
  eligibility_source, is_age_eligible   ballots
  (NO ballot_id, NO candidate)            id, ballot_id (opaque HMAC),
                                          candidate_id, channel,
tokens                                    receipt_code, cast_date
  id, member_id→members, token_hash,      (NO member_id, NO identity)
  type, is_used, channel_sent,
  expires_at, voided_at,                anonymous_paper_blanks  ★ member-blind
  reissued_from_token_id                  ballot_id, status, timestamps,
                                          void_reason
paper_ballots  ★ identity-only            (NO member_id, NO voter cols)
  id, short_code, member_id→members,
  status, timestamps
  (NO ballot_id column — severed)

SPLIT AUDIT                             GOVERNANCE (survives wipe)
───────────                             ─────────────────────────
vote_audit_log (ballot-only,            governance.
  hash-chained SEC-18)                    processing_activity_ledger
participation_audit (identity-only)        (append-only, hash-chained,
ballot_audit_log (ballot-only)             RoPA; WIPE_STARTED/
  each CHECK-rejects the other's           WIPE_COMPLETED/…)
  plane's handles
eligibility_adjudications (append-only)
```

**Two-domain core** (identity vs anonymous) plus **severed paper plane** (paper identity vs blank pool) — the four-way separation is the anonymity mechanism.

## 2.4 Core Data Flows

### Digital vote (LEGACY mode)
```
Member → /vote/<token> → POST /api/vote
  → private.submit_anonymous_vote (SECURITY DEFINER, row lock):
     1. validate token (phase, expiry, not voided, eligibility)
     2. receipt_code = CSPRNG (gen_random_bytes, 5-try collision retry)
     3. ballot_id = hmac_sign('DIGITAL:'||random(32))  ← opaque
     4. INSERT ballots (ballot_id, candidate_id, channel='DIGITAL')
     5. UPDATE tokens SET is_used=TRUE
  → return { success, receiptCode }   ← ballot_id NEVER returned
```

### Paper flow (three distinct operations, severed)
```
CHECK-IN (identity plane only):
  Admin scans/searches member → check_in_paper_voter
    → ensure_voting_entitlement (lazy-create if absent)
    → lock token FOR UPDATE, reserve (is_used, channel_sent='PAPER')
    → INSERT paper_ballots (short_code, member_id)   ← NO ballot_id
    → audit participation_audit
    → return short_code (identity slip)

POOL GENERATION (anonymous plane only):
  Admin generate batch → generate_anonymous_blank_ballot_pool
    → INSERT anonymous_paper_blanks (ballot_id=opaque, status='AVAILABLE')
    ← NO member_id anywhere

RECORD VOTE (anonymous plane only, member-blind):
  Admin scans QR → GET /api/admin/paper-ballot-status → {exists,status}
    → (client gate: reject unknown/used)
  Confirm → submit_paper_vote
    → INSERT ballots (ballot_id, candidate_id, channel='PAPER')
    → UPDATE anonymous_paper_blanks SET status='CAST'
    → audit ballot_audit_log
    → return { success, message, receipt_code }   ← NO member identity
```

### Phase change (three-fold confirmation)
```
Admin click "Advance to X"
  → POST /api/admin/phase {action:'request'}
     → create phase_change_token (1h TTL, bound to admin_session_id)
     → email confirmation link to ADMIN_EMAIL
Admin clicks email link → /admin/phase/confirm
  → {action:'confirm'} verify token (marks used, does NOT change phase)
Admin returns, types CONFIRM
  → {action:'execute'} → re-validate token + session binding
     → UPDATE election_settings.current_phase (DB trigger validates transition)
```

## 2.5 Security Design (per control)

| Control | Mechanism | Notes |
|---------|-----------|-------|
| Anonymity (member↔ballot) | Severed planes + opaque ballot IDs + split audit + CHECK constraints + member-blind confirm RPCs | Core invariant; re-certified v0.13.1 |
| Admin auth | HttpOnly cookie session, `admin_sessions` (token SHA-256 hash), idle+absolute TTLs | No localStorage secret |
| CSRF | Double-submit: `admin_csrf` cookie + `x-csrf-token` header; `requireAdminWithCsrf` on mutations | |
| Rate limiting | `check_rate_limit` RPC (sliding window, atomic), per-IP + per-token HMAC'd identifiers | Login fails closed; admin proxy/vote/member-search currently fail open (being revised in OpenSpec change `rate-limit-failure-policy`) |
| Session binding | Phase/reset tokens bound to `admin_session_id`, re-checked at execute | SEC-07 |
| Audit tamper-evidence | SHA-256 hash chain (`record_hash` links `previous_hash`), append-only trigger | SEC-18 |
| Governance ledger | Separate `governance` schema, append-only, hash-chained, wipe-surviving | RoPA / Art. 30 |
| RPC access lockdown | REVOKE EXECUTE from PUBLIC/anon/authenticated on all wrappers; `ALTER DEFAULT PRIVILEGES` future-proof | SEC (0.4.2/0.2.2) |
| Input validation | Length caps, email/phone/URL format, CSV formula-injection sanitization, UUID pre-check | |
| Error handling | Generic production errors (`apiError()`), detailed in dev, server-only logging | SEC-09 |
| CSP/headers | Per-request nonce + `strict-dynamic`; `blob:` in img-src for file-scan; HSTS, frame-ancestors none | |
| Config validation | Module-load fail-fast; prod requires strong secret + HTTPS base URL | SEC-13/20 |

## 2.6 Configuration Management

Single source of truth: **environment variables** (`.env.local` / Vercel env) + **DB `election_settings`** row (id=1).

- Env (deployment identity — shared across serial elections): `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, `APP_BASE_URL`, `RESEND_API_KEY`, `FROM_EMAIL`, `ADMIN_SECRET`, optional `ADMIN_EMAIL`.
- HMAC key: `app.ballot_hmac_key` via `ALTER SYSTEM` (outside transaction), rotate per election as hygiene.
- `election_settings` (per-election): dates, `voting_token_ttl_hours` (1..2160), age-requirement toggle + undetermined-default, `paper_ballot_layout` (SEPARATE_SLIP/SINGLE_SHEET, immutable once voting starts), `digital_write_mode` (LEGACY/TWO_PHASE), `digital_credential_ttl_minutes`, `allow_adding_member_during_voting`.

## 2.7 Error Handling Strategy

- API boundary: `lib/api-errors.ts` `apiError()` — generic message in prod, detailed in dev; consistent status codes (400 invalid, 401 auth+reason, 403 CSRF, 404, 409 conflict/state, 429 rate-limit, 500).
- RPC boundary: security-sensitive failures return `{success:false, message}` and roll back (each RPC is one transaction; wipe is atomic).
- Fail behavior is per-surface: eligibility/validation errors deny, while limiter errors are currently mixed (login closed; admin proxy, vote, member-search open).
- Audit atomicity applies to RPC-contained flows that write data + audit in one function; several route-level writes use separate calls (for example phase/date updates and subsequent audit insert).

## 2.8 Deployment Architecture

```
  GitHub repo ──(manual)──> vercel CLI ──build──> Vercel (serverless/edge)
                                                    │ HTTPS
                                              Supabase Postgres
                                                    ▲
  Admin laptop ──supabase MCP / SQL Editor──migrations + seed
```

- **No auto-deploy on git push.** Deploy only via `vercel --prod`; rollback via `vercel rollback <url>`.
- Migrations applied out-of-band via Supabase MCP / SQL Editor (39-file canonical run order); the app never runs DDL.
- New-election lifecycle: wipe (Danger Zone or SQL reseed) → review settings → import roster → candidates → ballot pool → advance phase.

## 2.9 Technology Stack

| Component | Technology | Version | Purpose |
|-----------|-----------|---------|---------|
| Framework | Next.js (App Router, Turbopack) | 16 | SSR + API routes |
| Language | TypeScript | 5.9 | Type safety |
| UI | React + Tailwind CSS (dark `prefers-color-scheme`) | 19 / v4 | Public + admin UI |
| Database | Supabase (PostgreSQL, RLS) | — | Data + SECURITY DEFINER RPCs |
| Email | Resend | — | Magic-link + confirmation delivery |
| QR generate | `qrcode` | — | Ballot/QR PNG generation |
| QR scan | `html5-qrcode` | 2.3.8 | In-app camera/file scanning |
| Hosting | Vercel | — | Serverless deployment + rollback |
| Testing | Playwright | — | UAT suites |
| SBOM | CycloneDX (`cyclonedx-npm`) | — | 499 components (SBOM snapshot 2026-09-25), permissive licenses |

## 2.10 Future Considerations

- SMS-OTP at-cast second channel (deferred proxy-voting hardening — only if demonstrated risk).
- Multi-admin principals (`admin_principals`) — deferred.
- Timing-correlation (C3) — accepted deferred residual from Wave 6 council review.
- Governed raw-export procedure (out-of-band DBA, logged) — Wave 5 roadmap decision.


---

# Section 3: UI/UX Wireframes

ASCII wireframes (box-drawing). Dark theme via `prefers-color-scheme` (Tailwind v4); the app follows the OS palette.

## 3.1 Design System

| Element | Spec |
|---------|------|
| Theme | Dual light/dark, OS-driven (`prefers-color-scheme`); mobile wizard & dashboard dark-themed |
| Typography | System font stack; headings bold; tabular numerals for tallies |
| Layout | Desktop: header + tab bar + content pane; Mobile: full-width single column, large tap targets |
| Feedback | Fixed-position bottom-center toast (`role="status"`), auto-dismiss 4 s, mirrors in-flow message |
| Breakpoints | Mobile-first; dashboard optimized ≥768 px; Mobile Wizard ≤480 px |
| Status colors | eligible/active green · warning/pending amber (RESERVED pulses) · danger/ineligible red · info blue |

## 3.2 Public: Home `/`

```
┌──────────────────────────────────────────────┐
│  Anonymous Election System                   │
│  ┌────────────┐                              │
│  │ [VOTING] ● │  phase badge                 │
│  └────────────┘                              │
│  Nominations: <start> – <end>                │
│  Voting:      <start> – <end>                │
│                                              │
│  ┌────────────────────────────────────────┐  │
│  │ Enter your voting token / paste link   │  │
│  └────────────────────────────────────────┘  │
│  [ Go to vote ]   [ Verify a vote ]          │
│                  [ Results (after close) ]   │
└──────────────────────────────────────────────┘
```
*Route `/`; data: `GET /api/election/status`; current behavior: token input has no submit handler, and Results link is always rendered.*

## 3.3 Public: Vote `/vote/[token]`

```
┌──────────────────────────────────────────────┐
│  Cast Your Vote                              │
│  ──────────────                              │
│  ○ Jane Doe                                  │
│    <statement…>                              │
│  ○ John Smith                                │
│    <statement…>                              │
│  ○ …                                         │
│  ┌────────────────────────────────────────┐  │
│  │  [ Submit Vote ]                       │  │
│  └────────────────────────────────────────┘  │
│  ── after submit ──                          │
│  ✔ Vote recorded                             │
│  Receipt: VC-1a2b3c4d5e                      │
│  [ Copy ]  [ Download / Print receipt ]      │
│  Save this privately — it is not emailed.    │
│  Confirm at /verify                          │
└──────────────────────────────────────────────┘
```
*Route `/vote/[token]`; loads candidates via `GET /api/candidates` after `verify-token`; receipt in ephemeral state only (no localStorage). Two-phase mode (TWO_PHASE) shows redeem→cast steps.*

## 3.4 Public: Verify `/verify`

```
┌──────────────────────────────────────────────┐
│  Confirm Your Vote Was Recorded              │
│  (confirms recording — not who it was for)   │
│  ┌────────────────────────────────────────┐  │
│  │ Receipt code (VC-…)   [primary]        │  │
│  └────────────────────────────────────────┘  │
│  ┌────────────────────────────────────────┐  │
│  │ or Ballot ID (paper QR) [secondary]    │  │
│  └────────────────────────────────────────┘  │
│  [ Check ]                                   │
│  ── result ──                                │
│  ✔ Found · channel: PAPER · cast: <date>     │
│  (candidate is never shown)                  │
└──────────────────────────────────────────────┘
```
*Route `/verify`; auto-fills from `?ballot_id=`; returns `{found, channel, cast_date}` + optional `receipt_match` only.*

## 3.5 Public: Results `/results`

```
┌──────────────────────────────────────────────┐
│  Election Results                            │
│  ── if phase < VOTING_CLOSED ──              │
│  🔒 Results are published after voting close │
│  ── else ──                                  │
│  Jane Doe    ████████████░░  142  (48%)      │
│  John Smith  ███████░░░░░░░   98  (33%)      │
│  …                                         │
│  [ Look up receipt ]                         │
└──────────────────────────────────────────────┘
```
*Route `/results`; `GET /api/results`; locked until VOTING_CLOSED/COMPLETED.*

## 3.6 Admin: Login + Dashboard shell

```
┌──────────────────────────────────────────────┐
│  Admin Login           (12:00 mobile TTL ⏱)  │
│  ┌────────────────────────────────────────┐  │
│  │ Admin secret  ********                 │  │
│  └────────────────────────────────────────┘  │
│  [ Sign in ]                                 │
└──────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│ Admin Dashboard   Phase:[VOTING]  idle 09:32  [📱Mobile QR] [Logout] │
│ [Search&Issue][Preprinted][Record/Spoil][Settings][Candidates]│
│ [Members][Token Dispatch][Nominations][Eligibility][Reporting*]│
│ ┌──────────────────────────────────────────────────────────┐ │
│ │  <active tab pane>                                        │ │
│ │                                  ┌────────────────────┐  │ │
│ │  (persistent in-flow message)    │ 🔔 toast (4 s)     │  │ │
│ │                                  └────────────────────┘  │ │
└──────────────────────────────────────────────────────────────┘
```
*Route `/admin/dashboard`; session HttpOnly cookie; re-auth modal overlays live dashboard on mutation-401 (preserves unsaved form state).*

### Tab: Search & Issue (check-in)
```
│ Search members: [ andr____ ]  (debounced)                 │
│ ┌──────────────────────────────────────────────────────┐ │
│ │ member      code      status          action         │ │
│ │ Andrew Lee  M-a1b2    ELIGIBLE        [ Check-in ]   │ │
│ │ Andrew Po   M-c3d4    Checked-in ◦grey [— disabled] │ │
│ └──────────────────────────────────────────────────────┘ │
│ ── on check-in ──  Identity slip: SHORT CODE  VEK8-T48G  │
│                    (member name/code — NO QR)            │
```

### Tab: Preprinted Ballots (anonymous pool)
```
│ [ Generate blank pool (1–1000) ] [ Print QR sheets ]     │
│ [ Void unused ]                                          │
│ Pool:  AVAILABLE 412 · CAST 88 · VOIDED 4                 │
│ (tiles render ballot_id QR only — NO member identity)    │
```

### Tab: Record / Spoil (shared Ballot Lookup)
```
│ Ballot Lookup: [ 📷 Scan QR ] or [ ballot id _________ ] │
│   scan-time check → ✔ valid / ✖ Not a valid paper ballot │
│   (Record/Spoil buttons disabled while ID empty)         │
│ Record: candidate [ dropdown ▾ ]      [ Record Vote ]    │
│ Spoil:  reason chip [rip][mark][oth]  [ Spoil Ballot ]   │
```

### Tab: Election Settings (excerpt — Danger Zone)
```
│ Phase: [Advance ▸] (3-fold email confirm)  dates [····]  │
│ Voting link TTL [168]h   Age requirement [x]             │
│ Roster: [ ] Allow adding during voting ⚠                 │
│ ── DANGER ZONE ──────────────────────────────────────┐   │
│ │ Database Wipe — deletes ALL election data (SETUP only)│ │
│ │ type: [WIPE] → [DELETE ALL DATA] → [ Execute ]        │ │
│ └────────────────────────────────────────────────────────┘ │
│ │ Purge Roster PII: Stage1 contact / Stage2 identity      │ │
│ │ type [PURGE]                                            │ │
```

## 3.7 Admin: Mobile Wizard `/admin/mobile`

```
┌──────────────────────────────┐
│ ☰ Mobile Wizard      ⏱ 11:47 │  (amber pulse < 3 min)
│ [Check-in] [Record] [Spoil]  │  phase-gated
│ ──────────────────────────── │
│  RECORD mode                 │
│  ┌────────────────────────┐  │
│  │   [ camera viewfinder ]│  │
│  │   300px scan frame     │  │
│  └────────────────────────┘  │
│  If focus struggles, try     │
│  another camera (Back Ultra  │
│  Wide) or adjust distance.   │
│  [ 📷 Photo ]  [ Cancel ]    │
│  ── after scan ──            │
│  ✔ valid ballot              │
│  candidate [ dropdown ▾ ]    │
│  [ Confirm Record ]          │
│  → receipt shown             │
└──────────────────────────────┘
```
*Route `/admin/mobile`; mobile-scoped session, 12-min absolute; `Html5QrcodeScanner` + photo fallback (≤1200px); dark theme; auto-clear messages 3 s; checked-in/voted members greyed in check-in search.*

## 3.8 User Flow (voter decision tree)

```
A member wants to vote
        │
   has email link?
   ┌────┴─────┐
   YES        NO → vote on PAPER (below)
   │
 open /vote/<token>
   │ token valid? ──NO──> error (expired/voided/used)
   YES
 select candidate → submit
   │
 receipt VC-… (copy/print)
   │
 confirm at /verify
   │
   ▼
DONE

PAPER channel (in person):
  Admin Check-in → identity slip (short code)   [entitlement reserved]
  Member picks anonymous blank from pool (QR — no identity)
  Member marks ballot, deposits
  Admin Record: scan QR → validate → candidate → confirm
  Member verifies at /verify via QR/ballot id
```

## 3.9 Error States Catalog

| Condition | HTTP | User-facing title/message | Retry? | Target |
|-----------|------|---------------------------|--------|--------|
| Invalid/expired voting token | 400 | "Invalid or expired voting token." | Yes — request reissue | `/api/vote` |
| Paper vote RPC failure | 400 | RPC message or "Paper vote failed." | Depends on error | `/api/admin/paper-vote` |
| Results before close | 200 | `{ published:false, phase }` payload (not an error code) | No | `/api/results` |
| CSRF token missing | 403 | "CSRF token required" | Yes — resubmit | state-changing admin APIs |
| DOB + age-eligible both provided | 400 | "Provide either a date of birth or the \"Age eligible\" assertion — not both." | Yes — fix input | Add Member |
| Duplicate member identity fields | 409 | "Member code/email/phone already exists" | No | Add Member |
| Wrong vote mode (TWO_PHASE active on legacy endpoint) | 409 | code `TWO_PHASE_REQUIRED` | No — operator mode/config choice | `/api/vote` |


---

# Section 4: Master Prompt Document

## 4.1 Document Purpose

This section captures enough context — the original request, the methodology, the design decisions *and their trade-offs*, the testing strategy, and the reproduction recipe — that a fresh AI agent session (or a new engineer) could understand why the system is shaped the way it is, and could extend it without re-opening settled questions.

## 4.2 Project Genesis

**Initial request:** build a privacy-first voting system for a ~300-member community electing a Committee Head, supporting both remote (email magic-link) and in-person (paper ballot) voting, with strong voter anonymity.

**Evolution (from `docs/CHANGELOG.md`):**

| Milestone | What happened |
|-----------|---------------|
| v0.1.0 (2026-08-11) | First functional release: two-domain Supabase schema, SECURITY DEFINER private RPCs, paper ballots with HMAC-signed IDs, public vote/verify/results pages, admin dashboard. |
| v0.2.0 (2026-08-19) | Security hardening release — 21 findings (SEC-01…21): HttpOnly cookie sessions, distributed rate limiting, CSRF, token expiry, hash-chained audit log (SEC-18), config validation, security headers, SBOM tooling. 36-test UAT suite. |
| v0.2.1–0.2.5 | Post-release fixes: CSV formula-injection phone regression, token expiry enforcement (SEC-06), RPC access lockdowns (`REVOKE … FROM PUBLIC, anon, authenticated`), configurable token TTL (1–2160h), proxy-voting threat model documented. |
| v0.3.0 (2026-09-03) | **Tier-1 anonymity fix — opaque ballot IDs.** Pre-v0.3.0 payloads embedded `member_id`/`candidate_id`/timestamps in *signed-but-cleartext* ballot IDs shown on the public verify page; fixed to pure-random payloads. **Required a destructive wipe** — old IDs could not be retro-anonymized. |
| v0.4.0–0.4.4 | Anonymous nomination flow (token-gated, nominator-blind writes), admin adjudication made atomic, `admin_id` FK repointed `members → admin_sessions` (100% of admin audit logging had been silently FK-failing), nomination public wrappers locked down. |
| v0.5.0–0.8.0 | Printable A6 4-up/6-up ballot sheets, mobile assign wizard, scoped admin sessions (mobile 12-min absolute), in-place re-auth modal preserving unsaved work, dual session timeouts (10-min idle + 4h absolute). |
| v0.9.0–0.10.0 | Paper-ballot integrity: reserve-token-at-issue closes the paper+digital double-vote race (shared `FOR UPDATE` lock order). Digital self-verification by receipt code; candidate disclosure removed from `/verify` in *all* phases. |
| v0.11.x | UX polish bundle; wipe-list correctness — `seed.sql` truncates all 10 election-scoped tables in one CASCADE; disposable-reuse runbook; anonymous aggregate `scripts/export-results.js`. |
| v0.12.0 (Wave 5) | **GDPR privacy subsystem:** wipe-surviving governance/RoPA ledger, eligibility schema + two-channel enforcement + atomic adjudication, DOB-free age derivation (boolean only), two-stage roster PII purge. Council review of real-PII readiness returned **NO-GO** with findings F1–F15. |
| v0.13.0–0.13.1 (Waves 6/7) | **The severance releases.** Wave 6 structurally severed paper identity (`paper_ballots`) from the anonymous pool (`anonymous_paper_blanks`) with split audit tables and co-location CHECKs — closing the council NO-GO (C1 audit register, C2 shared `ballot_id` join; C3 timing correlation accepted as residual). Wave 7 added opt-in two-phase digital voting (redeem/cast/release) with `LEGACY` default. v0.13.1 reconciled the app layer to the severed schema and deleted the forbidden per-member assign route (its RPC arg set was itself a co-location). Anonymity invariant re-certified full-diff. |
| v0.14.0–0.15.3 | Entitlement provisioning + lazy paper check-in; eligibility SETUP-only gate; **Mobile Wizard** (`/admin/mobile`) with scanner crash fix, EC-Q QR rendering (zxing/iOS), `blob:` CSP fix, 📷 Photo fallback, scan-time validation (member-blind), dark theme; import append mode; XOR DOB age eligibility; governed Members CSV export; in-app Danger Zone wipe RPC (with a grant-signature bug caught and fixed); toast notifications. |

**Real-PII readiness warning:** despite severance and Wave 5 controls, deployment remains **synthetic-data-only** until the open remediations in `docs/SECURITY.md` (F4/F11/F14) are closed and verified.

**Review methodology:** every significant wave went through brainstorm/spec → plan → implementation → `@oracle` design or security review → verifier test tiers → live-DB verification against known-bad inputs (e.g. voided token must be refused; `create_member` in COMPLETED phase must insert 0 rows) → tagged release. Council (`@council`) was reserved for the real-PII/anonymity NO-GO decision.

## 4.3 Key Design Decisions

| Decision | Rationale | Trade-off |
|----------|-----------|-----------|
| **D1 — One election per deployment** (`election_settings` id=1, no `election_id`) | Eliminates cross-election linkage surface; reuse is wipe-and-reseed, so the secret-ballot guarantee stays clean ("wiped together = clean anonymity") | No in-app history; prior results must be archived (aggregate-only) before wipe |
| **D2 — Two-domain schema, extended to four planes** | Identity vs anonymous separation; Wave 6 extended to paper identity (`paper_ballots`) vs anonymous blanks (`anonymous_paper_blanks`) with no join key | Operational complexity: check-in and ballot pool are separate objects staff must handle correctly |
| **D3 — Opaque HMAC-signed ballot IDs with pure-random payloads** | Ballot IDs appear on public pages and printed QRs; only signature (not encryption) protects them, so the payload must carry zero information | Slightly longer IDs (~135 chars); QRs demand EC level Q for iOS/zxing detectability |
| **D4 — Critical vote/check-in writes through `private` SECURITY DEFINER RPCs** | Atomic multi-step mutations with row locks for security-sensitive vote/check-in flows; single choke point for phase/eligibility/void/double-vote guards there | Some operational writes still happen in route handlers (sessions/settings/audit), so not every mutation is RPC-atomic |
| **D5 — Receipt-freeness over strong verifiability** | `/verify` confirms *recording*, never candidate; receipts are device-local, never emailed | Voters can't prove their vote content is correct — accepted for this threat model |
| **D6 — Possession-based digital auth (magic link)** | Low friction for a small community; involuntary theft mitigated by single-use + expiry; voluntary delegation is *unpreventable* remotely | Proxy voting possible; paper channel is the high-assurance path; SMS-OTP deferred |
| **D7 — Per-surface failure policy (current mixed state)** | Eligibility and invalid-handle checks fail closed; rate-limit error handling differs by surface (login closed, admin proxy/vote/member-search open) | Inconsistent behavior across routes; policy is being revised in OpenSpec change `rate-limit-failure-policy` |
| **D8 — Append-only + hash-chained audit, split by plane; wipe-surviving governance ledger** | Tamper evidence (SEC-18); RoPA/Art. 30 accountability that outlives disposable election data | Two audit stores to reconcile; ledger needs its own lifecycle policy |
| **D9 — DOB transient-only age derivation** | Data minimization: age eligibility stored as a boolean; DOB exists only in memory at import | European date formats misparse silently → mitigated by ISO-only docs, not by storing DOB |
| **D10 — Manual phase advancement** | Dates never flip phases automatically; admin intent + three-fold confirmation for every transition | Operator must remember to advance; misordered advancement blocked by DB trigger |
| **D11 — Vercel CLI-only deploys** | `git push` does NOT deploy; `vercel --prod` after merge; rollback via `vercel rollback` | Extra manual step; documented in every CHANGELOG entry that needs it |
| **D12 — In-app wipe is data-only and SETUP-gated; SQL reseed is the full-rebuild path** | Convenience for serial reuse without risking mid-election catastrophe (server-enforced) | Two wipe paths to keep documented; governance events written to ledger, not the wiped audit log |
| **D13 — Single sanctioned raw-PII export (Members CSV), governed** | Roster export is operationally necessary; made minimal-field, client-side, and ledger-audited instead of forbidden | Export file leaves the app; accountability rests on the ledger event + admin handling |
| **D14 — Admin honest-but-not-cryptographic anonymity** | The service-role operator *can* correlate; documented in `docs/SECURITY.md` instead of overclaiming | Trust in the operator is a real requirement of this deployment model |

## 4.4 Architecture Context

```
        This system is ONE tenantless, stateless Next.js app whose entire
        state lives in a single Supabase Postgres. The "architecture" is
        the schema discipline:

   ┌──────────── writes only via ────────────┐
   │        private SECURITY DEFINER RPCs     │
   ▼                                         │
 identity plane ──✗ never joined ✗── anonymous plane
 (members/tokens/  (CHECKs + no      (ballots/
  paper_ballots)    shared columns)   blanks/candidates)
```

Technology choice rationale:

| Choice | Why |
|--------|-----|
| Next.js 16 App Router | Single deployable (UI + API routes); serverless fit; note: `middleware.ts` → `proxy.ts` convention change applies |
| Supabase Postgres | Managed DB + pgcrypto CSPRNG + RLS + SQL-function security boundary; no app-side DB password |
| Resend | Transactional email with minimal integration surface |
| html5-qrcode (not native BarcodeDetector) | iOS Safari lacks BarcodeDetector; html5-qrcode's zxing fallback covers it — but requires EC Q |
| Tailwind v4 `prefers-color-scheme` | Dual theme without JS toggles; matches staff expectations on phones at night |

## 4.5 Testing Strategy

| Tier | What | How |
|------|------|-----|
| Build | TypeScript + lint | `npm run build`, `npm run lint` (0 errors; pre-existing warnings are baseline) |
| Unit/route | Route-mocked Playwright specs | e.g. `tests/wave6-dispatch-email.spec.ts` — zero DB mutation |
| Automated UAT | `tests/uat.spec.ts` + versioned suites (e.g. `tests/uat-v0151.spec.ts`) | Live dev server + live Supabase; `--reporter=list --workers=1`; headed with user pauses for admin secret |
| API negatives | curl/spec matrices (e.g. R1–R9 for voided-token guard) | Known-bad inputs MUST be refused with 0 rows written |
| Live-DB migration UAT | Rolled-back `DO`-block sentinel harnesses (`RAISE EXCEPTION` at end) | Proves guards (eligibility, phase, wipe) against real schema without mutating data |
| Manual UAT | `docs/UAT_MANUAL_TESTING.md` | Voter + admin scenarios incl. full SETUP→COMPLETED lifecycle demo on prod |

Key patterns: **fake camera feeds** (y4m) for scanner repro-isolation; **guard tests against known-bad input** (a check that can only ever pass proves nothing); **final-writer migration discipline** verified by re-run-order review; **anonymity re-certification** via full-diff review after any change touching the paper or vote planes.

## 4.6 Remaining Work

**Planned / backlog (tracked in `docs/plans/` and memory):**
- `admin_principals` multi-admin model (audit advisory-lock + fallback hard-fail follow-ups).
- Governed raw-retention/export procedure (out-of-band DBA, ledger event `RAW_RETENTION_OUT_OF_BAND_DECLARED`).
- Deferred: SMS-OTP at-cast second channel; fake-receipt deniability (rejected as YAGNI).

**Operational (per election):**
- Pre-go-live: destructive wipe (Option B — reseed minus the demo fixture, phase=SETUP), HMAC key rotation, roster import, UAT pass.
- Post-election: `node scripts/export-results.js` aggregate archive → governance ledger entries → wipe → (optional) roster PII purge stages.

## 4.7 Reproduction Instructions (for an AI agent)

To recreate this project from scratch:

1. **Scaffold:** Next.js 16 + TypeScript + Tailwind v4 app; Supabase project; Resend account. Note the Next.js 16 `middleware.ts` → `proxy.ts` rename.
2. **Schema first:** create the four-plane data model (identity `members`/`tokens`, anonymous `ballots`/`candidates`, severed paper pair `paper_ballots`/`anonymous_paper_blanks`, split audit + `governance.processing_activity_ledger`). Enforce the severance with **CHECK constraints and missing columns**, not just convention. Apply the 39-file canonical migration run order (`docs/TECHNICAL_GUIDE.md`); `seed.sql` is item 21 (last of the base rebuild), with later migration items after it.
3. **Write boundary:** keep critical vote/check-in mutations in `private` SECURITY DEFINER RPCs with `SET search_path = public, private, extensions`; use thin `public` wrappers granted to `service_role` only; `REVOKE EXECUTE FROM PUBLIC, anon, authenticated` on everything; `ALTER DEFAULT PRIVILEGES` to future-proof.
4. **Ballot IDs:** `hmac_sign('DIGITAL:'/'PAPER:' || encode(gen_random_bytes(32),'hex'))`. Never embed identifiers or timestamps. Set `app.ballot_hmac_key` outside a transaction.
5. **Auth:** HttpOnly cookie admin sessions (idle 10 min sliding / 4 h absolute desktop, 12 min absolute mobile), CSRF double-submit, three-fold email confirmation for phase/reset/wipe, differentiated 401 reasons, re-auth modal preserving unsaved state.
6. **Public surfaces:** `/`, `/vote/[token]`, `/verify` (never returns candidate), `/results` (phase-locked), `/nominate/[token]`. Anti-coercion: hide turnout on public/status and `/api/admin/stats` during VOTING.
7. **Admin surfaces:** nine persistent dashboard tabs plus a phase-gated Reporting tab, and a phase-gated Mobile Wizard with camera + 📷 photo scanning (EC-Q QRs, `blob:` in CSP img-src, 300px scan frame).
8. **Security pass:** rate limiting via RPC (with explicit per-surface failure policy), input validation + CSV sanitization, generic prod errors, CSP nonce + strict-dynamic, config validation fail-fast, `npm run security:check`.
9. **Test as you go:** every guard must pass a *known-bad* input test before being trusted; use rolled-back DO-block harnesses for DB proofs; Playwright for UI/API UAT.
10. **Document the threat model honestly** (`docs/SECURITY.md`): what is and isn't protected, especially the admin/trust boundary.

---

*End of Blueprint. Cross-references: `docs/USER_GUIDE.md` (operation), `docs/TECHNICAL_GUIDE.md` (architecture detail + canonical migration order), `docs/SECURITY.md` (threat model), `docs/DEPLOYMENT_GUIDE.md`, `docs/SBOM.md`, `docs/CHANGELOG.md` (history).*
