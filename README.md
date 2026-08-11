# Anonymous Election System

A privacy-first voting system for a 300-member community electing a Committee Head. Supports both digital (magic-link) and paper ballot channels, with voter anonymity guaranteed against other voters and the public.

## Quick Start

### 1. Database setup

Run the SQL files in the Supabase SQL Editor **in this order**:

| Order | File | Purpose |
|-------|------|---------|
| 1 | `supabase/schema.sql` | Base schema: tables, RLS, private RPCs |
| 2 | `supabase/seed.sql` | Seed: 4 candidates, 300 members, set phase to `VOTING` |
| 3 | `supabase/migration_paper_ballots.sql` | Paper ballot tables + private RPCs (issue/submit/spoil) |
| 4 | `supabase/migration_public_wrappers.sql` | Public wrapper functions forwarding to private RPCs |
| 5 | `supabase/migration_fix_gen_random_bytes.sql` | Column-width + search_path fix for pgcrypto on Supabase Cloud |
| 6 | `supabase/migration_fix_service_role_grants.sql` | GRANT service_role access to `paper_ballots` + `vote_audit_log` |

> **Critical:** Step 6 fixes a silent bug where `paper_ballots` and `vote_audit_log` deny `service_role` by default (RLS enabled, no policies), causing all members to show as `ELIGIBLE` even when they have issued ballots. If you skip it, the admin dashboard will display incorrect voting statuses.

### 2. Environment

Copy `.env.example` to `.env.local` and fill in:

```env
NEXT_PUBLIC_SUPABASE_URL="https://your-supabase-project.supabase.co"
NEXT_PUBLIC_SUPABASE_ANON_KEY="your-anon-key"
SUPABASE_SERVICE_ROLE_KEY="your-service-role-key"
APP_BASE_URL="https://your-election-domain.vercel.app"
RESEND_API_KEY="re_123456789..."
FROM_EMAIL="Election Committee <elections@yourdomain.com>"
ADMIN_SECRET="change-this-to-a-long-random-string"
```

Set `ADMIN_SECRET` to a long random string (e.g. `openssl rand -hex 32`).

### 3. Install & build

```bash
npm install
npm run build
```

### 4. Dispatch voting tokens

```bash
node scripts/dispatch-tokens.js
```

Sends magic-link emails to all active members via Resend. Each link uses `/vote/<token>` (token in URL path, not query string — avoids access-log/Referer leakage).

### 5. Run the app

```bash
npm run dev    # development
# or
npm start      # production (after build)
```

## How It Works

### Digital voting
1. Each member receives a unique, single-use voting token via email
2. Member opens the magic link (`/vote/<token>`)
3. Token is verified server-side; member selects a candidate
4. `submit_anonymous_vote` RPC atomically: validates token → generates CSPRNG receipt code → inserts ballot → marks token used
5. Member receives a receipt code to verify their vote was counted

### Paper voting
1. Admin issues a paper ballot via the admin dashboard (`/admin/dashboard`)
2. System generates an HMAC-signed ballot ID (`PAPER:<uuid>:<timestamp>:<hmac>`) + short code + QR code
3. QR code is printed on the physical ballot
4. On election day, voter marks the paper ballot and submits it to election staff
5. Staff scans the QR with the in-app scanner (or enters the short code) and records the vote
6. `submit_paper_vote` RPC inserts a `ballots` row with `channel='PAPER'` (enters canonical tally)
7. Voter can verify their vote at `/verify` by scanning the QR with their phone's native camera

### Vote verification
- Public `/verify` page accepts a ballot ID (and optional receipt code for digital votes)
- QR codes encode URL payloads (`${APP_BASE_URL}/verify?ballot_id=<id>`) — native phone cameras (iOS/Android) recognize them as tappable links
- Scanning a paper ballot's QR with a phone camera opens the verify page with the ballot ID auto-filled

### Election results
- Results are published only after `current_phase` is set to `VOTING_CLOSED` or `COMPLETED`
- During active voting, `/api/admin/stats` hides turnout counts (anti-coercion)
- Results page (`/results`) shows aggregated vote counts + percentages, with optional receipt lookup

## Admin Dashboard

Access at `/admin` (redirects to `/admin/dashboard`). Requires the `ADMIN_SECRET` to be entered in the UI.

Features:
- **Member search** — find members by name, see voting status (ELIGIBLE / DIGITAL_VOTED / PAPER_ISSUED / PAPER_VOTED)
- **Issue paper ballot** — generates ballot ID + short code + printable QR (512×512 PNG)
- **Record paper vote** — scan QR with in-app scanner or enter short code, select candidate
- **Spoil ballot** — mark a ballot as spoiled with a reason (audit logged)

## Privacy Model

See `docs/SECURITY.md` for the full honest threat model. **Short version**: anonymous to other voters and the public; the admin has the technical ability to correlate via timestamps/logs and has committed not to.

## Architecture

Two-domain Supabase schema:
- **Identity domain** (`members`, `tokens`): who is eligible, who has voted
- **Anonymous domain** (`ballots`, `candidates`): what was voted, receipt codes
- **Paper ballot domain** (`paper_ballots`, `vote_audit_log`): issued ballot tracking + audit trail

Writes go through `SECURITY DEFINER` RPCs in the `private` schema (not exposed via PostgREST). The service-role key is server-only and never bundled to the client.

## Tech Stack

- **Framework:** Next.js 16 (App Router, TypeScript, Turbopack)
- **Database:** Supabase (PostgreSQL with RLS)
- **Styling:** Tailwind CSS v4
- **Email:** Resend
- **QR codes:** `qrcode` (generation), `html5-qrcode` (in-app scanning)
- **Crypto:** `gen_random_bytes` (Postgres CSPRNG), HMAC-signed ballot IDs

## Commands

| Command | Description |
|---------|-------------|
| `npm run dev` | Start dev server |
| `npm run build` | Production build (includes TypeScript type-check) |
| `npm start` | Start production server (after build) |
| `npm run lint` | Run ESLint |
| `node scripts/dispatch-tokens.js` | Send magic-link emails to all active members |
| `node scripts/import-members.js` | Import members from `data/members.csv` |
