# Nomination Submission & Adjudication — Implementation Plan (Spec 1)

> **For implementers:** Use the `executing-plans` skill (inline) or have the orchestrator dispatch one `@fixer` per task with review between tasks. Steps use checkbox (`- [ ]`) syntax for tracking. DB tasks are applied via the **Supabase MCP** (`supabase_apply_migration` / `supabase_execute_sql`) because this project has **no direct Postgres URL** — SQL is never run from app code (project AGENTS.md).

**Goal:** Implement the missing NOMINATION submission flow — token-gated digital nomination, non-consuming roster search, admin out-of-band entry, and admin adjudication of nominees into candidates — without ever linking a nomination to its nominator.

**Architecture:** All writes go through `SECURITY DEFINER` RPCs in the `private` schema (mirrors `submit_anonymous_vote`). The submit RPC reads the member only to validate/consume the token, inserts anonymous rows, and marks the token used — one transaction. Public routes hash the raw token server-side and call the RPC via the service-role client.

**Tech Stack:** Next.js 16.2.12 (App Router, Turbopack), TypeScript, Supabase/Postgres (RLS + `private` RPCs), Tailwind v4, Resend, `pg_trgm`.

**Branch:** `agent/nomination-submit-flow` (already checked out).

**Spec:** `docs/specs/2026-09-04-nomination-submission-design.md` (OpenSpec §12 requirements are the acceptance criteria).

---

## Preflight (do once, before Task 1)

- [ ] **P.1 — Read the framework docs.** Project AGENTS.md: "This is NOT the Next.js you know." Before writing any route/page, read `node_modules/next/dist/docs/` for App Router route handlers and `next.config.ts` `headers()`.
- [ ] **P.2 — Confirm branch + clean tree.**

Run: `git -C /home/rtaniman/Programs/opencode-projects/anonymous-election status --porcelain && git rev-parse --abbrev-ref HEAD`
Expected: clean tree, branch `agent/nomination-submit-flow`.

- [ ] **P.3 — Confirm helpers exist** (used by later tasks): `lib/api-errors.ts` exports `rateLimitError`, `validationError`; a `check_rate_limit` RPC exists; `lib/audit-log.ts` exports `insertAuditLog`; `app/api/admin/auth.ts` exports `requireAdmin`, `requireAdminWithCsrf`, `getAdminSession`.

Run: `grep -rn "export function rateLimitError\|export function validationError" app lib; grep -rn "check_rate_limit" supabase; grep -rn "export async function insertAuditLog\|export function insertAuditLog" lib`
Expected: each found.

---

## Task 1: DB migration — schema, RLS, immutability, settings, adjudications

**Files:**
- Create: `supabase/migration_nomination_submission.sql`
- Apply via: `supabase_apply_migration` (name: `nomination_submission`)

- [ ] **Step 1: Write the migration file (schema half).**

```sql
-- migration_nomination_submission.sql  (Spec 1) — run AFTER the CANONICAL sequence.
-- Extensions: Supabase installs pg_trgm into the `extensions` schema.
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- 1. anonymous_nominations: add nominee link + provenance
ALTER TABLE anonymous_nominations
  ADD COLUMN IF NOT EXISTS nominee_member_id UUID REFERENCES members(id) NULL,
  ADD COLUMN IF NOT EXISTS source TEXT NOT NULL DEFAULT 'DIGITAL'
    CHECK (source IN ('DIGITAL','ADMIN'));

-- trigram index for roster name search
CREATE INDEX IF NOT EXISTS idx_members_full_name_trgm
  ON members USING gin (full_name gin_trgm_ops);

-- 2. RLS lockdown (base schema never enabled RLS on this table)
ALTER TABLE anonymous_nominations ENABLE ROW LEVEL SECURITY;  -- no public policy
GRANT SELECT, INSERT ON anonymous_nominations TO service_role;

-- 3. Immutability trigger (append-only; TRUNCATE for wipes is unaffected)
CREATE OR REPLACE FUNCTION private.reject_nomination_mutation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'anonymous_nominations rows are immutable (append-only).';
END; $$;

DROP TRIGGER IF EXISTS trg_nominations_immutable ON anonymous_nominations;
CREATE TRIGGER trg_nominations_immutable
  BEFORE UPDATE OR DELETE ON anonymous_nominations
  FOR EACH ROW EXECUTE FUNCTION private.reject_nomination_mutation();

-- 4. election_settings config
ALTER TABLE election_settings
  ADD COLUMN IF NOT EXISTS allow_write_ins BOOLEAN NOT NULL DEFAULT TRUE,
  ADD COLUMN IF NOT EXISTS max_nominees_per_member SMALLINT NOT NULL DEFAULT 1
    CHECK (max_nominees_per_member BETWEEN 1 AND 3);

-- 5. Admin adjudication provenance (never links a nominator)
CREATE TABLE IF NOT EXISTS nomination_adjudications (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  admin_id UUID REFERENCES members(id),
  decision TEXT NOT NULL CHECK (decision IN ('PROMOTE','MERGE','DISCARD')),
  candidate_id UUID REFERENCES candidates(id),
  nominee_member_id UUID REFERENCES members(id),
  affected_nomination_ids UUID[] NOT NULL DEFAULT '{}',
  note TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE nomination_adjudications ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT ON nomination_adjudications TO service_role;

-- Idempotent promotion: at most one PROMOTE candidate per matched nominee
CREATE UNIQUE INDEX IF NOT EXISTS idx_adjudication_one_promote_per_nominee
  ON nomination_adjudications (nominee_member_id)
  WHERE decision = 'PROMOTE' AND nominee_member_id IS NOT NULL;
```

- [ ] **Step 2: Apply the migration.** Use `supabase_apply_migration` name=`nomination_submission` with the SQL above.

- [ ] **Step 3: Verify schema + RLS + immutability.** Run via `supabase_execute_sql`:

```sql
-- columns present
SELECT column_name FROM information_schema.columns
WHERE table_name='anonymous_nominations' ORDER BY 1;   -- expect nominee_member_id, source (+ existing)
-- RLS on
SELECT relrowsecurity FROM pg_class WHERE relname='anonymous_nominations';  -- expect true
-- immutability fires
INSERT INTO anonymous_nominations (nominee_name) VALUES ('__t__');
DO $$ BEGIN
  BEGIN UPDATE anonymous_nominations SET reason='x' WHERE nominee_name='__t__';
    RAISE EXCEPTION 'IMMUTABILITY FAILED';
  EXCEPTION WHEN others THEN RAISE NOTICE 'immutability OK: %', SQLERRM; END;
END $$;
DELETE FROM anonymous_nominations WHERE nominee_name='__t__';  -- also should raise
```
Expected: columns present; `relrowsecurity=true`; UPDATE and DELETE both raise "immutable" (the guard test — a green run only proves the negative case). Clean up the `__t__` row with `TRUNCATE anonymous_nominations` if needed (TRUNCATE bypasses the row trigger).

- [ ] **Step 4: Commit.**

```bash
git add supabase/migration_nomination_submission.sql
git commit -m "feat(db): nomination schema, RLS, immutability trigger, settings, adjudications"
```

---

## Task 2: DB RPC — `private.submit_nomination`

**Files:** Append to `supabase/migration_nomination_submission.sql`; re-apply the new function block.

- [ ] **Step 1: Write the RPC (append to the migration file).**

```sql
CREATE OR REPLACE FUNCTION private.submit_nomination(
  p_token_hash VARCHAR(64),
  p_nominees   JSONB
)
RETURNS TABLE (success BOOLEAN, message TEXT, inserted_count INT)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE
  v_phase election_phase; v_nom_start TIMESTAMPTZ; v_nom_end TIMESTAMPTZ;
  v_allow_write_ins BOOLEAN; v_max SMALLINT;
  v_token_id UUID; v_member_id UUID; v_is_used BOOLEAN;
  v_expires_at TIMESTAMPTZ; v_voided_at TIMESTAMPTZ;
  v_count INT; v_elem JSONB;
  v_nominee_member_id UUID; v_nominee_name TEXT; v_reason TEXT; v_norm TEXT;
  v_seen_members UUID[] := '{}'; v_seen_names TEXT[] := '{}'; v_inserted INT := 0;
BEGIN
  SELECT current_phase, nomination_start, nomination_end, allow_write_ins, max_nominees_per_member
    INTO v_phase, v_nom_start, v_nom_end, v_allow_write_ins, v_max
    FROM election_settings WHERE id = 1;

  IF v_phase <> 'NOMINATION' THEN
    RETURN QUERY SELECT FALSE, 'Nomination phase is not open.'::TEXT, 0; RETURN; END IF;
  IF (v_nom_start IS NOT NULL AND NOW() < v_nom_start)
     OR (v_nom_end IS NOT NULL AND NOW() > v_nom_end) THEN
    RETURN QUERY SELECT FALSE, 'Nomination window is closed.'::TEXT, 0; RETURN; END IF;

  SELECT id, member_id, is_used, expires_at, voided_at
    INTO v_token_id, v_member_id, v_is_used, v_expires_at, v_voided_at
    FROM tokens WHERE token_hash = p_token_hash AND type = 'NOMINATION' FOR UPDATE;

  IF v_token_id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Invalid or non-existent nomination token.'::TEXT, 0; RETURN; END IF;
  IF v_voided_at IS NOT NULL THEN
    RETURN QUERY SELECT FALSE, 'This nomination token has been voided.'::TEXT, 0; RETURN; END IF;
  IF v_expires_at IS NULL OR v_expires_at <= NOW() THEN
    RETURN QUERY SELECT FALSE, 'This nomination token has expired.'::TEXT, 0; RETURN; END IF;
  IF v_is_used THEN
    RETURN QUERY SELECT FALSE, 'This nomination token has already been used.'::TEXT, 0; RETURN; END IF;

  IF p_nominees IS NULL OR jsonb_typeof(p_nominees) <> 'array' THEN
    RETURN QUERY SELECT FALSE, 'Invalid nominees payload.'::TEXT, 0; RETURN; END IF;
  v_count := jsonb_array_length(p_nominees);
  IF v_count < 1 THEN
    RETURN QUERY SELECT FALSE, 'At least one nominee is required.'::TEXT, 0; RETURN; END IF;
  IF v_count > v_max THEN
    RETURN QUERY SELECT FALSE, format('At most %s nominee(s) allowed.', v_max)::TEXT, 0; RETURN; END IF;

  -- Validate ALL elements before inserting ANY (all-or-nothing).
  FOR v_elem IN SELECT * FROM jsonb_array_elements(p_nominees) LOOP
    v_nominee_member_id := NULLIF(v_elem->>'nominee_member_id','')::UUID;
    v_nominee_name := trim(coalesce(v_elem->>'nominee_name',''));
    v_reason := v_elem->>'reason';

    IF v_reason IS NOT NULL AND length(v_reason) > 2000 THEN
      RETURN QUERY SELECT FALSE, 'Reason exceeds 2000 characters.'::TEXT, 0; RETURN; END IF;

    IF v_nominee_member_id IS NOT NULL THEN
      SELECT full_name INTO v_nominee_name FROM members
        WHERE id = v_nominee_member_id AND is_active = TRUE;      -- canonicalize; ignore client name
      IF v_nominee_name IS NULL THEN
        RETURN QUERY SELECT FALSE, 'Nominee not found or inactive.'::TEXT, 0; RETURN; END IF;
      IF v_nominee_member_id = ANY(v_seen_members) THEN CONTINUE; END IF;
      v_seen_members := array_append(v_seen_members, v_nominee_member_id);
    ELSE
      IF NOT v_allow_write_ins THEN
        RETURN QUERY SELECT FALSE, 'Write-in nominees are not allowed.'::TEXT, 0; RETURN; END IF;
      IF v_nominee_name = '' THEN
        RETURN QUERY SELECT FALSE, 'Nominee name is required for write-ins.'::TEXT, 0; RETURN; END IF;
      IF length(v_nominee_name) > 100 THEN
        RETURN QUERY SELECT FALSE, 'Nominee name exceeds 100 characters.'::TEXT, 0; RETURN; END IF;
      v_norm := lower(v_nominee_name);
      IF v_norm = ANY(v_seen_names) THEN CONTINUE; END IF;
      v_seen_names := array_append(v_seen_names, v_norm);
    END IF;

    INSERT INTO anonymous_nominations (nominee_member_id, nominee_name, reason, source)
    VALUES (v_nominee_member_id, v_nominee_name, v_reason, 'DIGITAL');   -- NO nominator identity
    v_inserted := v_inserted + 1;
  END LOOP;

  UPDATE tokens SET is_used = TRUE, used_at = NOW() WHERE id = v_token_id;  -- consume
  RETURN QUERY SELECT TRUE, 'Nomination submitted.'::TEXT, v_inserted;
END;
$$;

REVOKE EXECUTE ON FUNCTION private.submit_nomination(VARCHAR, JSONB) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.submit_nomination(VARCHAR, JSONB) TO service_role;
```

- [ ] **Step 2: Apply** via `supabase_apply_migration` name=`nomination_submit_rpc` (the `CREATE OR REPLACE` block above).

- [ ] **Step 3: Verify anonymity + guards (test).** Run via `supabase_execute_sql` on the seed DB (phase must be NOMINATION for the happy path; set it, test, restore):

```sql
-- Setup: a NOMINATION token for a known member.
UPDATE election_settings SET current_phase='NOMINATION', max_nominees_per_member=1, allow_write_ins=true WHERE id=1;
WITH m AS (SELECT id FROM members WHERE is_active LIMIT 1)
INSERT INTO tokens (member_id, token_hash, type, is_used, expires_at)
SELECT m.id, repeat('a',64), 'NOMINATION', false, now()+interval '1 day' FROM m;

-- Happy path: matched nominee, client name should be ignored.
SELECT * FROM private.submit_nomination(repeat('a',64),
  '[{"nominee_member_id":"'||(SELECT id FROM members WHERE is_active LIMIT 1)||'","nominee_name":"WRONG","reason":"good"}]'::jsonb);
-- expect success=true, inserted_count=1

-- ANONYMITY ASSERTION: row carries nominee, NOT nominator; name canonicalized.
SELECT nominee_name = (SELECT full_name FROM members WHERE is_active LIMIT 1) AS name_canonicalized,
       source='DIGITAL' AS src_ok
FROM anonymous_nominations ORDER BY submitted_date DESC LIMIT 1;   -- both true

-- Reused token now rejected (guard-against-bad-input).
SELECT success FROM private.submit_nomination(repeat('a',64),'[{"nominee_name":"X"}]'::jsonb); -- expect false

-- Wrong phase rejected.
UPDATE election_settings SET current_phase='VOTING' WHERE id=1;
-- (mint a fresh token) then submit -> expect false "phase is not open"

-- Cleanup
TRUNCATE anonymous_nominations; DELETE FROM tokens WHERE token_hash=repeat('a',64);
UPDATE election_settings SET current_phase='VOTING' WHERE id=1;  -- restore baseline
```
Expected: happy path inserts 1, `name_canonicalized` + `src_ok` both true, reuse rejected, wrong-phase rejected. **This validates Spec §12 Requirements: Nominator Anonymity, Phase Gate, Single-Use, Matched Canonicalization.**

- [ ] **Step 4: Commit.** `git add supabase/migration_nomination_submission.sql && git commit -m "feat(db): submit_nomination RPC (anonymous, in-tx, canonicalized)"`

---

## Task 3: DB RPCs — non-consuming search + admin out-of-band add

**Files:** Append to `supabase/migration_nomination_submission.sql`.

- [ ] **Step 1: Write `search_members_for_nomination` (non-consuming).**

```sql
CREATE OR REPLACE FUNCTION private.search_members_for_nomination(
  p_token_hash VARCHAR(64), p_query TEXT
)
RETURNS TABLE (member_id UUID, full_name TEXT)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE v_phase election_phase; v_token_id UUID; v_is_used BOOLEAN;
        v_expires_at TIMESTAMPTZ; v_voided_at TIMESTAMPTZ;
BEGIN
  IF p_query IS NULL OR length(trim(p_query)) < 2 THEN RETURN; END IF;
  SELECT current_phase INTO v_phase FROM election_settings WHERE id=1;
  IF v_phase <> 'NOMINATION' THEN RETURN; END IF;

  SELECT id, is_used, expires_at, voided_at
    INTO v_token_id, v_is_used, v_expires_at, v_voided_at
    FROM tokens WHERE token_hash = p_token_hash AND type='NOMINATION';   -- NO row lock, NO update
  IF v_token_id IS NULL OR v_is_used OR v_voided_at IS NOT NULL
     OR v_expires_at IS NULL OR v_expires_at <= NOW() THEN RETURN; END IF;

  RETURN QUERY
    SELECT m.id, m.full_name FROM members m
    WHERE m.is_active = TRUE AND m.full_name % p_query          -- pg_trgm similarity operator
    ORDER BY similarity(m.full_name, p_query) DESC
    LIMIT 5;                                                    -- minimal fields only
END; $$;

REVOKE EXECUTE ON FUNCTION private.search_members_for_nomination(VARCHAR, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.search_members_for_nomination(VARCHAR, TEXT) TO service_role;
```

- [ ] **Step 2: Write `admin_add_nomination` (out-of-band, source=ADMIN).**

```sql
CREATE OR REPLACE FUNCTION private.admin_add_nomination(
  p_nominee_member_id UUID, p_nominee_name TEXT, p_reason TEXT
)
RETURNS TABLE (success BOOLEAN, message TEXT)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, private, extensions
AS $$
DECLARE v_phase election_phase; v_allow BOOLEAN; v_name TEXT;
BEGIN
  SELECT current_phase, allow_write_ins INTO v_phase, v_allow FROM election_settings WHERE id=1;
  IF v_phase <> 'NOMINATION' THEN
    RETURN QUERY SELECT FALSE, 'Nomination phase is not open.'::TEXT; RETURN; END IF;
  IF p_reason IS NOT NULL AND length(p_reason) > 2000 THEN
    RETURN QUERY SELECT FALSE, 'Reason exceeds 2000 characters.'::TEXT; RETURN; END IF;

  IF p_nominee_member_id IS NOT NULL THEN
    SELECT full_name INTO v_name FROM members WHERE id=p_nominee_member_id AND is_active=TRUE;
    IF v_name IS NULL THEN
      RETURN QUERY SELECT FALSE, 'Nominee not found or inactive.'::TEXT; RETURN; END IF;
  ELSE
    IF NOT v_allow THEN
      RETURN QUERY SELECT FALSE, 'Write-in nominees are not allowed.'::TEXT; RETURN; END IF;
    v_name := trim(coalesce(p_nominee_name,''));
    IF v_name = '' THEN
      RETURN QUERY SELECT FALSE, 'Nominee name is required.'::TEXT; RETURN; END IF;
    IF length(v_name) > 100 THEN
      RETURN QUERY SELECT FALSE, 'Nominee name exceeds 100 characters.'::TEXT; RETURN; END IF;
  END IF;

  INSERT INTO anonymous_nominations (nominee_member_id, nominee_name, reason, source)
  VALUES (p_nominee_member_id, v_name, p_reason, 'ADMIN');
  RETURN QUERY SELECT TRUE, 'Nomination added.'::TEXT;
END; $$;

REVOKE EXECUTE ON FUNCTION private.admin_add_nomination(UUID, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION private.admin_add_nomination(UUID, TEXT, TEXT) TO service_role;
```

- [ ] **Step 3: Apply** both blocks via `supabase_apply_migration` name=`nomination_search_and_admin_rpcs`.

- [ ] **Step 4: Verify.** Via `supabase_execute_sql`:

```sql
-- search returns only when phase=NOMINATION + valid token; minimal fields.
UPDATE election_settings SET current_phase='NOMINATION' WHERE id=1;
INSERT INTO tokens (member_id, token_hash, type, is_used, expires_at)
SELECT id, repeat('b',64), 'NOMINATION', false, now()+interval '1 day' FROM members WHERE is_active LIMIT 1;
SELECT count(*) <= 5 AS max5 FROM private.search_members_for_nomination(repeat('b',64), 'a');  -- <=5, no error
-- invalid/short query -> empty
SELECT count(*) = 0 AS empty_short FROM private.search_members_for_nomination(repeat('b',64), 'a'); -- 'a' <2 chars => empty
-- admin add ADMIN source
SELECT success FROM private.admin_add_nomination((SELECT id FROM members WHERE is_active LIMIT 1), NULL, 'x'); -- true
SELECT source FROM anonymous_nominations ORDER BY submitted_date DESC LIMIT 1; -- 'ADMIN'
TRUNCATE anonymous_nominations; DELETE FROM tokens WHERE token_hash=repeat('b',64);
UPDATE election_settings SET current_phase='VOTING' WHERE id=1;
```
Expected as annotated. **Validates §12: Token-Gated Roster Search, Admin Out-of-Band Nomination, RPC Execution Lockdown.**

- [ ] **Step 5: Commit.** `git commit -am "feat(db): non-consuming member search + admin_add_nomination RPCs"`

---

## Task 4: Route — `POST /api/nominate`

**Files:** Create `app/api/nominate/route.ts`. Mirrors `app/api/vote/route.ts:1-79`.

- [ ] **Step 1: Write the route.**

```ts
import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import crypto from 'crypto';
import { rateLimitError, validationError } from '@/lib/api-errors';

const WINDOW = 60; const MAX = 5;

export async function POST(req: Request) {
  const ip = req.headers.get('x-forwarded-for')?.split(',')[0] || 'unknown';
  try {
    const { data: rl, error: rlError } = await supabaseServer.rpc('check_rate_limit', {
      p_identifier: `nominate:${ip}`, p_window_seconds: WINDOW, p_max_requests: MAX,
    });
    if (rlError) console.error('[nominate] rate limit RPC error:', rlError);
    else if (!rl?.allowed) return rateLimitError(WINDOW);
  } catch (err) { console.error('[nominate] rate limit failed:', err); }

  try {
    const { rawToken, nominees } = await req.json();
    if (!rawToken || !Array.isArray(nominees) || nominees.length === 0)
      return validationError('Missing input');

    const tokenHash = crypto.createHash('sha256').update(rawToken).digest('hex'); // never log rawToken

    let { data, error } = await supabaseServer.rpc('submit_nomination', {
      p_token_hash: tokenHash, p_nominees: nominees,
    });
    if (error) {
      try {
        const res = await supabaseServer.schema('private').rpc('submit_nomination', {
          p_token_hash: tokenHash, p_nominees: nominees,
        });
        if (!res.error && res.data) { data = res.data; error = null; }
      } catch { /* keep original error */ }
    }
    if (error || !data || !data[0]?.success)
      return NextResponse.json({ error: data?.[0]?.message || 'Nomination failed.' }, { status: 400 });

    return NextResponse.json({ success: true, insertedCount: data[0].inserted_count });
  } catch {
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}
```

- [ ] **Step 2: Type-check.** Run: `npm run build` (Turbopack type-checks). Expected: compiles; no TS errors in `app/api/nominate/route.ts`.
- [ ] **Step 3: Commit.** `git add app/api/nominate/route.ts && git commit -m "feat(api): POST /api/nominate"`

---

## Task 5: Route — `POST /api/nominate/search` (dual rate-limited, non-consuming)

**Files:** Create `app/api/nominate/search/route.ts`.

- [ ] **Step 1: Write the route.**

```ts
import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import crypto from 'crypto';
import { rateLimitError, validationError } from '@/lib/api-errors';

const IP_WINDOW = 60, IP_MAX = 30;      // per-IP
const TOK_WINDOW = 60, TOK_MAX = 12;    // per token_hash

export async function POST(req: Request) {
  const ip = req.headers.get('x-forwarded-for')?.split(',')[0] || 'unknown';
  try {
    const { rawToken, query } = await req.json();
    if (!rawToken || typeof query !== 'string') return validationError('Missing input');
    if (query.trim().length < 2) return NextResponse.json({ results: [] });

    const tokenHash = crypto.createHash('sha256').update(rawToken).digest('hex');

    const { data: ipRl } = await supabaseServer.rpc('check_rate_limit', {
      p_identifier: `nominate_search_ip:${ip}`, p_window_seconds: IP_WINDOW, p_max_requests: IP_MAX,
    });
    if (ipRl && !ipRl.allowed) return rateLimitError(IP_WINDOW);

    const { data: tokRl } = await supabaseServer.rpc('check_rate_limit', {
      p_identifier: `nominate_search_tok:${tokenHash}`, p_window_seconds: TOK_WINDOW, p_max_requests: TOK_MAX,
    });
    if (tokRl && !tokRl.allowed) return rateLimitError(TOK_WINDOW);

    let { data, error } = await supabaseServer.rpc('search_members_for_nomination', {
      p_token_hash: tokenHash, p_query: query,
    });
    if (error) {
      try {
        const res = await supabaseServer.schema('private').rpc('search_members_for_nomination', {
          p_token_hash: tokenHash, p_query: query,
        });
        if (!res.error) { data = res.data; error = null; }
      } catch { /* keep */ }
    }
    if (error) return NextResponse.json({ results: [] });
    return NextResponse.json({
      results: (data || []).map((r: { member_id: string; full_name: string }) =>
        ({ memberId: r.member_id, fullName: r.full_name })),
    });
  } catch {
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}
```

- [ ] **Step 2: Type-check.** Run: `npm run build`. Expected: compiles.
- [ ] **Step 3: Commit.** `git add app/api/nominate/search/route.ts && git commit -m "feat(api): POST /api/nominate/search (IP+token rate-limited, non-consuming)"`

---

## Task 6: Dispatch link branch + settings extension + token-page headers

**Files:**
- Modify: `app/api/admin/tokens-dispatch/route.ts:111`
- Modify: `app/api/admin/settings/route.ts` (GET select + PATCH body)
- Modify: `next.config.ts` (`headers()`)

- [ ] **Step 1: Branch the magic link on token type.** Replace line 111 (`const magicLink = ...`) with:

```ts
      const linkPath = tokenType === 'NOMINATION' ? 'nominate' : 'vote';
      const magicLink = `${process.env.APP_BASE_URL || 'http://localhost:3000'}/${linkPath}/${rawToken}`;
```

- [ ] **Step 2: Extend settings GET.** In `app/api/admin/settings/route.ts` GET, change the select + response:

```ts
    const { data, error } = await supabaseServer
      .from('election_settings')
      .select('voting_token_ttl_hours, allow_write_ins, max_nominees_per_member')
      .eq('id', 1).single();
    // ...
    return NextResponse.json({
      votingTokenTtlHours: data.voting_token_ttl_hours,
      allowWriteIns: data.allow_write_ins,
      maxNomineesPerMember: data.max_nominees_per_member,
    });
```

- [ ] **Step 3: Extend settings PATCH.** Accept optional `allowWriteIns` (boolean) and `maxNomineesPerMember` (int 1–3); validate and include in the `.update({...})`. Add before the update:

```ts
    const patch: Record<string, unknown> = {};
    if (votingTokenTtlHours !== undefined) {
      if (!Number.isInteger(votingTokenTtlHours) ||
          votingTokenTtlHours < MIN_VOTING_TOKEN_TTL_HOURS ||
          votingTokenTtlHours > MAX_VOTING_TOKEN_TTL_HOURS)
        return NextResponse.json({ error: `votingTokenTtlHours must be an integer between ${MIN_VOTING_TOKEN_TTL_HOURS} and ${MAX_VOTING_TOKEN_TTL_HOURS}` }, { status: 400 });
      patch.voting_token_ttl_hours = votingTokenTtlHours;
    }
    if (allowWriteIns !== undefined) {
      if (typeof allowWriteIns !== 'boolean')
        return NextResponse.json({ error: 'allowWriteIns must be a boolean' }, { status: 400 });
      patch.allow_write_ins = allowWriteIns;
    }
    if (maxNomineesPerMember !== undefined) {
      if (!Number.isInteger(maxNomineesPerMember) || maxNomineesPerMember < 1 || maxNomineesPerMember > 3)
        return NextResponse.json({ error: 'maxNomineesPerMember must be an integer between 1 and 3' }, { status: 400 });
      patch.max_nominees_per_member = maxNomineesPerMember;
    }
    if (Object.keys(patch).length === 0)
      return NextResponse.json({ error: 'No valid settings provided' }, { status: 400 });
```
Then `.update(patch)` (instead of the single-field update) and `.select('voting_token_ttl_hours, allow_write_ins, max_nominees_per_member')`; destructure `{ votingTokenTtlHours, allowWriteIns, maxNomineesPerMember }` from `req.json()`.

- [ ] **Step 4: Add token-page headers.** In `next.config.ts` `headers()`, add entries so `/vote/:token` and `/nominate/:token` set `Referrer-Policy: no-referrer` and `Cache-Control: no-store`:

```ts
      {
        source: '/:kind(vote|nominate)/:token',
        headers: [
          { key: 'Referrer-Policy', value: 'no-referrer' },
          { key: 'Cache-Control', value: 'no-store' },
        ],
      },
```

- [ ] **Step 5: Verify.** Run: `npm run build`. Expected: compiles. Manually confirm header block placement matches existing `headers()` array shape (`next.config.ts:29-31`).
- [ ] **Step 6: Commit.** `git commit -am "feat: nominate dispatch link + settings toggles + no-referrer/no-store on token pages"`

---

## Task 7: `/nominate/[token]` page — typeahead nomination UI  → **@designer**

**Files:** Create `app/nominate/[token]/page.tsx` (parallel to `app/vote/[token]/page.tsx:1-99`).

**Contract (must hold; visual/interaction refinement is @designer's):**
- Client component; reads `token` from route params.
- Debounced (not per-keystroke) roster search → `POST /api/nominate/search` `{ rawToken, query }`; renders up to 5 `{ memberId, fullName }` as pickable options.
- Picking a member = a **matched** nominee (`nominee_member_id` set). If write-ins are allowed, free-text entry that isn't picked = a **write-in** (`nominee_member_id: null`, `nominee_name` = typed text).
- Allow adding up to `maxNomineesPerMember` nominees (fetch the cap; hide "add another" at the cap). Each nominee has an optional `reason` (≤2000 chars, enforced client + server).
- Submit → `POST /api/nominate` `{ rawToken, nominees: [{ nominee_member_id, nominee_name, reason }] }`. Show success (with count) / error message from the response.

- [ ] **Step 1: Write the page skeleton (@designer to refine visuals within this contract).**

```tsx
'use client';
import { useState, useCallback, use } from 'react';

type Match = { memberId: string; fullName: string };
type Nominee = { nominee_member_id: string | null; nominee_name: string; reason: string };

export default function NominatePage({ params }: { params: Promise<{ token: string }> }) {
  const { token } = use(params);
  const [query, setQuery] = useState('');
  const [matches, setMatches] = useState<Match[]>([]);
  const [nominees, setNominees] = useState<Nominee[]>([]);
  const [status, setStatus] = useState<string | null>(null);

  const search = useCallback(async (q: string) => {
    if (q.trim().length < 2) { setMatches([]); return; }
    const res = await fetch('/api/nominate/search', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ rawToken: token, query: q }),
    });
    const json = await res.json();
    setMatches(json.results ?? []);
  }, [token]);

  // NOTE: wrap `search` in a debounce (e.g. 300ms) — @designer.
  const addMatched = (m: Match) =>
    setNominees((n) => [...n, { nominee_member_id: m.memberId, nominee_name: m.fullName, reason: '' }]);
  const addWriteIn = (name: string) =>
    setNominees((n) => [...n, { nominee_member_id: null, nominee_name: name, reason: '' }]);

  const submit = async () => {
    const res = await fetch('/api/nominate', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ rawToken: token, nominees }),
    });
    const json = await res.json();
    setStatus(res.ok ? `Submitted ${json.insertedCount} nomination(s).` : (json.error ?? 'Failed.'));
  };

  return (
    <main>
      {/* @designer: layout, typeahead dropdown, nominee chips, reason fields, cap handling, submit + status */}
    </main>
  );
}
```

- [ ] **Step 2: Structural smoke (Playwright — see `ui-verification` skill).** Assert the page renders, typing ≥2 chars issues a search request, a result can be selected, and submit posts to `/api/nominate`. (Playwright MCP must be enabled — flag to orchestrator.)
- [ ] **Step 3: Type-check + commit.** `npm run build` then `git add app/nominate && git commit -m "feat(ui): /nominate/[token] typeahead nomination page"`

---

## Task 8: Admin settings toggles UI  → **@fixer** (mechanical) / **@designer** if restyled

**Files:** Modify `app/admin/dashboard/page.tsx` settings section (co-locate with the existing `voting_token_ttl_hours` control).

- [ ] **Step 1:** Add a checkbox bound to `allowWriteIns` and a 1–3 selector bound to `maxNomineesPerMember`; persist via the existing settings `PATCH` (Task 6). Match the existing settings-form pattern already in the dashboard.
- [ ] **Step 2:** `npm run build`; manual check the controls save and reload.
- [ ] **Step 3:** `git commit -am "feat(ui): admin toggles for write-ins + max nominees"`

---

## Task 9: Admin out-of-band "Add nomination" UI + route  → **@designer**

**Files:**
- Create: `app/api/admin/nominations/add/route.ts`
- Modify: `app/admin/dashboard/page.tsx` (nomination admin section)

- [ ] **Step 1: Route (CSRF-guarded, calls `admin_add_nomination`).**

```ts
import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { requireAdminWithCsrf, getAdminSession } from '../../auth';
import { insertAuditLog } from '@/lib/audit-log';

export async function POST(req: Request) {
  const authFail = await requireAdminWithCsrf(req);
  if (authFail) return authFail;
  const admin = await getAdminSession();
  try {
    const { nomineeMemberId, nomineeName, reason } = await req.json();
    let { data, error } = await supabaseServer.rpc('admin_add_nomination', {
      p_nominee_member_id: nomineeMemberId ?? null,
      p_nominee_name: nomineeName ?? null,
      p_reason: reason ?? null,
    });
    if (error) {
      try {
        const res = await supabaseServer.schema('private').rpc('admin_add_nomination', {
          p_nominee_member_id: nomineeMemberId ?? null, p_nominee_name: nomineeName ?? null, p_reason: reason ?? null,
        });
        if (!res.error && res.data) { data = res.data; error = null; }
      } catch { /* keep */ }
    }
    if (error || !data || !data[0]?.success)
      return NextResponse.json({ error: data?.[0]?.message || 'Add failed.' }, { status: 400 });
    await insertAuditLog({ action: 'ADMIN_ACTION', adminId: admin?.id || null,
      details: { op: 'add_nomination', nomineeMemberId: nomineeMemberId ?? null, admin_ip: admin?.ip_address } });
    return NextResponse.json({ success: true });
  } catch {
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}
```

- [ ] **Step 2: UI (@designer).** "Add nomination" form, visible only when `current_phase === 'NOMINATION'`. Reuse the same matched (member picker over the roster — admin can use the existing member search) / write-in entry pattern. POST to the route above.
- [ ] **Step 3:** `npm run build`; commit `git add app/api/admin/nominations app/admin && git commit -m "feat: admin out-of-band add-nomination (route + UI)"`

---

## Task 10: Admin adjudication UI + promote route  → **@designer** (largest UI)

**Files:**
- Create: `app/api/admin/nominations/route.ts` (GET grouped/unmatched read)
- Create: `app/api/admin/nominations/adjudicate/route.ts` (POST decision)
- Modify: `app/admin/dashboard/page.tsx` (adjudication section, shown at `NOMINATION_CLOSED`)

**Contract:**
- **GET** returns two datasets from live queries over immutable rows:
  - matched: `SELECT nominee_member_id, (SELECT full_name FROM members) , count(*) FROM anonymous_nominations WHERE nominee_member_id IS NOT NULL GROUP BY 1` + whether already promoted (join `nomination_adjudications` PROMOTE).
  - unmatched: `SELECT id, nominee_name, reason FROM anonymous_nominations WHERE nominee_member_id IS NULL`, each with top-3 roster suggestions via `similarity(full_name, nominee_name)`.
- **POST adjudicate** `{ decision, nomineeMemberId?, nomineeName?, affectedNominationIds[], candidateStatement? }`:
  - `PROMOTE`: insert a `candidates` row (from `members.full_name` for matched, or `nomineeName` for write-in) **then** insert a `nomination_adjudications` PROMOTE row — the unique index makes re-promoting the same matched nominee fail cleanly (surface as "already promoted").
  - `MERGE`: link to an existing `candidate_id`; record adjudication (no new candidate).
  - `DISCARD`: record adjudication only.
  - **Never mutate `anonymous_nominations`.**

- [ ] **Step 1:** GET read route (service-role queries; admin-gated via `requireAdmin`).
- [ ] **Step 2:** adjudicate route (CSRF-guarded; idempotent PROMOTE relying on `idx_adjudication_one_promote_per_nominee`; audit-log each decision).
- [ ] **Step 3 (@designer):** Two-section adjudication panel — matched groups with counts + "Promote" tick; unmatched write-ins each with top-3 suggestions and Add-as-candidate / Merge / Discard actions. Shown only at `NOMINATION_CLOSED`.
- [ ] **Step 4:** `npm run build`; verify idempotent promote returns a clean "already promoted" (guard test: attempt double-promote via the UI/route, expect rejection).
- [ ] **Step 5:** `git add app/api/admin/nominations app/admin && git commit -m "feat: nomination adjudication (grouped/unmatched read + idempotent promote/merge/discard)"`

---

## Task 11: Verification pass  → **@verifier** (standard tier), then **@oracle** spot-review of the migration

- [ ] **Step 1:** `@verifier` standard tier — `npm run build` + `npm run lint`. Pre-existing lint error at `app/admin/dashboard/page.tsx:95` (`setMounted`) is out of scope; do not fix unless touched.
- [ ] **Step 2:** Re-run the DB assertion suites from Tasks 2–3 against the seed DB; confirm all Spec §12 scenarios pass, then restore `current_phase='VOTING'` and `TRUNCATE anonymous_nominations`.
- [ ] **Step 3:** `@oracle` spot-review of `migration_nomination_submission.sql` — confirm no nominator identity path, grants correct, immutability + RLS enforced.
- [ ] **Step 4:** Present summary → user confirmation → merge to `main` per AGENTS.md Git Workflow. (Migrations are applied on the live DB during the second wipe / Option B.)

---

## Self-Review (spec coverage map)

| Spec §12 Requirement | Task |
|---|---|
| Nominator Anonymity | 2 (RPC + assertion) |
| Nomination Phase Gate | 2 |
| Token Single-Use Consumption | 2 |
| Matched Nominee Canonicalization | 2 |
| Write-in Control | 2 |
| Per-Submission Nominee Limit | 2 |
| Nomination Row Immutability | 1 |
| Nomination Table Access Control (RLS) | 1 |
| RPC Execution Lockdown | 2, 3, 9 |
| Token-Gated Roster Search | 3, 5 |
| Token URL Leakage Prevention | 6 |
| Admin Out-of-Band Nomination | 3, 9 |
| Idempotent Candidate Promotion | 1, 10 |

No gaps. Type names consistent across tasks (`nominees[]` shape `{nominee_member_id, nominee_name, reason}`; RPC names `submit_nomination` / `search_members_for_nomination` / `admin_add_nomination`).
