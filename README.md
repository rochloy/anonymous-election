# Anonymous Election System

A privacy-first voting system for a 300-member community electing a Committee Head. Supports both digital (magic-link) and paper ballot channels, with voter anonymity guaranteed against other voters and the public.

## Documentation

- [Blueprint](docs/BLUEPRINT.md) — PRD, Solution Design, Wireframes, Master Prompt
- [User Guide](docs/USER_GUIDE.md) — Admin & voter operation
- [Technical Guide](docs/TECHNICAL_GUIDE.md) — Architecture, migrations (canonical run order), testing
- [Deployment Guide](docs/DEPLOYMENT_GUIDE.md) — Production deployment
- [Login WAF Operations](docs/LOGIN_WAF_OPERATIONS.md) — Inspect and manage the login-only firewall rule
- [Security](docs/SECURITY.md) — Threat model & privacy posture
- [SBOM](docs/SBOM.md) — Dependencies and licenses (CycloneDX)
- [Changelog](docs/CHANGELOG.md) — Version history

## Quick Start

### 1. Database setup

> **⛔ There is currently no supported fresh-rebuild path. Do not attempt one.**
>
> `supabase/schema.sql` is **disarmed** — it aborts on execution and will not create anything.
> It is the day-one base schema, roughly 41 migrations behind the live database. Running it
> would not give you a stale-but-working database; it would build the pre-v0.3.0 leaky ballot
> payload (embedding `member_id` + `candidate_id`), restore the public `SELECT` policies that
> F4 M2 removed, undo the Wave 6 paper severance, and omit ~70 objects that exist only in
> later migrations.
>
> The historical migration list in `docs/TECHNICAL_GUIDE.md` is a **record of the order in
> which migrations were applied to the live database**, not a replayable recipe — it has known
> ordering defects and at least one omitted file.
>
> A consolidated, verified baseline is in progress. Until it lands:
> - **Existing hosted database:** apply only a new, separately reviewed terminal migration.
> - **New environment:** not currently supported. Do not improvise one from these files.
>
> Tracked as **F15** in `docs/SECURITY.md`.

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

Use the admin dashboard Token Dispatch tab to send voting/nomination magic links.

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

> **Operator note (v0.13.0):** digital voting mode is controlled by `election_settings.digital_write_mode`.
> `LEGACY` (default) uses the single-shot `/api/vote` path; `TWO_PHASE` uses `/api/vote/redeem` → `/api/vote/cast` → `/api/vote/release` with TTL-bound `DVC-` credentials.
> Endpoint gating is symmetric (`LEGACY_MODE` / `TWO_PHASE_REQUIRED`). See `docs/TECHNICAL_GUIDE.md` → **Digital write mode (Wave 7 two-phase toggle)** for the full endpoint contract.

### Paper voting
1. Admin check-in issues an **identity slip** (short code + member), consuming/reserving voting entitlement
2. Anonymous paper ballots come from a **separate pre-printed pool** (`anonymous_paper_blanks`) with opaque ballot IDs and QR codes (no member identity on the ballot)
3. On election day, voter marks an anonymous paper ballot and submits it to election staff
4. Staff scans the ballot QR (or enters ballot ID) and records the vote
5. `submit_paper_vote` RPC inserts a `ballots` row with `channel='PAPER'` and marks the anonymous blank as `CAST`
6. Voter can verify recording at `/verify` by scanning the QR with their phone's native camera

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
- **Issue paper check-in** — issues an identity slip (short code + member; no ballot ID, no QR)
- **Record paper vote** — scan anonymous pre-printed ballot QR or enter ballot ID, then select candidate (no member identity on ballot)
- **Spoil ballot** — mark a ballot as spoiled with a reason (audit logged)
- **Voter Eligibility** — search members, review eligibility reason/source, and adjudicate eligible/ineligible with reason code + note
- **Purge Roster PII (danger zone)** — two-step PURGE-gated workflow (contact-PII purge after voting closes, identity-anonymization after 30-day dispute window)

## Privacy Model

See `docs/SECURITY.md` for the full honest threat model. **Short version**:

- Eligibility enforcement is fail-closed (`UNDETERMINED` defaults to ineligible unless explicitly configured otherwise)
- Age checks are derived-only (`is_age_eligible`); DOB is not persisted
- Public/results exports are aggregate-only (no raw roster/token/audit dump path in app)
- The system is anonymous to other voters/public, but not cryptographically anonymous against an all-powerful admin/service role

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
- **Crypto:** `gen_random_bytes` (Postgres CSPRNG) — opaque random ballot IDs (the former HMAC signature layer was removed 2026-10-08; see `docs/SECURITY.md`)

## Commands

| Command | Description |
|---------|-------------|
| `npm run dev` | Start dev server |
| `npm run build` | Production build (includes TypeScript type-check) |
| `npm start` | Start production server (after build) |
| `npm run lint` | Run ESLint |
| `node scripts/import-members.js` | Import members from `data/members.csv` |
