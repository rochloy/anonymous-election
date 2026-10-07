# Proposal

## Why

F4 remains open: unauthenticated verification and results requests are handled by server routes with the all-access Supabase service-role client. Public election-status and candidate routes use the same credential. Their current response projections do not themselves prove a data leak, and the live preflight found no direct `anon`/`authenticated` table SELECT on ballots, candidates, or election settings; nevertheless, a defect in a public read handler runs with much more database authority than that read requires. Remove this avoidable privilege before accepting real personal data.

## What Changes

- Move the four anonymous read surfaces—vote verification, published results, election status, and active candidates—to narrowly scoped database-backed read contracts invoked with a server-side anon-key client. Keep the established voter-visible response shapes, including ballot-ID verification during voting, VC-only receipt verification, and the post-close receipt-found flag; never return a candidate choice in verification. Correct the existing paired-input ambiguity: an unknown ballot ID plus a valid receipt must not verify a different ballot.
- Limit direct access: no `anon` or `authenticated` table SELECT for ballots, candidates, or election settings; no database contract that returns individual ballot rows or a receipt-to-candidate mapping. Grant public invocation only to the reviewed read contracts, using a reader role without login, write permissions, table ownership, or RLS bypass. Preserve admin and token-authenticated flows outside this change.
- Fail closed on missing or malformed database responses and actual read errors: never claim `SETUP`, `found: false`, or zero published votes when a dependency failed. Return generic errors without sensitive database details.
- Add observable negative checks against current over-privileged routes, denied raw-table reads, unpublished results, malformed inputs, wrong receipt/ballot pairs, unexpectedly broad function grants, and a simulated broken database dependency. Test database permissions through the actual anon-key API, not only SQL Editor role simulation.
- Stage the production rollout: add the narrow read contracts; verify the public database boundary; deploy the four routes; re-verify; only then remove the old broad SELECT policies. Leave existing table-level anon denial in place throughout. No live election reset or wipe is needed.
- Review public lookup abuse resistance as part of the design; a Next.js-only limiter cannot protect a directly callable anon RPC. Do not claim the public read oracle is rate-limited until its effective access paths are tested.

## Capabilities

### New Capabilities

- `public-election-reads`: Least-privilege anonymous verification, results, election status, and candidate reads, with phase-bound publication, privacy-preserving outputs, and fail-closed behavior.

### Modified Capabilities

None. The existing `paper-ballot-attribution` specification describes paper-plane actor references, not public reads.

## Impact

- **App:** `/api/verify`, `/api/results`, `/api/election/status`, `/api/candidates`, a separate server-only anon client, and focused contract/error tests. Preserve current page compatibility; avoid unrelated admin, nomination, and token-authenticated routes.
- **Database:** Additive forward migration for restricted read contracts and dedicated owner, followed by a separate post-cutover migration to remove obsolete broad SELECT policies. Explicitly review exact function signatures, effective privileges, RLS, and the anon-key PostgREST response shape.
- **Docs and operations:** update SECURITY.md's F4 status only after both migrations, route deployment, and negative checks pass; document deployment/rollback checkpoints and the remaining public existence-oracle and privileged-operator limits. Do not claim this change certifies the app for real personal data or closes unrelated F1/F14 work.
- **Production safety:** no destructive data operations; the current production election is empty SETUP after synthetic UAT. Run populated phase-positive checks and deliberate privilege/fault-injection checks in a localhost-only Supabase stack; production gets separate read-only parity checks after approved migration/deployment gates. Do not point local test clients at production or link the local project to the hosted one.
