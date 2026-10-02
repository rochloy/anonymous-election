# Login WAF Operations (Operator Runbook)

This runbook documents `scripts/manage-login-waf.sh`, an interactive helper for one pinned Vercel firewall rule:

- **ID:** `rule_login_rate_limit_observation_6Qv4nI`
- **Name:** `Login rate-limit observation`
- **Target:** one `conditionGroup` entry with exactly two conditions:
  - `path eq /api/admin/login`
  - `method eq POST`

## Linked checkout and CLI routing

All Vercel calls are pinned to the linked main checkout using `--cwd`:

- Default linked checkout: `/home/rtaniman/Programs/opencode-projects/anonymous-election`
- Optional override (tests/controlled scenarios): `MANAGE_LOGIN_WAF_LINKED_MAIN=/abs/path`

The script validates `.vercel/project.json` in the linked checkout before any firewall call:

- `projectId = prj_Ha0FArHnIMgFTLhWMAZsVf86J3k0`
- `orgId = team_W8yuVa7lHUXqrhvWCc1bmcfH`

If the IDs do not match, execution stops.

## Modes

```bash
scripts/manage-login-waf.sh status
scripts/manage-login-waf.sh observe
scripts/manage-login-waf.sh enforce
scripts/manage-login-waf.sh disable
```

### `status` (strictly read-only)

- Validates pinned rule shape against Vercel CLI v54.11.1 JSON schema currently observed.
- Prints enabled state, limit, and exceed action.
- If `hasDraft`/`pendingChanges` or non-empty diff exists, prints warnings only.
- Never edits, disables, discards, or publishes.

### `observe`

- Stages update for pinned rule only:
  - `active=true`
  - `action.mitigate.rateLimit.action="log"`
- Requires typed `PUBLISH`.
- Re-checks diff immediately before publish.

### `enforce`

- Prompts for canonical decimal integer `1..10000000` only.
  - Accepted format: `0` or non-zero without leading zeros (`^(0|[1-9][0-9]*)$`), then range-checked to reject `0` and `>10000000`.
  - Inputs like `08`, `007`, empty, text, and extremely long digit strings are rejected before any staged mutation.
- Warns for values `<=5` (shared IP/NAT risk).
- Stages update for pinned rule only:
  - `active=true`
  - `action.mitigate.rateLimit.limit=<operator value>`
  - `action.mitigate.rateLimit.action="rate_limit"`
- Requires typed `PUBLISH`.
- Re-checks diff immediately before publish.

### `disable`

- Stages update for pinned rule only:
  - `active=false`
- Requires typed `PUBLISH`.
- Re-checks diff immediately before publish.

## Safety model (fail-closed)

For mutate modes (`observe`, `enforce`, `disable`) the script refuses to continue unless all checks pass:

1. Linked checkout project/org IDs match pinned IDs.
2. `vercel firewall rules list --json` envelope is exact expected shape (`rules`, `hasDraft`, `pendingChanges`).
3. Exactly one rule matches pinned ID+name.
4. Pinned rule is exact expected shape (including condition group array, rate-limit fields, and key sets).
5. `hasDraft=false` and `pendingChanges=0` before mutation.
6. `vercel firewall diff --json` is exact expected shape and empty before mutation.
7. After staging, diff is **exactly one** change:
   - `{action:"rules.update", id:<pinned id>, value:<full rule object>}`
8. Staged `value` deep-compares to pre-stage full rule with only intended field changes allowed.
9. Diff is re-validated **after** operator types `PUBLISH` and immediately before publish call.

Only read-only presentation metadata is ignored during deep comparison:

- `valid`
- `validationErrors`
- `_status`
- `hasDraft`

Unknown fields or unexpected diff shapes are treated as unsafe and fail execution.

## Publish race warning (TOCTOU)

After confirmation, script performs an immediate draft re-check before calling publish.

Residual TOCTOU remains because `vercel firewall publish` has no conditional version guard. Operate in an exclusive operator window.

## Post-publish verification

After successful publish call, script verifies:

1. Rules envelope reports `hasDraft=false` and `pendingChanges=0`.
2. Live pinned rule matches expected post-change full object (metadata-ignored deep compare).
3. `vercel firewall diff --json` is empty.

On failure, script exits non-zero and never auto-discards drafts.

## Prohibited automatic operations

Script does **not** run `vercel firewall discard`.

Tests ensure safety failures prevent `vercel firewall publish`.

## Test harness

Run:

```bash
scripts/test-manage-login-waf.sh
```

The harness injects a fake `vercel` binary in `PATH` and verifies all mutation paths are intercepted. It keeps live rule immutable until fake publish (draft-only updates before publish).

Covered cases include:

- status read-only warning behavior with drafts
- observe/enforce/disable success paths
- enforce input/range validation + low-threshold warning
- wrong change action
- wrong change id
- extra condition in staged value
- changed base action
- extra config field in staged value
- unknown diff shape
- preexisting unrelated draft markers
- concurrent draft introduced after confirmation
- project/org ID mismatch
- operator refusal with staged-draft/live immutability assertion
- known-bad immutability guard (fails if fake edit mutates live immediately)
- known-bad guard (invalid live rule shape) preventing publish
