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
│   │   │   ├── auth.ts           # requireAdmin() helper
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
│   │   ├── auth/verify-token/    # Admin secret verification
│   │   ├── candidates/           # Public candidate list
│   │   ├── election/status/      # Public phase + schedule
│   │   ├── results/              # Public results
│   │   ├── verify/               # Vote verification
│   │   └── vote/[token]/         # Digital voting UI
│   ├── verify/page.tsx           # Public vote verification
│   └── vote/[token]/page.tsx     # Digital voting
├── lib/
│   └── supabase-server.ts        # Service-role client singleton
├── proxy.ts                      # Rate limiter for /api/admin/*
├── supabase/
│   ├── schema.sql                # Base schema (tables, RLS, RPCs)
│   ├── seed.sql                  # 4 candidates, 300 members, phase=VOTING
│   ├── migration_paper_ballots.sql
│   ├── migration_public_wrappers.sql
│   ├── migration_fix_gen_random_bytes.sql
│   ├── migration_fix_service_role_grants.sql
│   ├── migration_option_e_paper_ballots_part1.sql
│   ├── migration_option_e_paper_ballots_part2.sql
│   └── migration_phase_control.sql
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
- Reset action (`action: 'reset'`) allows `COMPLETED → SETUP` for testing

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
| 6 | Members Management | CSV import, activate/deactivate |
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

### Unit / Integration
```bash
# No automated test suite currently
# Manual UAT via admin dashboard
```

### Build Verification
```bash
npm run build  # Includes TypeScript type-check
npm run lint
```

---

## Security Features

- **RLS on all tables** — Service-role bypasses via SECURITY DEFINER RPCs
- **Admin auth** — `x-admin-secret` header validated against `ADMIN_SECRET`
- **Rate limiting** — `proxy.ts` limits `/api/admin/*` to 10 req/min per IP
- **Anti-coercion** — `/api/admin/stats` hides turnout during `VOTING` phase
- **Audit logging** — All admin/voting actions logged to `vote_audit_log`
- **Phase transition validation** — DB trigger prevents invalid transitions
- **Email confirmation** — 3-level confirmation for phase changes
- **QR payload** — URL format for native camera compatibility

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
- [ ] All migrations applied in Supabase
- [ ] `ADMIN_SECRET` set and secure
- [ ] `RESEND_API_KEY` and `FROM_EMAIL` configured
- [ ] `APP_BASE_URL` set to production URL
- [ ] `ADMIN_EMAIL` set for phase confirmation emails
- [ ] Rate limiting tested
- [ ] HTTPS enforced

---

## Key Files Reference

| File | Purpose |
|------|---------|
| `lib/supabase-server.ts` | Service-role client singleton |
| `proxy.ts` | Rate limiter for admin APIs |
| `app/api/admin/auth.ts` | `requireAdmin()` helper |
| `app/admin/dashboard/page.tsx` | Admin UI (8 tabs) |
| `app/api/admin/phase/route.ts` | Phase control + dates API |
| `supabase/schema.sql` | Base schema |
| `supabase/migration_phase_control.sql` | Phase tokens + DB triggers |