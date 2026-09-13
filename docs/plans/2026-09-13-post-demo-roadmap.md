# Post-Demo Roadmap — anonymous-election

**Status:** Draft for approval · **Created:** 2026-09-13 · **Baseline:** `v0.6.0` (`main`)

This is the authoritative sequencing of all post-demo backlog work. It replaces
the ad-hoc "Wave" labels previously used only in shipped increments — those were
never captured as a plan. Every wave below traces to a `BACKLOG:` memory and/or
source location; nothing here is speculative.

**Standing rules (from AGENTS.md + user directives):**

- Each wave is **plan-gated**: present the wave plan and get explicit go-ahead
  before any code or DB change.
- **No merge to `main` without explicit confirmation.**
- `app/admin/dashboard/page.tsx` and `app/admin/mobile-assign/page.tsx` are
  **designer-owned** — do not flatten; UI changes route through `@designer`,
  mechanical wiring through `@fixer` only when it preserves the design exactly.
- DB changes apply via **Supabase MCP** (`apply_migration` for DDL); `.sql`
  files remain source-of-truth + canonical run order.
- **Vercel does not auto-deploy** — UI changes need `vercel --prod --yes`;
  RPC-only DB changes need no redeploy.

---

## Already shipped (pre-roadmap, for context)

| Version | Increment |
|---------|-----------|
| `v0.3.0` | Opaque ballot IDs (Tier-1 anonymity leak closed) |
| `v0.4.x` | Nomination-flow security hardening |
| `v0.5.0` | A6 printable paper ballots + mobile-phone admin assignment |
| `v0.6.0` | Wave 0.2 — Member Management Integrity (phase-gated roster edits, `member_code`-keyed import) |

---

## Wave sequence

Ordering optimizes for: shovel-ready first, security next, then integrity,
privacy, polish, and go-live gating last. Dependencies are called out per wave.

### Wave 1 — Nomination Submit-Flow + Token Reissue  *(feature; most shovel-ready)*

- **Why first:** Specs + implementation plans are already **finalized, committed,
  and oracle-hardened** — only the user-review gate + execution remain.
- **Scope:**
  - Spec 1 — nomination submission (14 reqs): `docs/specs/2026-09-04-nomination-submission-design.md`; plan `docs/plans/2026-09-04-nomination-submission.md` (11 tasks).
  - Spec 2 — token reissue (8 reqs): `docs/specs/2026-09-04-token-reissue-design.md`; plan `docs/plans/2026-09-04-token-reissue.md` (6 tasks + preflight).
- **Order:** Spec 1 **before** Spec 2 (Spec 2 depends on Spec 1's token guards).
- **Dependency:** Spec 2's migration is best applied on a **clean DB at the
  Option B wipe (Wave 8)** — so either land Spec 2 code now but defer its
  migration to Wave 8, or sequence Spec 2 alongside go-live prep.
- **Route:** `executing-plans` (inline) → `@verifier`.
- **Source:** `mem_20260904_67dz`.

### Wave 2 — Admin Session Security & UX Overhaul  *(security; no migration)*

- **Problem:** Absolute-only 30-min server TTL; client 15-min inactivity timer
  is UX-only, not a security control; expired sessions leave a stale "logged-in"
  shell because `apiFetch` never inspects 401s.
- **Scope (OWASP idle + absolute):**
  1. Server-enforced **sliding idle** (~10 min; bump `expires_at` on each
     authorized request in `requireAdmin`) + **absolute cap** (~2–4 h; reject if
     `now > created_at + MAX`, never extended); revoke on expiry (`revoked_at`)
     so the token can't replay. **No migration** — `admin_sessions` already has
     `created_at`/`expires_at`/`revoked_at`.
  2. Client timer downgraded to a pre-expiry **warning/countdown**.
  3. Context-aware 401 handling centralized in `apiFetch`: idle expiry → full
     login view; absolute/mid-task expiry → **in-place re-auth modal** (preserve
     React state) requiring the actual secret.
- **Route:** `@oracle` (sign off absolute-cap intent) → `@designer` (modal
  look/feel) + `@fixer` (auth + interceptor, additive; do not flatten). Subsumes
  the standalone stale-shell 401 item.
- **Source:** `mem_20260911_2g97` (+ `mem_20260908_98db`).

### Wave 3 — Paper-Ballot Integrity: Model A token-reserve-at-issue  *(small, coordinated RPC)*

- **Goal:** Make Model A symmetric with Model B — reserve the member's VOTING
  token at **issue** time (`private.issue_paper_ballot`), not only at
  vote-record. Closes the digital door at issue (defense-in-depth).
- **Already done (verify before building):** the spoil-gate half is **deployed**
  — `private.spoil_paper_ballot` allow-list already includes `ISSUED` and frees
  the reserved token for `ISSUED_TO_VOTER`. So **only the issue-side reserve
  remains**.
- **Preflight:** re-verify deployed `spoil_paper_ballot` via `pg_get_functiondef`
  before changing `issue_paper_ballot` (avoid stranding tokens on spoil).
- **Route:** `@oracle` (confirm cross-channel/double-vote guard) → `@fixer`
  (migration) → `@verifier`.
- **Source:** `mem_20260912_qp5d` (supersedes `_q78j`).

### Wave 4 — Digital Voter Self-Verification  *(privacy-correct fix)*

- **Problem:** Confirmation screen shows only the `VC-…` receipt code, but
  `/verify` requires the `ballot_id` (`DIGITAL:…`) the voter never sees — so
  digital voters can't self-verify.
- **Fix (must NOT email anything):** surface `ballot_id` **device-locally** on
  the confirmation screen (Copy/Download/Print), or rework `/verify` to accept
  `receipt_code` alone for digital.
- **Guardrail codified:** the "email me the receipt" button stays **rejected**
  as an anonymity/receipt-freeness regression — document it as a won't-do.
- **Route:** `@oracle` (pick verification model) → `@fixer`.
- **Source:** `mem_20260911_wjru` (Item B fix; Item A guardrail).

### Wave 5 — GDPR Privacy Subsystem  *(largest; decisions gate first)*

- **Prerequisite:** a **brainstorming pass** to resolve 4 open decisions before
  any build:
  (a) default stance for UNDETERMINED eligibility before VOTING;
  (b) build as a general `voting_eligible` override with reason codes vs.
      age-specific;
  (c) does age apply to paper voters too or digital-only;
  (d) keep raw DOB or derived boolean only.
- **Scope:**
  1. **PII retention/purge** (direction confirmed): admin-triggered, confirmed,
     audit-logged "Purge roster PII" action — purge email+phone at
     `VOTING_CLOSED`; anonymize `full_name` after ~30-day dispute window; keep
     `member_id` shell + voted-flag (never hard-delete — FKs). Privacy notice at
     CSV import.
  2. **Configurable age-eligibility** (toggleable, multi-org reusable):
     `age_requirement_enabled` (default OFF) + `minimum_voting_age`;
     `is_age_eligible`/`voting_eligible`/`eligibility_source`; conditional
     "Voter Eligibility" adjudication tab + `eligibility_adjudications` audit
     table; gate dispatch/issuance on `voting_eligible`. Prefer derived-boolean
     over raw DOB (reconciles with item 1's minimization).
- **Route:** brainstorming (decisions) → `@oracle` (schema+flow) → `@designer`
  (new tab UI) → `@fixer`/`@verifier`.
- **Source:** `mem_20260911_e0yc` (+ folds `mem_20260911_wjru`).

### Wave 6 — UX Polish Bundle  *(non-blocking; can parallelize)*

Independent small items; group into one branch or split by owner.

1. **Member-picker typeahead** on paper-ballot Assign/Search (nomination-style
   autocomplete). `@designer` — designer-owned page. `mem_20260911_66xb`.
2. **Token Dispatch "Select All with Email"** — filter email-less members,
   grey/tag them, live "N selectable / M no email" count. `@fixer` logic +
   `@designer` styling. `mem_20260908_mhn0`.
3. **Nominate short-prefix search** — switch `search_members_for_nomination`
   from pg_trgm `%` (whole-string) to word_similarity `<%` so prefixes like
   "kimb" match. RPC-only. `@fixer` + `@verifier`. `mem_20260908_nmr9`.
4. **Model A single-ballot print layout** — currently `print:hidden`, so
   Ctrl+P renders nothing; give Model A its own print-only layout like Model B.
   `@designer` → `@verifier`. `mem_20260911_9r6b`.
5. **"nominationrecorded" spacing** — source has the space; likely **deploy
   drift**. Verify deployed-vs-source first; robust fix = explicit `{' '}`
   separator, then redeploy. Low-priority cosmetic. `@fixer`. `mem_20260908_af7n`.

### Wave 7 — Data-Hygiene: wipe-list correctness  *(pre-go-live safety)*

- **Problem:** The SETUP re-seed/destructive wipe does **not** clear the
  `tokens` table; a reseed can leave stale/unexpired tokens → potential
  double-token vector (currently mitigated only by member-level one-vote guard).
- **Fix:** add `tokens` (and confirm `ballots`) to the documented wipe list in
  `docs/TECHNICAL_GUIDE.md` canonical run order + any reseed script; re-verify
  the member-level one-vote guard in `submit_anonymous_vote` during triage.
- **Route:** `@fixer` (docs + script) → `@verifier`.
- **Source:** `mem_20260911_rhfl`.
- **Why before Wave 8:** the Option B wipe must use the corrected list.

### Wave 8 — Go-Live Gating  *(terminal; do only when distributing real links)*

Sequential, and **last**:

1. **Option B wipe → empty SETUP.** Fresh backup first. TRUNCATE all data tables
   to empty (candidates, tokens, anonymous_nominations, ballots, paper_ballots,
   paper_ballot_batches, vote_audit_log, phase_change_tokens, admin_sessions,
   rate_limit_hits CASCADE; DELETE members), **skip `seed.sql`**, set
   `current_phase='SETUP'`. Apply Wave 1 Spec 2 migration here on the clean DB.
   `mem_20260903_gy03`.
2. **Import real members** via `scripts/import-members.js`; **dispatch tokens**.
3. **Downgrade Supabase MCP to read-only** — add `&read_only=true` to the
   `mcp.supabase` URL in `~/.config/opencode/opencode.json`, restart opencode.
   **This is the very last action** (write access is needed through step 2).
   `mem_20260903_0s22`.

---

## Dependency summary

- **Wave 1 (Spec 2 migration)** → best applied at **Wave 8 step 1** (clean DB).
- **Wave 3** → preflight re-verify deployed spoil gate.
- **Wave 5** → 4 decisions resolved (brainstorming) before build; age-eligibility
  adds PII, so build derived-boolean-first to stay consistent with PII
  minimization.
- **Wave 7** → must precede **Wave 8** (wipe uses corrected table list).
- **Wave 8** → terminal; MCP read-only is the final step, after real-member
  import + token dispatch.

## Suggested execution order

`1 → 2 → 3 → 4 → 6 (opportunistic parallel) → 5 → 7 → 8`

(Wave 5 sits after the quick wins because it's the largest and still needs
decisions; Waves 7–8 are strictly go-live gating.)
