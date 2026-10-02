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
  - keeps current `rateLimit.limit` value (reads live limit and re-applies it)
  - `action.mitigate.rateLimit.action="log"`
- Uses explicit full rate-limit action flags on `rules edit` (`--action rate_limit --rate-limit-window 60 --rate-limit-requests <live limit> --rate-limit-algo fixed_window --rate-limit-keys ip --rate-limit-action log --enabled --yes`) so Vercel CLI stages a real draft.
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
- Uses explicit full rate-limit action flags on `rules edit` (`--action rate_limit --rate-limit-window 60 --rate-limit-requests <operator value> --rate-limit-algo fixed_window --rate-limit-keys ip --rate-limit-action rate_limit --enabled --yes`).
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
7. After staging, diff is **exactly one** change with exact keys:
   - `action`, `createdAt`, `id`, `userId`, `username`, `value`
   - `action` must be `rules.update`
   - `id` must be the pinned rule ID
   - audit fields are type-checked as strings (no hardcoded identity values)
8. Staged `value` deep-compares to pre-stage full rule with only intended field changes allowed.
   - Draft `value` is strict: it must contain **exactly** these four top-level keys: `name`, `active`, `conditionGroup`, `action`.
   - Comparison normalizes **expected live rule only** by removing metadata fields that are not part of draft value.
9. Diff is re-validated **after** operator types `PUBLISH` and immediately before publish call.

Only expected live metadata is ignored during deep comparison (the staged draft `value` must not contain these keys):

- `id` (diff draft `value` only; post-publish live rule still includes `id`)
- `valid`
- `validationErrors`
- `_status`

Unknown fields or unexpected diff shapes are treated as unsafe and fail execution.

## Supervised live trials (2026-10-02)

- A manual CLI edit was staged and published at `limit=2`, `action=rate_limit`; four bounded invalid-secret requests to the production alias returned 401, 401, 429, 429. This pattern is consistent with the WAF threshold, but **rule-specific Firewall event attribution was not retrieved**; the responses alone do not prove their source.
- A manual CLI edit then restored `limit=10`, `action=rate_limit`. The live rule was verified and no drafts remained. This is the current live state.
- The first helper attempt omitted flags required by Vercel CLI v54.11.1 and safely stopped without staging a draft; the helper was corrected to supply the complete rate-limit action flags.
- The next live helper edit stalled at the CLI staging spinner and was interrupted. The live rule was unchanged and no draft remained; a later bounded manual CLI edit established the real draft format.
- With that format reflected in the helper, a real `observe` helper run staged exactly one update (`limit=10`, `action=log`), showed the expected diff, and stopped when the operator entered `NO` instead of `PUBLISH`. The sole draft was independently inspected and discarded. The live `limit=10`, `action=rate_limit` rule and empty draft state were verified afterward.
- This confirms the helper's real **staging and refusal** path, not its real publish/disable path. The fixture suite covers those paths; they have not yet been exercised through the helper against Vercel.
- Real draft JSON included the audit fields `username`, `createdAt`, and `userId`; its `value` contained exactly `name`, `active`, `conditionGroup`, and `action` (no `id`). The helper requires that shape and rejects additional fields.

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
- extra audit metadata field in staged change envelope
- unknown diff shape
- preexisting unrelated draft markers
- concurrent draft introduced after confirmation
- project/org ID mismatch
- operator refusal with staged-draft/live immutability assertion
- known-bad immutability guard (fails if fake edit mutates live immediately)
- known-bad guard (invalid live rule shape) preventing publish
