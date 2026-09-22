# Security & Privacy Model

## Anonymity Guarantee (Honest Statement)

This system guarantees **anonymity against other voters and the public**. It does **not** guarantee anonymity against the administrator.

### What is protected
- One voter cannot see another voter's choice.
- The public cannot see who voted for whom until results are published, and even then only sees aggregated counts + receipt codes (not voter identities).
- The receipt-code lookup lets a voter verify their own vote was counted, without revealing their identity.

### What is NOT protected
The administrator (or anyone holding the `SUPABASE_SERVICE_ROLE_KEY`, or Supabase support staff) has the technical ability to correlate votes to voters via:
1. **Transaction timestamps**: the `submit_anonymous_vote` RPC updates `tokens.used_at` and inserts a `ballots` row in the same transaction. The millisecond-precision `used_at` can be joined to the ballot insertion time.
2. **Query logs**: Supabase's Postgres logs capture RPC parameters (`p_token_hash`, `p_candidate_id`) in plaintext. The `p_token_hash` directly identifies the voter.

### Mitigation commitments
- The administrator has committed, in writing, not to run correlation queries.
- Database query logs are escrowed with a third party and not directly accessible to the admin.
- The `private` schema and `REVOKE EXECUTE FROM anon` prevent direct RPC invocation by non-admin clients.

### If you need stronger anonymity
If the threat model includes a curious or coerced administrator, this architecture is insufficient. Use a blind-signature or mixnet architecture instead, where no single component can link identity to vote.

## Security Controls Implemented
- **Admin route auth**: all `/api/admin/*` routes require `x-admin-secret` header matching `ADMIN_SECRET` env var.
- **Rate limiting**: admin routes limited to 120 req/min per IP.
- **RPC in private schema**: `submit_anonymous_vote` and `submit_paper_vote` are in the `private` schema, not exposed via PostgREST. `REVOKE EXECUTE FROM anon, authenticated`.
- **CSPRNG receipts**: receipt codes generated with `gen_random_bytes` (Postgres CSPRNG) inside the RPC, with 5-attempt retry on collision.
- **Paper tally fix**: paper votes insert a `ballots` row with `channel='PAPER'`, so they enter the canonical tally.
- **No live turnout during voting**: `/api/admin/stats` hides turnout counts while phase is `VOTING` (anti-coercion).
- **Receipt-free public verification (v0.10.0)**: `/api/verify` confirms only that a vote was **recorded** (`{found, channel, cast_date}`) and never returns the chosen candidate in any phase. Prior to v0.10.0 it revealed the candidate name once phase left `VOTING`, which turned any leaked or coerced `ballot_id` into a transferable proof of *how* someone voted; that disclosure is removed. Digital self-verification uses the voter's `VC-…` receipt code (the `ballot_id` is never returned to the browser); receipt lookup is format-guarded (`^VC-[0-9a-fA-F]{10}$`) and canonicalized before an exact match, with no `ilike`/wildcard path (anti-coercion / receipt-freeness).
- **Token in URL path**: magic links use `/vote/<token>` not `/vote?token=<token>`, avoiding access-log and Referer leakage.
- **Random member codes**: seed uses random 8-char codes, not sequential `MEM-001`..`MEM-300`.
- **HMAC-signed, opaque ballot IDs**: ballot IDs are `hmac_sign(payload)` = `payload || '.' || <hmac-sig>` to prevent forgery. As of v0.3.0 the payload is pure-random (`PAPER:<32-byte-random-hex>` / `DIGITAL:<32-byte-random-hex>`) with **no** member/candidate/timestamp embedded — closing the Tier-1 deanonymization leak (the payload half of a signed ID is publicly visible).
- **URL-based QR payload**: QR codes encode `${APP_BASE_URL}/verify?ballot_id=<id>` so native phone cameras recognize them as actionable links. The ballot ID is already printed as plain text on the physical ballot, so encoding it in a URL introduces no new exposure. The `/verify` endpoint only queries the anonymous `ballots` table — voter identity is never revealed.

## Wave 5 Security / Privacy Additions (v0.12.0)

- **Eligibility fail-closed enforcement:** `UNDETERMINED` eligibility is treated as ineligible by default, with eligibility checks enforced at dispatch + cast paths (defense-in-depth).
- **Age-derived-only model:** age eligibility is derived and stored as a boolean (`is_age_eligible`); DOB is not persisted.
- **Aggregate-only result export posture:** application-supported export is aggregate tally only (no default raw roster/token/audit export endpoint).
- **Append-only governance/adjudication ledger:** governance and adjudication records are append-only, with anti-TRUNCATE protection for governance ledger retention.

## Wave 10 Security Additions (v0.15.1)

- **Eligibility phase-gating (SETUP-only):** eligibility changes are rejected outside SETUP phase (API returns 400, UI shows read-only mode). Prevents eligibility toggling during VOTING/NOMINATION which could suppress votes or create disputes over already-cast ballots.

## Accepted Residuals

### Admin role separation (Decision E) — deferred

The system does not implement role separation among administrators. There is a single shared
admin credential (`ADMIN_SECRET`), and every authenticated admin can access all admin surfaces —
including the participation view (who has voted, via which channel, and coarse time — **never how
they voted**), PII purge, and ballot-keyed correction. A dedicated `dispute-resolution` role and a
per-view access log were designed (`docs/specs/2026-09-17-v0.13.0-anonymity-design.md` §7) but
**deliberately deferred** (`docs/plans/2026-09-17-decision-e-rbac-backlog.md`).

**Why this is an accepted, proportionate residual:**
- Role separation is a **least-privilege / defense-in-depth** measure, not the substantive
  anonymity control. The substantive control is the identity↔vote linkage severance, which does
  not depend on it.
- No admin surface exposes voter *choice*; the residual concerns *who can see participation
  metadata and run privileged actions*, not confidentiality of the vote.
- The current deployment operates with a single trusted admin principal and no differentiated
  admin duties, so RBAC would separate nothing today. GDPR Art. 25/32 measures are met by the
  severance plus organizational controls proportionate to a small, trusted operator team.

**Revisit trigger:** the deployment becomes multi-admin with separated duties (e.g. a scrutineer
who resolves disputes but must not run PII purge). At that point role separation becomes a genuine
control and should be built (design + additive-implementation notes in the backlog doc above).

## GDPR / Real-PII Readiness

> ## ⚠️ Status: PARTIALLY REMEDIATED — verify remaining findings before real-PII load.
> The v0.13.x Security/Anonymity Wave (paper severance + digital severance + app-layer
> reconciliation) has **shipped**: F2, F3, F3b, and F15 remediations are live in production.
> **F4 and F11 remain OPEN** (re-verified 2026-09-20); F14 is in progress (CSP Tier-1/Tier-2);
> F1 (git history purge) completion is not verified in this document.

The Wave 5 GDPR council review returned a **NO-GO** for real-PII deployment. v0.12.0 was functionally complete for workflow/UAT and synthetic datasets, but not compliant/safe enough for production personal-data processing. The v0.13.x wave resolved the architectural NO-GO findings (F2/F3/F3b) via the paper-plane severance and digital-channel severance; the remaining findings below must be closed and verified before loading real personal data.

### Findings summary

| ID | Severity | GDPR article | Area / file | Risk summary | Planned remediation |
|---|---|---|---|---|---|
| F1 | Critical | Art.17 | repo hygiene (`/data`, `/archives`) | Roster PII and result archives were committable; real test email addresses were committed to git history. | `/data/` + `/archives/` now gitignored; full history purge tracked as follow-up decision in Security/Anonymity Wave (v0.13.0). |
| F2 | Critical | Art.9 / Art.25 | `paper_ballots`, `vote_audit_log` | Same-row storage of `member_id` and `candidate_id` creates a plaintext identity↔vote register. | Option C architectural linkage-break in v0.13.0 (remove direct joinability). |
| F3 | Critical | Art.9 | `submit_anonymous_vote` flow | Vote writer receives token-hash + candidate together and writes ballot + token update in one transaction; privileged observers can correlate. | v0.13.0 redesign to split trust boundaries and unlink identity from vote write path. |
| F3b | Critical | Art.9 | service-role/admin observability logs | Admin/service-role/query-log visibility can deanonymize transaction-level identity↔choice linkage. | v0.13.0 anonymity hardening + logging posture changes (Options B+C package). |
| F4 | Critical | Art.25 | `lib/supabase-server.ts` + public `/verify` and `/results` consumption path | Singleton service-role client currently backs public read paths; principle-of-least-privilege violation. | v0.13.0 key-scope split and least-privilege read architecture. |
| F11 | Medium | Art.5(1)(c) | token dispatch dry-run logging | Dry-run token dispatch logs member name/email/magic-link payloads. | Redact/suppress PII-bearing dry-run logs in v0.13.0. |
| F14 | Medium | Art.25 | CSP policy | Production CSP allows `unsafe-inline` + `unsafe-eval`. | Tighten CSP to nonce/hash-based script/style policy in v0.13.0. |
| F15 | Medium | Art.25 | `supabase/schema.sql` replay risk | Re-running `schema.sql` (`CREATE OR REPLACE`) can regress the vote writer back to a leaky payload. | Final-writer migration discipline + replay guards in v0.13.0. |

### Remediation track

The v0.13.x Security/Anonymity Wave **shipped** (paper + digital severance, split audit tables, no-colocation triggers, final-writer discipline). Remaining before real-PII load:

- **F4 — key-scope split (OPEN):** `/api/verify` still backs public read paths with the service-role singleton (`app/api/verify/route.ts:2,39,51`). Least-privilege read architecture not built.
- **F11 — dry-run log redaction (OPEN):** token-dispatch dry-run still logs member name/email/magic-link (`app/api/admin/tokens-dispatch/route.ts:253`).
- **F14 — CSP tightening (IN PROGRESS):** Tier-1 (drop prod `'unsafe-eval'`) + Tier-2 (per-request nonce, drop `'unsafe-inline'`); plan at `docs/plans/2026-09-18-f14-csp-tier2-nonce.md`.
- **F1 — git history purge (UNVERIFIED):** `/data/` + `/archives/` are gitignored; whether the committed-PII history purge was completed is not verified here.

Until F4/F11/F14 are closed and verified, production use remains restricted to **synthetic data only**.
