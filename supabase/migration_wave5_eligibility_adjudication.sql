-- Wave 5 migration 33: atomic voter-eligibility adjudication RPC.
-- Keeps the admin eligibility-override write inside a single SECURITY DEFINER transaction
-- (members UPDATE + append-only eligibility_adjudications INSERT) per the project architecture
-- rule that all writes go through private-schema RPCs, never direct PostgREST table writes.
-- Mirrors the adjudicate_nomination pattern. is_age_eligible is a factual age assessment and is
-- NOT changed by a manual adjudication (old = new in the audit row).

CREATE OR REPLACE FUNCTION private.adjudicate_eligibility(
  p_admin_session_id UUID,
  p_member_id UUID,
  p_new_voting_eligible BOOLEAN,
  p_new_eligibility_reason TEXT,
  p_note TEXT DEFAULT NULL
) RETURNS TABLE(success BOOLEAN, message TEXT, member_id UUID)
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, private AS $$
DECLARE
  v_old RECORD;
BEGIN
  -- Lock the member row; capture the pre-image for the audit record.
  SELECT id, voting_eligible, eligibility_reason, eligibility_source, is_age_eligible
    INTO v_old FROM members WHERE id = p_member_id FOR UPDATE;
  IF v_old.id IS NULL THEN
    RETURN QUERY SELECT FALSE, 'Member not found.'::TEXT, p_member_id; RETURN;
  END IF;

  -- Clean, early consistency guard (the members CHECK enforces this too, but give a nice message).
  IF (p_new_voting_eligible = TRUE  AND p_new_eligibility_reason <> 'ELIGIBLE')
  OR (p_new_voting_eligible = FALSE AND p_new_eligibility_reason  = 'ELIGIBLE') THEN
    RETURN QUERY SELECT FALSE,
      'Inconsistent adjudication: eligible=TRUE requires reason ELIGIBLE; eligible=FALSE requires a non-ELIGIBLE reason.'::TEXT,
      p_member_id;
    RETURN;
  END IF;

  -- No-op guard: nothing to record if the decision is unchanged.
  IF v_old.voting_eligible = p_new_voting_eligible
     AND v_old.eligibility_reason = p_new_eligibility_reason THEN
    RETURN QUERY SELECT FALSE, 'No change: member already in that eligibility state.'::TEXT, p_member_id;
    RETURN;
  END IF;

  -- Atomic override: members UPDATE (source = ADMIN_ADJUDICATION; is_age_eligible unchanged).
  UPDATE members
     SET voting_eligible   = p_new_voting_eligible,
         eligibility_reason = p_new_eligibility_reason,
         eligibility_source = 'ADMIN_ADJUDICATION'
   WHERE id = p_member_id;

  -- Append-only audit row (member-linked; wiped with the election).
  INSERT INTO eligibility_adjudications(
    member_id, admin_id,
    old_voting_eligible, old_eligibility_reason, old_eligibility_source, old_is_age_eligible,
    new_voting_eligible, new_eligibility_reason, new_eligibility_source, new_is_age_eligible,
    note)
  VALUES (
    p_member_id, p_admin_session_id,
    v_old.voting_eligible, v_old.eligibility_reason, v_old.eligibility_source, v_old.is_age_eligible,
    p_new_voting_eligible, p_new_eligibility_reason, 'ADMIN_ADJUDICATION', v_old.is_age_eligible,
    p_note);

  RETURN QUERY SELECT TRUE, 'Eligibility adjudicated.'::TEXT, p_member_id;
END;
$$;

-- PostgREST-exposed public wrapper (service_role only).
CREATE OR REPLACE FUNCTION public.adjudicate_eligibility(
  p_admin_session_id UUID,
  p_member_id UUID,
  p_new_voting_eligible BOOLEAN,
  p_new_eligibility_reason TEXT,
  p_note TEXT DEFAULT NULL
) RETURNS TABLE(success BOOLEAN, message TEXT, member_id UUID)
  LANGUAGE sql SECURITY DEFINER SET search_path = public, private AS $$
  SELECT * FROM private.adjudicate_eligibility($1,$2,$3,$4,$5);
$$;
REVOKE ALL ON FUNCTION public.adjudicate_eligibility(UUID,UUID,BOOLEAN,TEXT,TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.adjudicate_eligibility(UUID,UUID,BOOLEAN,TEXT,TEXT) TO service_role;
