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
