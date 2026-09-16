# Wave 5 — GDPR Privacy Subsystem Implementation Plan

> **For implementers:** Use the `executing-plans` skill (inline) or have the orchestrator dispatch one `@fixer` per task with review between tasks. Steps use checkbox (`- [ ]`) syntax. **This project has no unit-test suite** — verification is: DB-function UAT via a rolled-back `DO $$ … RAISE EXCEPTION` harness applied through the **Supabase MCP** (orchestrator-owned), `@verifier` for build/lint, and Playwright for UI UAT. Migrations are applied via the Supabase MCP (`apply_migration`); the `.sql` files remain source-of-truth + run order.

**Goal:** Add configurable voter eligibility (both channels), a two-stage roster-PII purge, a forbid-by-design raw-export posture, a wipe-surviving governance ledger, and an extended wipe definition — implementing the 5 locked Wave 5 decisions.

**Architecture:** Three new migrations (30 governance ledger → 31 eligibility schema → 32 enforcement, the final writer for the paper/vote RPCs) plus route/import/dispatch changes. Enforcement is defense-in-depth: route pre-checks for good errors + DB triggers/RPC checks that survive service-role scripts. No new PII is persisted (DOB is parsed in-memory only).

**Tech Stack:** Next.js 16 (App Router), Supabase Postgres (SECURITY DEFINER RPCs in `private` schema, RLS), TypeScript, Tailwind v4.

**Branch:** `agent/wave5-privacy-design` (continues the branch holding the approved design doc; per AGENTS.md — never main/master).

**Design source:** `docs/specs/2026-09-15-wave5-privacy-design.md` (approved 2026-09-15).

**Locked open items (from design §11, confirmed by approval):** dispute window = **30 days**; NOMINATION-token dispatch is **not** gated by `voting_eligible` (VOTING only).

---

## File Structure

**Create:**
- `supabase/migration_wave5_governance_ledger.sql` — `governance` schema + `processing_activity_ledger` + hash-chain + append-only/anti-TRUNCATE triggers + grants.
- `supabase/migration_wave5_eligibility_schema.sql` — `election_settings`/`members` columns, `eligibility_adjudications`, constraints, indexes, append-only guard.
- `supabase/migration_wave5_eligibility_enforcement.sql` — final-writer RPC recreations with eligibility checks, VOTING-token insert trigger, `purge_roster_pii` RPC + wrapper.
- `tests/wave5-eligibility.spec.ts` — Playwright route-mock structural UAT (admin eligibility surface).

**Modify:**
- `supabase/seed.sql:16-19` — add `eligibility_adjudications` to TRUNCATE list.
- `app/api/admin/members-import/route.ts` — parse transient DOB, compute eligibility, persist booleans only.
- `app/api/admin/tokens-dispatch/route.ts` — gate VOTING dispatch on `voting_eligible`; structured failures.
- `AGENTS.md` — remove `dispatch-tokens.js` Commands row; note eligibility/purge.
- `docs/TECHNICAL_GUIDE.md` — canonical run order (add 30–32); extended-wipe runbook; privacy notice.
- `docs/CHANGELOG.md` + `package.json` — version bump.

**Delete:**
- `scripts/dispatch-tokens.js` (retired — superseded by admin route + DB trigger).

**Designer-owned (separate lane, §Task 10):**
- `app/admin/dashboard/page.tsx` — "Voter Eligibility" adjudication tab + "Purge roster PII" control (data contract defined here; visuals by `@designer`).

---

## Task 1: Governance ledger migration (item 30)

**Files:** Create `supabase/migration_wave5_governance_ledger.sql`; Reference pattern: `supabase/migration_audit_log_hash_chain.sql` (read it for the SHA-256 `previous_hash`/`record_hash` chaining style).

- [ ] **Step 1: Write the migration**

```sql
-- Wave 5 migration 30: wipe-surviving governance / RoPA ledger (Option A: in-DB, never-truncated).
-- Records PROCESS/ACCOUNTABILITY SUMMARIES ONLY — never voter linkage. Excluded from seed.sql.
CREATE SCHEMA IF NOT EXISTS governance;

CREATE TABLE IF NOT EXISTS governance.processing_activity_ledger (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_type TEXT NOT NULL CHECK (event_type IN (
    'ROPA_DECLARED','ELIGIBILITY_POLICY_CONFIGURED','ROSTER_IMPORTED_SUMMARY',
    'ELIGIBILITY_ADJUDICATION_SUMMARY','TOKENS_DISPATCHED_SUMMARY','CONTACT_PII_PURGED',
    'IDENTITY_PII_ANONYMIZED','AGGREGATE_RESULTS_EXPORTED','WIPE_STARTED','WIPE_COMPLETED',
    'RAW_RETENTION_OUT_OF_BAND_DECLARED')),
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  actor_admin_id UUID,            -- NO FK: admin_sessions is wiped; store id-as-value + label only
  actor_label TEXT,
  controller_name TEXT,
  organization_ref TEXT,
  processing_purpose TEXT,
  lawful_basis TEXT,
  data_categories TEXT[],
  data_subject_categories TEXT[],
  retention_policy TEXT,
  event_summary JSONB NOT NULL DEFAULT '{}'::jsonb,
  previous_hash CHAR(64),
  record_hash CHAR(64) NOT NULL,
  CONSTRAINT governance_no_voter_linkage CHECK (
    event_summary::text !~* '(member_id|memberId|ballot_id|ballotId|token|email|phone|full_name|member_code)'
  )
);

-- Append-only + anti-TRUNCATE. TRUNCATE bypasses row triggers, so add a STATEMENT-level
-- TRUNCATE trigger that hard-rejects truncation (this is the defect-#1 guarantee).
CREATE OR REPLACE FUNCTION governance.reject_mutation() RETURNS trigger
  LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'governance.processing_activity_ledger is append-only (no UPDATE/DELETE)';
END;
$$;

CREATE OR REPLACE FUNCTION governance.reject_truncate() RETURNS trigger
  LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'governance.processing_activity_ledger must never be truncated';
END;
$$;

DROP TRIGGER IF EXISTS trg_governance_no_update ON governance.processing_activity_ledger;
CREATE TRIGGER trg_governance_no_update BEFORE UPDATE OR DELETE
  ON governance.processing_activity_ledger
  FOR EACH ROW EXECUTE FUNCTION governance.reject_mutation();

DROP TRIGGER IF EXISTS trg_governance_no_truncate ON governance.processing_activity_ledger;
CREATE TRIGGER trg_governance_no_truncate BEFORE TRUNCATE
  ON governance.processing_activity_ledger
  FOR EACH STATEMENT EXECUTE FUNCTION governance.reject_truncate();

-- Hash-chain append RPC (SECURITY DEFINER, service_role only). record_hash chains previous_hash.
CREATE OR REPLACE FUNCTION private.append_governance_event(
  p_event_type TEXT, p_actor_admin_id UUID, p_actor_label TEXT,
  p_controller_name TEXT, p_organization_ref TEXT, p_processing_purpose TEXT,
  p_lawful_basis TEXT, p_data_categories TEXT[], p_data_subject_categories TEXT[],
  p_retention_policy TEXT, p_event_summary JSONB
) RETURNS UUID
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, private, governance, extensions AS $$
DECLARE
  v_prev CHAR(64);
  v_hash CHAR(64);
  v_id UUID;
BEGIN
  SELECT record_hash INTO v_prev FROM governance.processing_activity_ledger
    ORDER BY occurred_at DESC, id DESC LIMIT 1;
  v_hash := encode(digest(
    coalesce(v_prev,'') || p_event_type || now()::text || coalesce(p_event_summary::text,''),
    'sha256'), 'hex');
  INSERT INTO governance.processing_activity_ledger(
    event_type, actor_admin_id, actor_label, controller_name, organization_ref,
    processing_purpose, lawful_basis, data_categories, data_subject_categories,
    retention_policy, event_summary, previous_hash, record_hash)
  VALUES (p_event_type, p_actor_admin_id, p_actor_label, p_controller_name, p_organization_ref,
    p_processing_purpose, p_lawful_basis, p_data_categories, p_data_subject_categories,
    p_retention_policy, coalesce(p_event_summary,'{}'::jsonb), v_prev, v_hash)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.append_governance_event(
  p_event_type TEXT, p_actor_admin_id UUID, p_actor_label TEXT,
  p_controller_name TEXT, p_organization_ref TEXT, p_processing_purpose TEXT,
  p_lawful_basis TEXT, p_data_categories TEXT[], p_data_subject_categories TEXT[],
  p_retention_policy TEXT, p_event_summary JSONB
) RETURNS UUID
  LANGUAGE sql SECURITY DEFINER SET search_path = public, private AS $$
  SELECT private.append_governance_event($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11);
$$;

REVOKE ALL ON FUNCTION public.append_governance_event(
  TEXT,UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT[],TEXT[],TEXT,JSONB) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.append_governance_event(
  TEXT,UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT[],TEXT[],TEXT,JSONB) TO service_role;
GRANT USAGE ON SCHEMA governance TO service_role;
GRANT SELECT, INSERT ON governance.processing_activity_ledger TO service_role;
```

- [ ] **Step 2: Apply via Supabase MCP** — `apply_migration` name `wave5_governance_ledger`, body = the file. Expected: success, no error.

- [ ] **Step 3: DB-function UAT — anti-TRUNCATE + append-only guard actually fire** (orchestrator runs via MCP `execute_sql`, self-rolling-back). This is a **guard-against-known-bad** test per AGENTS.md — it MUST fail on the forbidden op.

```sql
DO $$
DECLARE v_id UUID;
BEGIN
  v_id := public.append_governance_event('ROPA_DECLARED', NULL, 'uat', NULL, NULL, NULL,
    'test', ARRAY['none'], ARRAY['none'], 'test', '{"note":"uat"}'::jsonb);
  -- UPDATE must be rejected
  BEGIN
    UPDATE governance.processing_activity_ledger SET actor_label='x' WHERE id=v_id;
    RAISE EXCEPTION 'UAT_FAIL: update was allowed';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'UAT_FAIL%' THEN RAISE; END IF;
  END;
  -- TRUNCATE must be rejected
  BEGIN
    TRUNCATE governance.processing_activity_ledger;
    RAISE EXCEPTION 'UAT_FAIL: truncate was allowed';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'UAT_FAIL%' THEN RAISE; END IF;
  END;
  -- voter-linkage CHECK must reject a member_id key in event_summary
  BEGIN
    PERFORM public.append_governance_event('ROPA_DECLARED', NULL, 'uat', NULL, NULL, NULL,
      'test', ARRAY['none'], ARRAY['none'], 'test', '{"member_id":"x"}'::jsonb);
    RAISE EXCEPTION 'UAT_FAIL: linkage check did not reject member_id';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'UAT_FAIL%' THEN RAISE; END IF;
  END;
  RAISE EXCEPTION 'GOVERNANCE_LEDGER_OK';  -- sentinel: rolls back the whole DO block
END $$;
```

Expected: error `GOVERNANCE_LEDGER_OK` (all three guards fired; nothing persisted).

- [ ] **Step 4: Commit**

```bash
git add supabase/migration_wave5_governance_ledger.sql
git commit -m "feat(wave5): wipe-surviving governance ledger (migration 30)"
```

---

## Task 2: Eligibility schema migration (item 31)

**Files:** Create `supabase/migration_wave5_eligibility_schema.sql`. Reference: `supabase/migration_fix_admin_id_fk.sql:49-60` (admin FK pattern for `eligibility_adjudications.admin_id`).

- [ ] **Step 1: Write the migration** (exact DDL — from design §4.1–4.3)

```sql
-- Wave 5 migration 31: configurable voter eligibility (general voting_eligible + reason codes).
ALTER TABLE election_settings
  ADD COLUMN IF NOT EXISTS age_requirement_enabled BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS minimum_voting_age SMALLINT,
  ADD COLUMN IF NOT EXISTS undetermined_eligibility_defaults_ineligible BOOLEAN NOT NULL DEFAULT TRUE;

ALTER TABLE election_settings
  ADD CONSTRAINT election_settings_minimum_voting_age_check
    CHECK (minimum_voting_age IS NULL OR minimum_voting_age BETWEEN 0 AND 130),
  ADD CONSTRAINT election_settings_age_requirement_config_check
    CHECK (age_requirement_enabled = FALSE OR minimum_voting_age IS NOT NULL);

ALTER TABLE members
  ADD COLUMN IF NOT EXISTS voting_eligible    BOOLEAN NOT NULL DEFAULT TRUE,
  ADD COLUMN IF NOT EXISTS eligibility_reason TEXT    NOT NULL DEFAULT 'ELIGIBLE',
  ADD COLUMN IF NOT EXISTS eligibility_source TEXT    NOT NULL DEFAULT 'SYSTEM_DEFAULT',
  ADD COLUMN IF NOT EXISTS is_age_eligible    BOOLEAN,
  ADD COLUMN IF NOT EXISTS has_voted          BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE members
  ADD CONSTRAINT members_eligibility_reason_check CHECK (eligibility_reason IN (
    'ELIGIBLE','AGE_UNDER_MIN','NOT_A_MEMBER','MANUAL_ADMIN_HOLD','UNDETERMINED',
    'INACTIVE_MEMBER','PURGED')),
  ADD CONSTRAINT members_eligibility_source_check CHECK (eligibility_source IN (
    'SYSTEM_DEFAULT','CSV_IMPORT','ADMIN_ADJUDICATION','SYSTEM_RECOMPUTE','PURGE')),
  ADD CONSTRAINT members_eligibility_consistency_check CHECK (
    (voting_eligible = TRUE  AND eligibility_reason  = 'ELIGIBLE') OR
    (voting_eligible = FALSE AND eligibility_reason <> 'ELIGIBLE'));

CREATE INDEX IF NOT EXISTS idx_members_voting_eligible ON members(voting_eligible);

CREATE TABLE IF NOT EXISTS eligibility_adjudications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id UUID NOT NULL REFERENCES members(id) ON DELETE RESTRICT,
  admin_id  UUID REFERENCES admin_sessions(id) ON DELETE RESTRICT,
  old_voting_eligible BOOLEAN NOT NULL, old_eligibility_reason TEXT NOT NULL,
  old_eligibility_source TEXT NOT NULL, old_is_age_eligible BOOLEAN,
  new_voting_eligible BOOLEAN NOT NULL, new_eligibility_reason TEXT NOT NULL,
  new_eligibility_source TEXT NOT NULL, new_is_age_eligible BOOLEAN,
  note TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION private.reject_adjudication_mutation() RETURNS trigger
  LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'eligibility_adjudications is append-only'; END; $$;
DROP TRIGGER IF EXISTS trg_adjudication_no_update ON eligibility_adjudications;
CREATE TRIGGER trg_adjudication_no_update BEFORE UPDATE OR DELETE
  ON eligibility_adjudications FOR EACH ROW
  EXECUTE FUNCTION private.reject_adjudication_mutation();

ALTER TABLE eligibility_adjudications ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT ON eligibility_adjudications TO service_role;
```

- [ ] **Step 2: Apply via Supabase MCP** — `apply_migration` name `wave5_eligibility_schema`. Expected: success.

- [ ] **Step 3: DB-function UAT — consistency CHECK rejects an inconsistent row** (guard-against-known-bad; rolled back).

```sql
DO $$
BEGIN
  BEGIN
    INSERT INTO members(member_code, full_name, is_active, voting_eligible, eligibility_reason)
    VALUES ('UAT-BAD', 'uat', TRUE, FALSE, 'ELIGIBLE');  -- inconsistent: not eligible but reason ELIGIBLE
    RAISE EXCEPTION 'UAT_FAIL: consistency check did not reject';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'UAT_FAIL%' THEN RAISE; END IF;
  END;
  RAISE EXCEPTION 'ELIGIBILITY_SCHEMA_OK';
END $$;
```

Expected: error `ELIGIBILITY_SCHEMA_OK`.

- [ ] **Step 4: Commit**

```bash
git add supabase/migration_wave5_eligibility_schema.sql
git commit -m "feat(wave5): eligibility schema + adjudications table (migration 31)"
```

---

## Task 3: Update `seed.sql` wipe list

**Files:** Modify `supabase/seed.sql:16-18`.

- [ ] **Step 1: Add `eligibility_adjudications` to the TRUNCATE list** (it is member-linked, election-scoped — must wipe. Do NOT add the governance ledger.)

Replace the TRUNCATE statement:

```sql
TRUNCATE candidates, tokens, anonymous_nominations, ballots, paper_ballots,
  paper_ballot_batches, vote_audit_log, eligibility_adjudications, phase_change_tokens,
  admin_sessions, rate_limit_hits CASCADE;
DELETE FROM members;
```

- [ ] **Step 2: Commit**

```bash
git add supabase/seed.sql
git commit -m "chore(wave5): add eligibility_adjudications to seed.sql wipe list"
```

---

## Task 4: Enforcement migration (item 32 — FINAL WRITER)

**Files:** Create `supabase/migration_wave5_eligibility_enforcement.sql`. **CRITICAL:** this migration must be the **last** `CREATE OR REPLACE` for `private.submit_anonymous_vote`, `private.issue_paper_ballot`, and `private.issue_preprinted_paper_ballot`, or a later migration silently drops the checks (see `docs/TECHNICAL_GUIDE.md:236-243`).

**Copy-verbatim sources (fixer reads these in-session, preserves body exactly, inserts the eligibility block at the noted anchor, and keeps the existing `RETURNS TABLE`/OUT signature unchanged):**
- `private.submit_anonymous_vote` — copy current body from `supabase/migration_opaque_ballot_ids.sql` (approx lines 200-263). Anchor: immediately after the voting-token row is locked (`SELECT … FOR UPDATE`) and its `member_id` is known.
- `private.issue_paper_ballot` — copy from `supabase/migration_wave3_paper_token_reserve.sql` (approx lines 20-105). Anchor: immediately after the member existence/active `SELECT`, before token reservation / ballot insert.
- `private.issue_preprinted_paper_ballot` — copy from `supabase/migration_paper_assign_phase_gate.sql` (approx lines 39-97). Anchor: immediately after the member lookup, before ballot assignment / token reservation.

- [ ] **Step 1: Eligibility check block** — insert this at each RPC's member-known anchor. Adapt the `RETURN`/`RETURN QUERY` to match that function's existing OUT columns (fixer: match the copied signature exactly; the shape below is the pattern):

```sql
  -- Wave 5: voter eligibility gate (both channels). v_member_id must already be set.
  SELECT voting_eligible INTO v_voting_eligible
    FROM members WHERE id = v_member_id AND is_active = TRUE FOR SHARE;
  IF NOT FOUND OR v_voting_eligible IS NOT TRUE THEN
    -- Return the function's standard failure tuple with message 'Member is not eligible to vote.'
    -- (match existing OUT columns; e.g. RETURN QUERY SELECT FALSE, 'Member is not eligible to vote.', NULL, NULL;)
    RETURN;
  END IF;
```

Also declare `v_voting_eligible BOOLEAN;` in each function's `DECLARE` block.

- [ ] **Step 2: VOTING-token insert backstop trigger** (protects against direct service-role inserts and lets us retire the standalone dispatch script):

```sql
CREATE OR REPLACE FUNCTION private.enforce_token_eligibility() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, private AS $$
DECLARE v_ok BOOLEAN;
BEGIN
  IF NEW.type = 'VOTING' THEN
    SELECT (is_active AND voting_eligible) INTO v_ok FROM members WHERE id = NEW.member_id;
    IF v_ok IS NOT TRUE THEN
      RAISE EXCEPTION 'Cannot issue VOTING token: member % is not eligible', NEW.member_id
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_token_eligibility ON tokens;
CREATE TRIGGER trg_token_eligibility BEFORE INSERT ON tokens
  FOR EACH ROW EXECUTE FUNCTION private.enforce_token_eligibility();
```

- [ ] **Step 3: `purge_roster_pii` RPC + public wrapper** (design §5). Two stages, phase-gated, idempotent, audited.

```sql
CREATE OR REPLACE FUNCTION private.purge_roster_pii(
  p_admin_id UUID, p_stage TEXT, p_confirm TEXT
) RETURNS TABLE(success BOOLEAN, stage TEXT, members_touched INT, message TEXT)
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, private, governance, extensions AS $$
DECLARE
  v_phase TEXT;
  v_voting_end TIMESTAMPTZ;
  v_count INT := 0;
BEGIN
  IF p_confirm <> 'PURGE' THEN
    RETURN QUERY SELECT FALSE, p_stage, 0, 'Confirmation token mismatch'; RETURN;
  END IF;
  SELECT current_phase, voting_end INTO v_phase, v_voting_end FROM election_settings WHERE id = 1;

  IF p_stage = 'CONTACT' THEN
    IF v_phase NOT IN ('VOTING_CLOSED','COMPLETED') THEN
      RETURN QUERY SELECT FALSE, p_stage, 0, 'Stage CONTACT requires VOTING_CLOSED/COMPLETED'; RETURN;
    END IF;
    UPDATE members m SET
      email = NULL, phone = NULL,
      has_voted = (EXISTS (SELECT 1 FROM tokens t WHERE t.member_id = m.id AND t.type='VOTING' AND t.is_used = TRUE)
                OR EXISTS (SELECT 1 FROM paper_ballots p WHERE p.member_id = m.id AND p.status = 'VOTED'))
    WHERE email IS NOT NULL OR phone IS NOT NULL;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    PERFORM private.append_governance_event('CONTACT_PII_PURGED', p_admin_id, NULL, NULL, NULL,
      'roster PII minimization', 'storage limitation', ARRAY['contact'], ARRAY['members'], 'purged at voting close',
      jsonb_build_object('members_touched', v_count, 'phase', v_phase));
    RETURN QUERY SELECT TRUE, p_stage, v_count, 'Contact PII purged'; RETURN;

  ELSIF p_stage = 'IDENTITY' THEN
    IF v_voting_end IS NULL OR now() < v_voting_end + INTERVAL '30 days' THEN
      RETURN QUERY SELECT FALSE, p_stage, 0, 'Stage IDENTITY requires 30-day dispute window elapsed'; RETURN;
    END IF;
    UPDATE members SET
      full_name = 'Redacted member ' || substring(id::text from 1 for 8),
      member_code = 'PURGED-' || substring(id::text from 1 for 12),
      email = NULL, phone = NULL, is_age_eligible = NULL,
      voting_eligible = FALSE, eligibility_reason = 'PURGED', eligibility_source = 'PURGE'
    WHERE full_name NOT LIKE 'Redacted member %';
    GET DIAGNOSTICS v_count = ROW_COUNT;
    PERFORM private.append_governance_event('IDENTITY_PII_ANONYMIZED', p_admin_id, NULL, NULL, NULL,
      'roster identity anonymization', 'storage limitation', ARRAY['identity'], ARRAY['members'], 'anonymized after dispute window',
      jsonb_build_object('members_touched', v_count));
    RETURN QUERY SELECT TRUE, p_stage, v_count, 'Identity anonymized'; RETURN;
  END IF;
  RETURN QUERY SELECT FALSE, p_stage, 0, 'Unknown stage (use CONTACT or IDENTITY)';
END;
$$;

CREATE OR REPLACE FUNCTION public.purge_roster_pii(p_admin_id UUID, p_stage TEXT, p_confirm TEXT)
  RETURNS TABLE(success BOOLEAN, stage TEXT, members_touched INT, message TEXT)
  LANGUAGE sql SECURITY DEFINER SET search_path = public, private AS $$
  SELECT * FROM private.purge_roster_pii($1,$2,$3);
$$;
REVOKE ALL ON FUNCTION public.purge_roster_pii(UUID,TEXT,TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.purge_roster_pii(UUID,TEXT,TEXT) TO service_role;
```

- [ ] **Step 4: Apply via Supabase MCP** — `apply_migration` name `wave5_eligibility_enforcement`. Expected: success.

- [ ] **Step 5: DB-function UAT — eligibility gate + purge behavior** (orchestrator, rolled-back). Seeds an ineligible member, asserts (a) VOTING-token insert is rejected by the trigger, (b) Stage-CONTACT purge nulls contacts + sets `has_voted`, then rolls back with a sentinel.

```sql
DO $$
DECLARE v_mid UUID;
BEGIN
  INSERT INTO members(member_code, full_name, email, phone, is_active, voting_eligible, eligibility_reason, eligibility_source)
  VALUES ('UAT-INELIG','uat inelig','u@x.io','+1','TRUE'::bool, FALSE, 'AGE_UNDER_MIN','CSV_IMPORT')
  RETURNING id INTO v_mid;
  -- (a) trigger must block a VOTING token for an ineligible member
  BEGIN
    INSERT INTO tokens(member_id, token_hash, type, is_used, expires_at)
    VALUES (v_mid, repeat('a',64), 'VOTING', FALSE, now()+INTERVAL '1 day');
    RAISE EXCEPTION 'UAT_FAIL: ineligible VOTING token was allowed';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE 'UAT_FAIL%' THEN RAISE; END IF; END;
  -- (b) contact purge (needs phase; set temporarily within the rolled-back block)
  UPDATE election_settings SET current_phase='VOTING_CLOSED' WHERE id=1;
  PERFORM public.purge_roster_pii(NULL, 'CONTACT', 'PURGE');
  IF EXISTS (SELECT 1 FROM members WHERE id=v_mid AND (email IS NOT NULL OR phone IS NOT NULL)) THEN
    RAISE EXCEPTION 'UAT_FAIL: contact purge did not null email/phone';
  END IF;
  RAISE EXCEPTION 'ENFORCEMENT_OK';
END $$;
```

Expected: error `ENFORCEMENT_OK` (both assertions passed; nothing persisted — including the temporary phase change).

- [ ] **Step 6: Commit**

```bash
git add supabase/migration_wave5_eligibility_enforcement.sql
git commit -m "feat(wave5): eligibility enforcement (both channels), token trigger, purge RPC (migration 32)"
```

---

## Task 5: DOB-free eligibility at member import

**Files:** Modify `app/api/admin/members-import/route.ts`.

- [ ] **Step 1: Extend `CSVRow` + parse to accept transient DOB** — add to the interface (line 8-14) and keep DOB out of the persisted record. Add `dob`/`date_of_birth` to `CSVRow`:

```typescript
interface CSVRow {
  full_name?: string;
  name?: string;
  email?: string;
  phone?: string;
  member_code?: string;
  dob?: string;
  date_of_birth?: string;
}
```

- [ ] **Step 2: Load eligibility policy once** — after the phase check (after line 110), fetch settings:

```typescript
    const { data: elig } = await supabaseServer
      .from('election_settings')
      .select('age_requirement_enabled, minimum_voting_age, undetermined_eligibility_defaults_ineligible, voting_start')
      .eq('id', 1)
      .single();
    const ageEnabled = !!elig?.age_requirement_enabled;
    const minAge = elig?.minimum_voting_age ?? null;
    const undeterminedIneligible = elig?.undetermined_eligibility_defaults_ineligible ?? true;
    const asOf = elig?.voting_start ? new Date(elig.voting_start) : null;
    if (ageEnabled && (minAge === null || !asOf)) {
      return NextResponse.json(
        { error: 'Age requirement enabled but minimum_voting_age and/or voting_start not configured.' },
        { status: 400 }
      );
    }
```

- [ ] **Step 3: Compute eligibility in-memory (NO DOB persisted)** — inside the per-record loop, after `memberCode` is resolved (after line 186), before the upsert:

```typescript
      // Wave 5: derive age eligibility in-memory; DOB is NEVER persisted/logged.
      let isAgeEligible: boolean | null = null;
      let votingEligible = true;
      let eligibilityReason = 'ELIGIBLE';
      let eligibilitySource = 'CSV_IMPORT';
      if (ageEnabled) {
        const dobRaw = (record.dob || record.date_of_birth || '').trim();
        const dob = dobRaw ? new Date(dobRaw) : null;
        const valid = dob && !isNaN(dob.getTime());
        if (valid && asOf && minAge !== null) {
          let age = asOf.getFullYear() - dob!.getFullYear();
          const m = asOf.getMonth() - dob!.getMonth();
          if (m < 0 || (m === 0 && asOf.getDate() < dob!.getDate())) age--;
          isAgeEligible = age >= minAge;
          if (!isAgeEligible) { votingEligible = false; eligibilityReason = 'AGE_UNDER_MIN'; }
        } else {
          // UNDETERMINED (decision a — configurable)
          isAgeEligible = null;
          if (undeterminedIneligible) { votingEligible = false; eligibilityReason = 'UNDETERMINED'; }
        }
      }
```

- [ ] **Step 4: Persist only the derived fields** — replace the upsert object (lines 191-197) with:

```typescript
          {
            member_code: memberCode,
            full_name: fullName,
            email: email,
            phone: phone,
            is_active: true,
            voting_eligible: votingEligible,
            eligibility_reason: eligibilityReason,
            eligibility_source: eligibilitySource,
            is_age_eligible: isAgeEligible,
          },
```

- [ ] **Step 5: Verify no DOB leak** — confirm `dob`/`date_of_birth` appear ONLY in Steps 1/3 and never in the upsert, audit `details`, or `errors[]`. Run: `rg -n "dob|date_of_birth" app/api/admin/members-import/route.ts` — expected: matches only in the interface and the in-memory compute block.

- [ ] **Step 6: Commit**

```bash
git add app/api/admin/members-import/route.ts
git commit -m "feat(wave5): derive age eligibility at import without persisting DOB"
```

---

## Task 6: Gate digital dispatch + structured failures

**Files:** Modify `app/api/admin/tokens-dispatch/route.ts`.

- [ ] **Step 1: Select eligibility fields** — change the member select (line 33-37) to include eligibility:

```typescript
    const { data: members, error: membersError } = await supabaseServer
      .from('members')
      .select('id, member_code, full_name, email, voting_eligible, eligibility_reason, eligibility_source')
      .in('id', memberIds)
      .eq('is_active', true);
```

- [ ] **Step 2: Add eligibility gate + structured failures** — add a counter near line 59-61 and the gate at the top of the per-member loop (after line 63):

```typescript
    let sentCount = 0;
    let failedCount = 0;
    let eligibilityFailedCount = 0;
    const errors: string[] = [];
    const failures: Array<Record<string, unknown>> = [];
```

```typescript
      // Wave 5: gate VOTING dispatch on voting_eligible (NOMINATION is not gated).
      if (tokenType === 'VOTING' && member.voting_eligible !== true) {
        failedCount++;
        eligibilityFailedCount++;
        errors.push(`${member.full_name} (${member.member_code}): Ineligible — ${member.eligibility_reason}`);
        failures.push({
          memberId: member.id, memberCode: member.member_code,
          code: 'VOTER_INELIGIBLE',
          eligibilityReason: member.eligibility_reason,
          eligibilitySource: member.eligibility_source,
        });
        continue;
      }
```

- [ ] **Step 3: Extend the response + audit** — update the audit `details` (line 162-169) to include `eligibility_failed: eligibilityFailedCount`, and the JSON response (line 172-178) to:

```typescript
    return NextResponse.json({
      success: true,
      total: memberIds.length,
      sent: sentCount,
      failed: failedCount,
      eligibilityFailed: eligibilityFailedCount,
      errors: errors.slice(0, 20),
      failures: failures.slice(0, 20),
    });
```

- [ ] **Step 4: Commit**

```bash
git add app/api/admin/tokens-dispatch/route.ts
git commit -m "feat(wave5): gate digital VOTING dispatch on eligibility with structured failures"
```

---

## Task 7: Retire `scripts/dispatch-tokens.js`

**Files:** Delete `scripts/dispatch-tokens.js`; Modify `AGENTS.md` (Commands table).

- [ ] **Step 1: Delete the script**

```bash
git rm scripts/dispatch-tokens.js
```

- [ ] **Step 2: Remove its Commands-table row in `AGENTS.md`** — delete the line:

```
| Dispatch tokens | `node scripts/dispatch-tokens.js` |
```

- [ ] **Step 3: Grep for stale references** — Run: `rg -n "dispatch-tokens" --glob '!**/node_modules/**'` — expected: no matches. If any docs reference it, remove them in this commit.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore(wave5): retire dispatch-tokens.js (superseded by admin route + DB trigger backstop)"
```

---

## Task 8: Docs — canonical run order, extended wipe, privacy notice

**Files:** Modify `docs/TECHNICAL_GUIDE.md`.

- [ ] **Step 1: Append migrations 30–32 to the CANONICAL run order** (after current item 29) with the final-writer warning for item 32 (mirrors the existing item-28 warning at `TECHNICAL_GUIDE.md:236-243`):

```markdown
30. `supabase/migration_wave5_governance_ledger.sql` — wipe-surviving governance/RoPA ledger (governance schema; excluded from seed.sql).
31. `supabase/migration_wave5_eligibility_schema.sql` — eligibility columns + eligibility_adjudications.
32. `supabase/migration_wave5_eligibility_enforcement.sql` — **MUST be the final writer** for submit_anonymous_vote / issue_paper_ballot / issue_preprinted_paper_ballot; adds token-eligibility trigger + purge_roster_pii. Re-running any earlier writer for those RPCs after this re-opens the eligibility gap.
```

- [ ] **Step 2: Add "Extended wipe / erasure" subsection** (design §7.2) documenting: filesystem `archives/<election-run-id>/` handling, object-storage prefix deletion, and the honest **Supabase PITR/backups limitation** (erasure completes at retention expiry or project destruction — not by code), plus the ledger records to write.

```markdown
### Wipe / erasure is more than the DB

`seed.sql` clears DB tables only. A complete erasure ALSO requires:
- **Filesystem:** delete/move prior-org files under `archives/` (aggregate exports only — no raw exports exist by design).
- **Object storage:** delete the election/org bucket or prefix if used.
- **Supabase PITR/backups:** cannot be surgically erased by app code; completes at retention expiry or via project destruction. Record purge timestamp + retention window + expected expiry in the governance ledger.
- **Raw retention:** forbidden in-app. Any legally-compelled raw preservation is a manual out-of-band DBA action on written controller instruction, logged as a `RAW_RETENTION_OUT_OF_BAND_DECLARED` ledger event (no voter linkage).
```

- [ ] **Step 3: Add a CSV-import privacy notice line** documenting that an optional `dob` column is parsed in-memory to derive eligibility and is never stored.

- [ ] **Step 4: Commit**

```bash
git add docs/TECHNICAL_GUIDE.md
git commit -m "docs(wave5): canonical run order 30-32, extended-wipe runbook, import privacy notice"
```

---

## Task 9: Designer lane — eligibility tab + purge control (@designer)

**Files:** Modify `app/admin/dashboard/page.tsx` (designer-owned, do-not-flatten). **Route to `@designer`.** This task defines the DATA CONTRACT only; visuals/interaction are the designer's.

- [ ] **Step 1 (@designer):** Add a conditional **"Voter Eligibility"** tab, shown only when `election_settings.age_requirement_enabled`. It lists members with `votingEligible`, `eligibilityReason`, `eligibilitySource`, `isAgeEligible`, and an adjudication action that calls a new admin route wrapping an adjudication update + `eligibility_adjudications` insert. Reason/source vocab is fixed (design §4.2). Do NOT overload the existing `votingStatus` channel-state field.
- [ ] **Step 2 (@designer):** Add a **"Purge roster PII"** control (visible in `VOTING_CLOSED`/`COMPLETED`) with an explicit typed-confirmation (`PURGE`) calling a new admin route → `public.purge_roster_pii`. Stage CONTACT vs IDENTITY selectable; IDENTITY greys out until the 30-day window elapses. Surface the returned `{ success, stage, members_touched, message }`.
- [ ] **Step 3:** Orchestrator reviews the designer's user-facing copy afterward (per AGENTS.md design-handoff), preserving visual/interaction intent.
- [ ] **Step 4: Commit** (designer) — `feat(wave5): voter-eligibility tab + purge control (admin UI)`.

> Note: the two new admin API routes (`/api/admin/eligibility` adjudicate, `/api/admin/purge`) are mechanical `@fixer` work wrapping the RPCs with `requireAdminWithCsrf` + `insertAuditLog`; add them as bounded sub-tasks alongside Step 1/2 so the designer has endpoints to call.

---

## Task 10: Version bump + CHANGELOG

**Files:** Modify `package.json`, `docs/CHANGELOG.md`.

- [ ] **Step 1:** Bump `package.json` version `0.11.1` → `0.12.0` (new feature surface).
- [ ] **Step 2:** Add a `[0.12.0]` CHANGELOG entry: eligibility subsystem (both channels), two-stage PII purge, governance ledger, forbid-by-design raw export, extended-wipe docs, `dispatch-tokens.js` retired.
- [ ] **Step 3: Commit** — `chore(release): v0.12.0 — Wave 5 GDPR privacy subsystem`.

---

## Task 11: Verification + UAT gate (pre-merge)

- [ ] **Step 1:** `@verifier` standard tier — build (TS type-check) + lint. Expected: build OK; lint 0 new errors (19 baseline warnings tolerated).
- [ ] **Step 2:** Orchestrator DB-function UAT — re-run the sentinel harnesses from Tasks 1/2/4 against the live DB via Supabase MCP; all three must fail with their `*_OK` sentinels (rolled back).
- [ ] **Step 3:** Playwright UAT `tests/wave5-eligibility.spec.ts` — route-mocked structural check of the eligibility tab + purge control (no DB writes), per the `ui-verification` skill. `@fixer` writes; `@verifier`/orchestrator runs.
- [ ] **Step 4:** Present pre-merge summary (branch, commits, files, verifier + UAT results) and request explicit merge confirmation per AGENTS.md Git Workflow. **Do not merge without it.**

---

## Post-merge (AGENTS.md housekeeping — walk all four)
1. **Docs:** CHANGELOG done; confirm TECHNICAL_GUIDE + USER_GUIDE (purge/eligibility operator steps) updated; tag `v0.12.0`.
2. **Skills:** consider whether a reusable "governed-erasure / RoPA ledger" pattern is worth capturing.
3. **AGENTS.md:** dispatch-tokens row removed; verify no other stale command refs.
4. **Memory:** supersede/adjust the Wave 5 backlog memory (`mem_20260915_4u9s`) as implemented.

## Deployment
- Migrations 30–32 applied via Supabase MCP (part of the tasks).
- **No auto-deploy.** The dashboard UI changes (Task 9) require `vercel --prod --yes` after merge; RPC/route-only changes need none beyond the running app picking them up on next deploy.
