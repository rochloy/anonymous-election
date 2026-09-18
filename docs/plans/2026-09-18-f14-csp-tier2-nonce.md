# F14 CSP Tier-2 — Per-Request Nonce (drop script `'unsafe-inline'`)

**Status:** DRAFT — awaiting approval before implementation
**Date:** 2026-09-18
**Branch (when built):** `agent/f14-csp-tier2` (Tier-1 lands first on `agent/f14-csp-tier1`)
**Depends on:** F14 Tier-1 merged (prod drops `'unsafe-eval'`)

## Goal

Remove `'unsafe-inline'` from the CSP `script-src` directive by issuing a
per-request cryptographic nonce and letting Next.js attach it to its own
framework/bootstrap inline scripts. End state (prod):

```
script-src 'self' 'nonce-<per-request>' 'strict-dynamic'
```

Dev retains `'unsafe-eval'` (React/Next need it to build error stacks in the
browser — documented requirement).

Out of scope: `style-src 'unsafe-inline'` (that is Tier-3, high-risk, breaks QR
inline styles — **not** in this plan).

## Background / grounding

Official Next.js 16 CSP recipe (all verified against
`https://nextjs.org/docs/app/guides/content-security-policy`):

- Nonce is generated + injected in **`proxy.ts`** (Next 16's renamed middleware;
  we already have one for admin rate-limiting).
- Next.js **auto-propagates** a `'nonce-…'` value parsed from the request CSP
  header to: framework/React runtime scripts, page JS bundles, internally
  generated inline scripts/styles, and any `<Script nonce>`.
- Server Components read the nonce via `await headers()` (`x-nonce`).

## KEY TRADE-OFF (must be accepted before building)

A per-request nonce **forces dynamic rendering**:
- Disables static optimization + ISR for any route the CSP header covers.
- Disables default CDN caching for those routes (higher server load/latency).
- **Incompatible with Partial Prerendering (PPR).**

Sensitive routes (`/admin/*`, `/vote/[token]`, `/nominate/[token]`) are already
dynamic / `no-store`, so they lose nothing. The cost falls only on genuinely
static public pages. **Step 0 below quantifies exactly which routes those are —
we do not guess.**

## Implementation steps

- [ ] **Step 0 — Enumerate current render modes.** Run `npm run build` and
  capture the route table (○ Static / ƒ Dynamic). Record which routes are
  currently Static and would flip to Dynamic under a global nonce. Decision
  point: if a hot static public page (e.g. landing) must stay static, scope the
  `proxy.ts` `matcher` to exclude it (accept `'unsafe-inline'` there) rather
  than globally. Document the chosen matcher scope here before coding.
- [ ] **Step 1 — Move CSP into `proxy.ts`.** Generate `nonce =
  crypto.randomUUID()`-derived base64 per request. Build the CSP string there
  (prod: `'self' 'nonce-<n>' 'strict-dynamic'`; dev: append `'unsafe-eval'`).
  Set both the request header `x-nonce` and the response
  `Content-Security-Policy`. Preserve the existing admin rate-limit logic in the
  same `proxy()` — do not regress it.
- [ ] **Step 2 — Remove the static `script-src` from `next.config.ts`.** The
  `script-src` line moves to `proxy.ts`. Keep the other static headers
  (`style-src`, `img-src`, HSTS, `X-Frame-Options`, `Permissions-Policy`, the
  `/vote|nominate/:token` `no-referrer`/`no-store` block) in `next.config.ts`
  UNLESS Step 0 shows a conflict from setting CSP in two places — if so,
  consolidate the full CSP into `proxy.ts` to avoid duplicate/ conflicting
  headers.
- [ ] **Step 3 — `matcher` scope.** Configure `proxy.ts` `config.matcher` per
  Step 0 (exclude `_next/static`, `_next/image`, `favicon.ico`, and `api` if
  the API shouldn't carry the page CSP; keep admin paths so rate-limiting still
  fires — verify the matcher covers BOTH concerns).
- [ ] **Step 4 — Nonce on any hand-written inline `<script>`.** Grep for inline
  scripts / `dangerouslySetInnerHTML` script usage and `<Script>` tags; add
  `nonce={await headers().get('x-nonce')}` where needed. (Most Next-generated
  scripts are auto-handled; this covers our own, if any.)
- [ ] **Step 5 — Build + type-check** via `@verifier` (standard).
- [ ] **Step 6 — UAT** (prod build, `npm run build && npm start`):
  - `curl -sI` → confirm `script-src` has `'nonce-…' 'strict-dynamic'`, no
    `'unsafe-inline'`, nonce differs across two requests.
  - Full page load, admin dashboard, **QR scanner**, digital vote, verify page:
    zero CSP console violations.
  - Confirm admin rate-limiting still returns 429 after threshold (proxy
    regression check).

## Risks

- **`strict-dynamic` side effects** — once set, host-allowlist script sources
  are ignored; any script loaded by URL must be loaded by a nonced script.
  Verify no third-party `<script src>` breaks (scanner libs are npm-bundled, so
  low risk, but confirm in Step 6).
- **Double-CSP-header conflict** — if both `next.config.ts` and `proxy.ts`
  emit a CSP header, browsers intersect them (most restrictive wins) and can
  silently break scripts. Step 2 must ensure a single source of the CSP header.
- **Static-page latency regression** — mitigated by Step 0 matcher scoping.

## Rollback

Revert `proxy.ts` CSP block + restore the `script-src` line in
`next.config.ts` (Tier-1 form). No DB/schema impact.

## Definition of done

- Prod `script-src` carries a fresh per-request nonce + `strict-dynamic`, no
  `'unsafe-inline'`.
- QR scanner, admin dashboard, voting, verify all function with zero CSP
  console violations.
- Admin rate-limiting unregressed.
- Route render-mode changes documented + accepted.
