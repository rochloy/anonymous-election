<!-- BEGIN:nextjs-agent-rules -->
# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` before writing any code. Heed deprecation notices.
<!-- END:nextjs-agent-rules -->

# Anonymous Election System — Project AGENTS.md

## Stack

- **Language:** TypeScript
- **Framework:** Next.js 16.3.8 (App Router, Turbopack)
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
| Rate-limit policy tests | `npm run test:rate-limit` |
| Login 503 UI tests | `npx playwright test tests/rate-limit-login-ui.spec.ts --reporter=list --workers=1` |
| Start production | `npm start` |
| Lint | `npm run lint` |
| Login WAF helper tests | `scripts/test-manage-login-waf.sh` |
| Import members | `node scripts/import-members.js` |
| Export results (anonymous aggregate, pre-wipe archive) | `node scripts/export-results.js` |

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

No direct Postgres URL/password in the app. **Migrations:** the agent applies them via the **Supabase MCP** (`apply_migration` for DDL, `execute_sql` for queries/data). Manually pasting into the Supabase SQL Editor is the fallback when the MCP is unavailable. The `.sql` files in `supabase/` remain the source of truth and run order.

## Database Migration Run Order

Use the canonical migration sequence in `docs/TECHNICAL_GUIDE.md` → **Database Migrations — CANONICAL run order**.

- Do not maintain a duplicate migration list in this file.
- Follow the Technical Guide list exactly for destructive rebuild/reseed operations.

## Architecture

Two-domain Supabase schema (Option A: Honest-Restated Decoupled DB):
- **Identity domain** (`members`, `tokens`): who is eligible, who has voted
- **Anonymous domain** (`ballots`, `candidates`): what was voted, receipt codes
- **Paper ballot domain** (`paper_ballots`, `vote_audit_log`): issued ballot tracking + audit

Security-critical writes go through `SECURITY DEFINER` RPCs in `private` schema (not exposed via PostgREST); some admin routes still perform direct table writes (for example admin session creation). Service-role key is server-only (`lib/supabase-server.ts`), never bundled to client.

## Key Files

- `lib/supabase-server.ts` — lazy singleton service-role client
- `proxy.ts` — rate limiter for `/api/admin/*` (120 req/min per IP)
- `app/api/admin/auth.ts` — `requireAdmin()` helper (validates HttpOnly `admin_session` cookie) + `requireAdminWithCsrf()` (`admin_csrf` cookie + `x-csrf-token` header)
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

### Ballot ID format (opaque as of v0.3.0)
Ballot IDs are `TEXT` columns. The stored `ballot_id` is `private.hmac_sign(payload)`, which returns `payload || '.' || <hmac-sig>` (sig = 64 hex chars). **As of v0.3.0 the payload is pure-random and opaque** — `PAPER:<32-byte-random-hex>` (paper) or `DIGITAL:<32-byte-random-hex>` (digital) — so a full ID looks like `PAPER:<64-hex>.<64-hex-sig>` (~135 chars total). **No `member_id`, `candidate_id`, `timestamp`, or `batch_id` is embedded** in the payload; that pre-v0.3.0 leak (`PAPER:<uuid>:<timestamp>:…`, digital `<member_id>:<candidate_id>:…`) was the Tier-1 deanonymization bug fixed in `migration_opaque_ballot_ids.sql` — do NOT reintroduce identifiers into the payload. `hmac_sign`/`hmac_verify` are unchanged; paper RPCs still HMAC-verify IDs downstream. URL-encoded in QR: ~172-198 chars depending on `APP_BASE_URL`. QR renders as 512×512 PNG (QR Version ~8-9, EC level Q).

### pg-safeupdate: DELETE/UPDATE need a WHERE clause on API paths
Supabase loads the pg-safeupdate extension for PostgREST (API) requests. Any `DELETE` or `UPDATE` without a `WHERE` clause fails with "DELETE/UPDATE requires a WHERE clause" — **including statements inside SECURITY DEFINER RPCs called via `supabaseServer.rpc`**. The SQL Editor does not load it, so a statement that works there (e.g. `seed.sql`) can still fail in the app. Use `TRUNCATE`, or add an always-true predicate such as `WHERE id IS NOT NULL` (the extension only checks that a WHERE clause exists). Fixed for the wipe RPC in item 41.

### middleware.ts → proxy.ts (Next.js 16)
Next.js 16 deprecates the `middleware` file convention. Use `proxy.ts` with `export function proxy()` instead. The rate-limiting logic is unchanged.

### No direct DB access from application code
There is no Postgres URL/password in `.env.local`. All **runtime** database operations go through the Supabase JS client (`supabaseServer`) using the service-role key. **Migrations/DDL** are applied by the agent through the Supabase MCP (`apply_migration`/`execute_sql`); the Supabase SQL Editor is the manual fallback. The `supabase/*.sql` files stay authoritative for content and run order.

### LOGIN_RATE_LIMIT_MAX is env-gated (prod vs dev/test)
`LOGIN_RATE_LIMIT_MAX` is environment-gated: production uses **5** attempts/minute while non-production uses a high ceiling (**1000**), mirroring `proxy.ts` `MAX_HITS` behavior. Tests/dev flows rely on that high dev ceiling.

### Playwright UAT runs against live dev server + Supabase by default
`loginAndGetPage` is not route-mocked by default. Also, `page.route()` does **not** intercept requests sent via `page.request.fetch`, so assume live dev-server + live Supabase interaction unless explicitly mocked at the API layer.

### Playwright reporter must be list in PTY runs
Run Playwright with `--reporter=list` in PTY/non-interactive sessions. The HTML reporter auto-serves and can hang the PTY.

### Wave 5 migration note
Wave 5 added migrations **30–33**: governance ledger, eligibility schema, eligibility enforcement, and eligibility adjudication. Keep canonical ordering in `docs/TECHNICAL_GUIDE.md` aligned when adding future terminal writers.

### File-scan requires `blob:` in CSP img-src (v0.15.2)
The mobile wizard's 📷 Photo fallback loads the user-picked photo via `URL.createObjectURL()` — a `blob:` URL. The per-request CSP in `proxy.ts` must include `blob:` in `img-src` or the image load is blocked and the failure surfaces as a raw Event ("[object Event]"). `blob:` URLs are same-origin scoped (only the page's own scripts can create them) — safe allowance for client-side image processing.

### Ballot QRs must render at EC Q for zxing detectability (v0.15.2)
html5-qrcode's zxing fallback (used on iOS Safari, which has no native BarcodeDetector) cannot detect EC-M version-10 ballot QRs — verified in isolation (every EC-M variant fails at any size/margin; EC Q/H decode). `paper-batch` renders ballot QRs at **EC Q**. The EC level is a rendering parameter only — ballot IDs stay opaque random payloads; the data model and anonymity design are unchanged. Do NOT revert to EC M.

### Scan-time ballot validation queries anonymous_paper_blanks (v0.15.2)
`GET /api/admin/paper-ballot-status` + `lib/ballot-scan.ts` validate scanned ballots against the **member-blind** `anonymous_paper_blanks` pool (columns: ballot_id, status, timestamps, void_reason — no member/voter identity columns exist). The API returns `{exists, status}` only. The confirm-time RPCs (`submit_paper_vote` / `void_anonymous_paper_blank`) remain the security boundary. Note: `paper_ballots` is the identity plane (short_code, member_id) and has NO `ballot_id` column — do not query it by ballot ID.
