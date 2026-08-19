<!-- BEGIN:nextjs-agent-rules -->
# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` before writing any code. Heed deprecation notices.
<!-- END:nextjs-agent-rules -->

# Anonymous Election System — Project AGENTS.md

## Stack

- **Language:** TypeScript
- **Framework:** Next.js 16.2.12 (App Router, Turbopack)
- **Runtime:** Node.js 24+ (nvm)
- **Database:** Supabase (PostgreSQL with RLS, `private` schema for SECURITY DEFINER RPCs)
- **Styling:** Tailwind CSS v4
- **Email:** Resend
- **QR:** `qrcode` (generation), `html5-qrcode` (in-app scanning)
- **Package manager:** npm

## Commands

| Task | Command |
|------|---------|
| Install | `npm install` |
| Dev server | `npm run dev` |
| Build (includes TS type-check) | `npm run build` |
| Start production | `npm start` |
| Lint | `npm run lint` |
| Dispatch tokens | `node scripts/dispatch-tokens.js` |
| Import members | `node scripts/import-members.js` |

## Environment

Required vars in `.env.local` (see `.env.example`):

```
NEXT_PUBLIC_SUPABASE_URL
NEXT_PUBLIC_SUPABASE_ANON_KEY
SUPABASE_SERVICE_ROLE_KEY
APP_BASE_URL
RESEND_API_KEY
FROM_EMAIL
ADMIN_SECRET
```

No direct Postgres URL/password — SQL must be run manually in Supabase SQL Editor.

## Database Migration Run Order

Run in Supabase SQL Editor **in this exact order**:

1. `supabase/schema.sql` — base schema (tables, RLS, private RPCs)
2. `supabase/seed.sql` — 4 candidates, 300 members, phase = VOTING
3. `supabase/migration_paper_ballots.sql` — paper_ballots + vote_audit_log tables, private RPCs
4. `supabase/migration_public_wrappers.sql` — public wrapper functions
5. `supabase/migration_fix_gen_random_bytes.sql` — column-width + search_path fix
6. `supabase/migration_fix_service_role_grants.sql` — GRANT service_role on paper_ballots + vote_audit_log
7. `supabase/migration_option_e_paper_ballots_part1.sql` — Option E schema changes, enum additions, batch table
8. `supabase/migration_option_e_paper_ballots_part2.sql` — Option E functions, partial index, grants (run AFTER part1)
9. `supabase/migration_phase_control.sql` — Phase control tokens table, DB-level transition validation

## Architecture

Two-domain Supabase schema (Option A: Honest-Restated Decoupled DB):
- **Identity domain** (`members`, `tokens`): who is eligible, who has voted
- **Anonymous domain** (`ballots`, `candidates`): what was voted, receipt codes
- **Paper ballot domain** (`paper_ballots`, `vote_audit_log`): issued ballot tracking + audit

Writes go through `SECURITY DEFINER` RPCs in `private` schema (not exposed via PostgREST). Service-role key is server-only (`lib/supabase-server.ts`), never bundled to client.

## Key Files

- `lib/supabase-server.ts` — lazy singleton service-role client
- `proxy.ts` — rate limiter for `/api/admin/*` (10 req/min per IP)
- `app/api/admin/auth.ts` — `requireAdmin()` helper (validates `x-admin-secret` header)
- `app/admin/dashboard/page.tsx` — admin UI (member search, issue/record/spoil, QR scanner)
- `app/verify/page.tsx` — public vote verification (auto-fills from `?ballot_id=` URL param)
- `app/vote/[token]/page.tsx` — digital voting UI (token in URL path)

## Gotchas

### service_role GRANT on new tables (CRITICAL)
`paper_ballots` and `vote_audit_log` have RLS enabled with no policies. By default, `service_role` is **denied** table-level access (error `42501 permission denied`). SECURITY DEFINER RPCs bypass this (they work), but direct PostgREST reads as `service_role` fail silently if errors are swallowed. **Symptom:** all members show `ELIGIBLE` even when they have issued ballots. **Fix:** run `supabase/migration_fix_service_role_grants.sql`. The members API now throws on real DB errors (no silent swallowing) to prevent recurrence.

### pgcrypto search_path on Supabase Cloud
`pgcrypto` installs into the `extensions` schema on Supabase Cloud (not `public`). Private RPCs that call `gen_random_bytes()` must use `SET search_path = public, private, extensions`. Public wrapper functions use `SET search_path = public, private` (missing `extensions`, but they don't call gen_random_bytes directly). See `supabase/migration_fix_gen_random_bytes.sql`.

### QR payload must be a URL for native cameras
Native phone cameras (iOS Camera, Android) only surface an actionable tap target for recognized URI schemes (`http(s)`, `tel`, `mailto`, etc.). A bare `PAPER:...` string is decoded but shows "no usable data." QR codes encode `${APP_BASE_URL}/verify?ballot_id=<encoded>` so native cameras recognize them. The in-app `html5-qrcode` scanner uses `extractBallotId()` to parse the URL or fall back to raw text (handles both new URL-format and legacy raw-text QR for already-printed ballots).

### Ballot ID format
Paper ballot IDs are `TEXT` columns, format: `PAPER:<uuid>:<timestamp>:<hmac>` (~135 chars). URL-encoded in QR: ~172-198 chars depending on `APP_BASE_URL`. QR renders as 512×512 PNG (QR Version ~8-9, EC level M).

### middleware.ts → proxy.ts (Next.js 16)
Next.js 16 deprecates the `middleware` file convention. Use `proxy.ts` with `export function proxy()` instead. The rate-limiting logic is unchanged.

### No direct DB access from code
There is no Postgres URL/password in `.env.local`. All database operations go through the Supabase JS client (`supabaseServer`) using the service-role key. SQL migrations must be run manually in the Supabase SQL Editor.
