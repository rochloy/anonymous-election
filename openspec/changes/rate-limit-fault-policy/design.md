# Design

## Context

See proposal.md — Why, and the `request-rate-limiting` spec for the behavioral contract. The admin proxy calls `check_rate_limit` before `/api/admin/*` handlers (120 requests/IP/min production); login calls it again with a distinct `admin-login:<IP>` identifier (5/IP/min production). Login currently maps its own RPC error and a confirmed denial to the same 429; the proxy, legacy vote route, and admin member search fail open on RPC errors but treat absent result data as a denial. The nomination handlers already return 503 on RPC errors. Supabase also stores admin sessions and election state, so fault-only bypass cannot recover from a broad database outage.

## Goals / Non-Goals

**Goals:** Correct denial-versus-unavailability semantics at existing limiter call sites without changing the agreed per-surface fault policy; provide a safe, understandable 503 at login and actionable diagnostics; prove the guards with deliberately broken limiter responses and a voting-day re-login drill.

**Non-Goals:** A DB-backed fault-policy setting, runtime override, schema migration, automatic circuit breaker, process-local counter, speculative timeout, real-PII clearance, or offline vote/check-in replay. Limiter counter serialization and configuring third-party WAF/alerting are separate decisions.

## Decisions

1. **Per-surface policy stays fixed in code.** Login remains closed on its own limiter fault; the general proxy, legacy vote, and admin member search remain open on their own limiter faults. Nomination endpoints remain closed; the two-phase vote endpoints do not gain a new limit. Alternative: one DB-backed, any-phase toggle. Rejected because a setting in the same Supabase dependency is not a reliable emergency control and the shared-secret pre-auth login gate differs from the authenticated admin traffic gate.
2. **One explicit three-way result interpretation for each call site.** Only `data.allowed === true` permits a healthy request and only `data.allowed === false` is a confirmed denial; an error, thrown exception or absent/non-boolean `allowed` is a fault. Do not coerce truthiness, including strings such as `'false'`. For closed surfaces return 503 with a non-sensitive `Rate limiter unavailable` message and no `Retry-After` unless a measured retry estimate exists. For open surfaces log a sanitized fault and continue the route's ordinary checks; preserve the proxy's CSP on both allowed and blocked paths. Alternative: reuse `rateLimitError()` for faults; rejected because its 429 reports an attack/overuse that was never confirmed.
3. **No arbitrary deadline or breaker in v1.** RPC calls already run through the Supabase client; collect production-like limiter latency and fault-duration data before choosing a safe timeout. If evidence later justifies one, a deadline is classified as a fault under the same policy and its cancellation behavior must be tested. A per-instance breaker/local cache in ephemeral serverless instances cannot enforce a shared login cap; stale member/entitlement data cannot authorize check-in.
4. **Operator communication without claiming an alert service exists.** Structured, sanitized server events distinguish `limiter_unavailable` from `limit_denied` at login, proxy, legacy vote, member search, nomination submission and both nomination-search limiter checks; do not log IPs, submitted secret, tokens, members, queries, or raw exception objects with request data. The login response must be visible in desktop and mobile login forms without exposing the secret. A deployment runbook tells the polling lead where to inspect logs, how to distinguish limiter-only from full-DB failure, and when to pause final check-in. Do not promise automatic paging or email. If an external notifier is later chosen, configure/dedupe and fault-test it separately.
5. **Preserve pre-auth and voter safeguards.** A proxy fault does not bypass the login-specific check; a vote fault does not bypass its token, phase or cast boundary; member search still requires a valid session. Confirmed denials always remain 429 regardless of fault policy.
6. **Server-side fault-injection seam.** Add an injectable limiter-result interpreter or a test-local mocked Supabase client that exercises the actual route/proxy logic without live DB calls. The repository already has Playwright route-mocked browser tests, but browser interception alone cannot prove what a server-side RPC returned; a focused server-side test harness must explicitly supply allow/deny/error/throw/malformed results. A login fault test asserts no session-insert call, identical 503 behavior for different submitted secrets, and code review verifies limiter handling precedes secret comparison. Select the smallest harness compatible with the existing Node/TypeScript toolchain, without installing a heavy framework solely for this change.

## Risks / Trade-offs

- [Persistent limiter-only fault locks out new and expired admin sessions] → Distinct 503 plus server diagnostics and a polling-lead escalation procedure; active sessions continue while valid. Rehearse mobile expiry/re-login; pause final paper check-in when online reservation cannot commit.
- [A fail-open surface loses its request cap during a fault] → Keep auth/CSRF/DB checks intact, log the fault, and investigate independent upstream controls separately; do not assert that WAF rules are currently deployed.
- [Broad Supabase outage defeats both limiter and essential session/ballot operations] → Explain that 503 and fail-open are not database recovery mechanisms; no improvised offline ballot recording.
- [Request bursts share an IP, making legitimate denials possible] → Do not label 429 as proof of attack; retain its retry guidance and separate it from 503.
- [Existing SQL limiter count-then-insert can overshoot under concurrent requests] → Record a distinct concurrency hardening backlog; do not claim a strictly atomic cap or bundle a DB migration into this change.
- [Observability could leak personal or authentication data] → Use fixed event names and sanitized metadata only; test log content with known-bad secret/token fixtures.

## Deployment / Recovery Plan

1. Build and lint; run route/proxy unit tests with valid allow, valid deny, RPC error, exception and malformed data. Test known-bad input so the check demonstrably rejects a real denial. Verify logged-in work continues in a limiter-only fault and mobile expiry yields an actionable 503 at re-login.
2. Have polling staff rehearse how to contact a named election authority and distinguish limiter-only from broad Supabase failure; do not claim a usable offline workflow. Verify any external log-alert destination separately before documenting it as active.
3. After approval, deploy the application through Vercel CLI; smoke-check login 429/503 handling and ordinary authorized operations without injecting faults into production. Roll back the Vercel deployment on regression; this change has no DB migration.

## Open Questions

- No operator/on-call name or alert destination is in the repository. The runbook will use an explicit role placeholder for the election authority until the organizer fills and rehearses the real contact details. Do not label alerts "configured" before verification.
