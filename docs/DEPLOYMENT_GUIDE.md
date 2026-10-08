# Deployment Guide

Build, install, and run the Anonymous Election System in production.

## Stack

- **Next.js 16** (App Router, Turbopack) + **React 19** + **TypeScript 5**
- **Tailwind CSS v4** (dark mode via `prefers-color-scheme`)
- **Supabase** (Postgres + PostgREST/RPCs; service-role server-only)
- **Resend** (transactional email)
- **Vercel** (hosting; deployed via Vercel CLI — see below)

## Prerequisites

- Node.js 20+ (built/tested on 24)
- A Supabase project (SQL Editor access for migrations)
- A Vercel account + CLI authenticated (`vercel login`)
- Resend account (API key + verified sender domain)

## 1. Database setup

Run the SQL files in the Supabase SQL Editor **in the canonical order** — see `docs/TECHNICAL_GUIDE.md` → **Database Migrations — CANONICAL run order** (items 1–43). Critical ordering rules:

- After cloning, enable the personal-data pre-commit guard: `git config core.hooksPath .githooks`.
- `migration_opaque_ballot_ids.sql` + `migration_fix_spoil_frees_token.sql` run **LAST** of the base writers; **never re-run `migration_enforce_token_expiry.sql` after `opaque_ballot_ids`** (it reintroduces the pre-v0.3.0 leaky payload — the deanonymization hole).
- `migration_wave6_paper_severance.sql` (item 34) is **IRREVERSIBLE** — run after items 30–33.
- `migration_wipe_election_data.sql` (item 38) runs after the governance ledger (30), followed by its public PostgREST wrapper `migration_wipe_election_data_public_wrapper.sql` (item 40), the pg-safeupdate fix `migration_wipe_election_data_safeupdate_fix.sql` (item 41), and the email-confirmation hardening `migration_wipe_email_confirmation.sql` (item 43) — all are required before the in-app wipe pane functions.
- ~~The HMAC key is set **separately, outside any transaction**~~ — **REMOVED 2026-10-08**: the ballot HMAC layer no longer exists (`migration_drop_ballot_hmac.sql`, canonical run order item 48). Ballot IDs are pure-random opaque payloads; there is no key to provision, and setting `app.ballot_hmac_key` now has no effect (nothing reads it).

**Go-live prerequisite:** run the destructive reseed once before any real votes (purges test data; the opaque-ballot-ID fix cannot be applied retroactively). Keep the wipe, skip `seed.sql`'s inserts, set phase = `SETUP`, then import real members.

## 2. Environment

### Local (`.env.local`)

```env
NEXT_PUBLIC_SUPABASE_URL="https://your-project.supabase.co"
NEXT_PUBLIC_SUPABASE_ANON_KEY="your-anon-key"
SUPABASE_SERVICE_ROLE_KEY="your-service-role-key"
APP_BASE_URL="https://your-election-domain.vercel.app"
RESEND_API_KEY="re_..."
FROM_EMAIL="Election Committee <elections@yourdomain.com>"
ADMIN_SECRET="long-random-string"
```

`ADMIN_SECRET`: `openssl rand -hex 32`. The service-role key is server-only — never expose it to the client bundle.

### Vercel

Set the same variables in Vercel → Project → Settings → Environment Variables. `APP_BASE_URL` must match the production domain (the ballot QRs encode it).

## 3. Install & build

```bash
npm install
npm run build        # production build
npm run lint         # eslint
npx tsc --noEmit     # type-check
```

## 4. Deploy

```bash
vercel --prod
```

> **Gotcha:** this project deploys via the **Vercel CLI**, not GitHub integration — `git push` does NOT trigger a deployment. Always run `vercel --prod` after merging. Verify a deployment took effect by grepping the deployed HTML for a marker from the new commit.

**Rollback:** `vercel rollback <deployment-url>` (or the Vercel dashboard → Deployments → Promote) — instant, no rebuild; previous deployments are retained.

## 5. Post-deploy verification

1. Public pages load (`/`, `/verify`, `/results`)
2. Admin login works; the dashboard renders
3. The mobile wizard scans (camera + 📷 Photo fallback)
4. The scan-time validation rejects invalid/foreign QRs
5. `npm audit --audit-level=high` clean

Rate-limit semantics reference (ops):
- Confirmed limiter denial => 429
- Limiter fault on fail-closed surfaces (login, nomination submit/search) => 503
- Limiter fault on fail-open surfaces (general admin proxy, legacy vote, admin member search) => request proceeds to normal route guards
- Election-day procedure: `docs/ELECTION_DAY_RATE_LIMITER_RUNBOOK.md`

## 6. New-election setup (per election)

1. **Election Settings → Danger Zone → Database Wipe** (SETUP-only, email confirmation link + typed confirmations) — or the SQL Editor reseed for schema changes
2. Review the carried-over settings (dates, age requirement, token TTL)
3. Import the member roster (CSV; append mode for batches without codes)
4. Add candidates
5. Generate + print the ballot pool (EC Q QRs)
6. Advance the phase

Full lifecycle: `docs/TECHNICAL_GUIDE.md` → "Election Lifecycle & Reuse".
