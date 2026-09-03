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
    ├── dispatch-tokens.js
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
- Reset action (`action: 'request_reset'` → `verify_reset_token` → `execute_reset`) allows `COMPLETED → SETUP` for testing
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

### Database Migrations (run in Supabase SQL Editor in order)
1. `supabase/schema.sql`
2. `supabase/seed.sql`
3. `supabase/migration_paper_ballots.sql`
4. `supabase/migration_public_wrappers.sql`
5. `supabase/migration_fix_gen_random_bytes.sql`
6. `supabase/migration_fix_service_role_grants.sql`
7. `supabase/migration_option_e_paper_ballots_part1.sql`
8. `supabase/migration_option_e_paper_ballots_part2.sql`
9. `supabase/migration_phase_control.sql`
10. `supabase/migration_admin_sessions.sql`          # NEW
11. `supabase/migration_rate_limit.sql`              # NEW
12. `supabase/migration_token_expiry.sql`            # NEW
13. `supabase/migration_phase_token_admin.sql`       # NEW
14. `supabase/migration_audit_log_hash_chain.sql`    # NEW
15. `supabase/migration_configurable_token_ttl.sql`  # NEW (additive: election_settings.voting_token_ttl_hours)

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
