# Proposal

## Why

A limiter RPC failure currently looks like a genuine request-limit denial at admin login: staff receive 429 and cannot tell that the limiter is unavailable. The admin proxy and other selected endpoints instead continue on limiter errors, but their handling of malformed results and the election-day recovery procedure are not consistently defined. Staff need an accurate diagnosis without making an outage bypass the admin secret or a confirmed rate-limit denial.

## What Changes

- Define three distinct limiter outcomes: explicitly allowed, explicitly denied, and unavailable (RPC error, exception, malformed result, or measured timeout). A confirmed denial always returns 429; an unavailable limiter follows the endpoint's documented fault policy.
- Keep the existing fault posture: the login-specific limiter fails closed and returns a distinguishable, non-sensitive **503** instead of 429; the general `/api/admin/*` proxy, legacy `/api/vote`, and admin member search fail open on limiter faults while retaining their other authentication, CSRF, token, eligibility, and vote guards. Nomination submission and nomination search remain fail-closed on limiter faults, including absent/malformed limiter results; two-phase voting endpoints without this limiter remain unchanged.
- Surface login limiter unavailability to staff with an actionable, non-sensitive explanation; emit sanitized, distinguishable server events for limiter faults and confirmed denials. Document who watches these signals and what to do during a persistent login-limiter fault versus a broad Supabase outage. Do not claim external notification exists without a configured and tested destination.
- Add fault-injection and negative tests (denial versus RPC error, exception and malformed data) and a manual election-day drill for session expiry and re-login. Determine any timeout threshold from observed RPC latency rather than a guessed constant.
- Do **not** add an election-phase setting, a DB-stored emergency policy toggle, automatic circuit breaker, local-memory substitute, offline-ballot replay, or a schema migration. Investigate the limiter's count-then-insert concurrency weakness separately.

## Capabilities

### New Capabilities

- `request-rate-limiting`: per-surface denial/fault behavior, safe error visibility, and testable operator response when the shared limiter is unavailable.

### Modified Capabilities

None. The existing `paper-ballot-attribution` capability does not cover HTTP request limiting.

## Impact

- **Application:** `app/api/admin/login/route.ts`, `proxy.ts`, `app/api/vote/route.ts`, `app/api/admin/members/route.ts`, both `app/api/nominate` limiter routes, the admin login UI, and focused server-side route/proxy tests.
- **Operations/docs:** an election-day limiter-fault runbook and correction of rate-limit descriptions in the relevant user, technical, security and Blueprint documentation. No assumption of a configured Vercel WAF rule, email alert, or external on-call service.
- **Deployment:** application change requiring standard test/build/lint, fault-injection UAT, and an approved Vercel production deployment; no database DDL in this change.
- **Boundary:** this does not remove the synthetic-data-only restriction recorded in `docs/SECURITY.md`, nor does it provide an offline voting workflow.
