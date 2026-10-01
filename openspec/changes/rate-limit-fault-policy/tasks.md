# Tasks

## 1. Login limiter: denial versus fault

- [x] 1.1 Add focused server-side login tests using an injectable limiter interpreter or mocked Supabase client (not only browser request interception) for allow, explicit deny, RPC error, thrown exception, and absent/malformed `allowed`. Verify a real denial returns 429 with retry guidance, all faults return identical 503 responses for different submitted secrets with no session insert; review handler ordering to verify the secret is not compared on the fault path, and verify a valid allow still requires the correct secret.
- [x] 1.2 Implement three-way classification in the login route; send a non-sensitive, distinguishable 503 on fault while preserving 429 for explicit denial and existing authentication/session behavior. Verify the focused tests from 1.1 pass, including a deliberately broken limiter mock.
- [x] 1.3 Verify the desktop dashboard login/reauth and Mobile Wizard display the 503 explanation without exposing the submitted secret or suggesting that the admin merely exceeded a rate limit. Add focused UI tests only where existing response rendering is insufficient; verify the UI tests pass.

## 2. Existing fail-open surfaces and consistent diagnosis

- [x] 2.1 Add proxy tests for explicit allow, explicit deny, RPC error, throw and malformed result. Verify denied traffic returns 429, all faults still reach the normal handler, and the per-request CSP remains present on both blocked and unblocked responses.
- [x] 2.2 Update proxy limiter handling to treat only `allowed === false` as denial, classify all other unusable/error results as sanitized faults, and preserve CSP on early responses. Verify the tests in 2.1 pass, including a fault followed by a login-specific 503 (no proxy bypass of login's own limiter).
- [x] 2.3 Add route tests for the legacy vote limiter and authenticated member-search limiter with explicit denials and malformed/error responses. Verify 429 for a confirmed denial, ordinary vote guards remain in force when vote limiting fails, and member search still requires an admin session during a limiter fault.
- [x] 2.4 Update legacy vote and member-search limiter branches to the same three-way decision while retaining their existing fail-open posture. Verify tests from 2.3 pass; do not add a new limiter to two-phase voting.
- [x] 2.5 Add focused server-side tests for nomination submission plus **both** IP and token limiter checks in nomination search: explicit denial → 429, RPC error/throw/absent/malformed result → 503. Fix the existing submission `null` → 429 and search `null` → proceed bugs while preserving the current fail-closed posture. Verify all nomination tests pass with deliberately unusable limiter data.

## 3. Operator diagnostics and documented response

- [x] 3.1 Add sanitized structured server diagnostics that distinguish `limit_denied` from `limiter_unavailable` at login, general proxy, legacy vote, member search, nomination submission, and **both** nomination-search checks; do not log request bodies, IPs, secrets, token hashes, member identities, or raw exception objects. Verify with fixtures containing fake secret/token strings that none appear in captured logs and that denied/fault events have different markers on all surfaces.
- [x] 3.2 Document the current per-surface failure policy, 429-versus-503 meaning, and the named *role* responsible for reviewing server logs (contact identity to be supplied by the election authority) in an election-day runbook and reconcile affected USER_GUIDE, TECHNICAL_GUIDE, BLUEPRINT, and SECURITY wording. Distinguish limiter-only failure from broad Supabase failure, state when to pause online check-in, and disclaim any unconfigured external alert/automatic offline replay. Verify cross-document statements agree and links resolve.
- [ ] 3.3 Rehearse a non-production fault-injection drill: show a confirmed 429, a limiter-only login 503 after mobile session expiry, continued authenticated admin check-in while DB operations are healthy, and a separate broad-DB failure that the limiter fallback cannot rescue. Record actual operator observations and escalation contact; do not mutate production or claim an unrehearsed alert is active.

## 4. Integration and release gates

- [x] 4.1 Run focused route/proxy tests, `npm run build`, `npm run lint`, `git diff --check`, and `openspec validate rate-limit-fault-policy --strict`. Verify passing results or classify and resolve failures before committing application changes.
- [ ] 4.2 Obtain operator UAT approval for the 503 wording and election-day response; deploy with `vercel --prod` only after merge/deploy authorization and a passing build. Verify production smoke checks for normal login, ordinary admin access and a non-destructive confirmed 429; keep fault injection out of production. Document `vercel rollback <deployment-url>` for a regression.
