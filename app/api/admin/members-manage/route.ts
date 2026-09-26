import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { requireAdmin, requireAdminWithCsrf, getAdminSession } from '../auth';
import { insertAuditLog } from '@/lib/audit-log';
import { validateEmail, validateLength, validatePhone, INPUT_LIMITS } from '@/lib/input-validation';

export async function GET(req: Request) {
  const authFail = await requireAdmin();
  if (authFail) return authFail;

  try {
    const { searchParams } = new URL(req.url);
    const limit = parseInt(searchParams.get('limit') || '100', 10);
    const offset = parseInt(searchParams.get('offset') || '0', 10);
    const activeOnly = searchParams.get('active_only') === 'true';

    let query = supabaseServer
      .from('members')
      .select('id, member_code, full_name, email, phone, is_active, created_at')
      .order('created_at', { ascending: false })
      .range(offset, offset + limit - 1);

    if (activeOnly) {
      query = query.eq('is_active', true);
    }

    const { data, error } = await query;

    if (error) {
      return NextResponse.json({ error: error.message }, { status: 500 });
    }

    // Roster data-completeness counts (all members, independent of the list filter).
    // Empty strings are not possible: all write paths store NULLIF(trim(x), '').
    const { count: totalCount, error: totalError } = await supabaseServer
      .from('members').select('id', { count: 'exact', head: true });
    const { count: emailCount, error: emailError } = await supabaseServer
      .from('members').select('id', { count: 'exact', head: true }).not('email', 'is', null);
    const { count: phoneCount, error: phoneError } = await supabaseServer
      .from('members').select('id', { count: 'exact', head: true }).not('phone', 'is', null);
    const { count: bothCount, error: bothError } = await supabaseServer
      .from('members').select('id', { count: 'exact', head: true }).not('email', 'is', null).not('phone', 'is', null);

    const countError = totalError || emailError || phoneError || bothError;
    if (countError) {
      return NextResponse.json({ error: countError.message }, { status: 500 });
    }

    return NextResponse.json({
      members: data || [],
      stats: {
        total: totalCount || 0,
        withEmail: emailCount || 0,
        withPhone: phoneCount || 0,
        withBoth: bothCount || 0,
      },
    });
  } catch {
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}

export async function PATCH(req: Request) {
  const authFail = await requireAdminWithCsrf(req);
  if (authFail) return authFail;

  const adminSession = await getAdminSession();

  try {
    const { id, is_active } = await req.json();

    if (!id) {
      return NextResponse.json({ error: 'Member ID is required' }, { status: 400 });
    }

    if (typeof is_active !== 'boolean') {
      return NextResponse.json({ error: 'is_active must be a boolean' }, { status: 400 });
    }

    const { data, error } = await supabaseServer.rpc('set_member_active', {
      p_member_id: id,
      p_active: is_active,
    });

    if (error) {
      const isPhaseError = error.message?.includes('Member edits are only allowed during SETUP, NOMINATION, or NOMINATION_CLOSED phases.');
      if (isPhaseError) {
        return NextResponse.json({ error: error.message }, { status: 400 });
      }
      return NextResponse.json({ error: error.message }, { status: 500 });
    }

    // Audit log
    await insertAuditLog({
      action: is_active ? 'MEMBER_ACTIVATED' : 'MEMBER_DEACTIVATED',
      adminId: adminSession?.id || null,
      memberId: id,
      details: { member_code: data.member_code, full_name: data.full_name, admin_ip: adminSession?.ip_address },
    });

    return NextResponse.json({ success: true, member: data });
  } catch (err: unknown) {
    const errorMsg = err instanceof Error ? err.message : 'Server error';
    return NextResponse.json({ error: errorMsg }, { status: 500 });
  }
}

export async function POST(req: Request) {
  const authFail = await requireAdminWithCsrf(req);
  if (authFail) return authFail;

  const adminSession = await getAdminSession();

  try {
    const { full_name, email, phone, member_code, dob, age_eligible_asserted } = await req.json();

    // XOR: a DOB and the "Age eligible" assertion are mutually exclusive.
    const dobProvided = typeof dob === 'string' && dob.trim() !== '';
    const assertedProvided = age_eligible_asserted === true;
    if (dobProvided && assertedProvided) {
      return NextResponse.json(
        { error: 'Provide either a date of birth or the "Age eligible" assertion — not both.' },
        { status: 400 }
      );
    }

    // Validate DOB format before creating anything (ISO 8601 via new Date()).
    let dobParsed: Date | null = null;
    if (dobProvided) {
      dobParsed = new Date(dob.trim());
      if (isNaN(dobParsed.getTime())) {
        return NextResponse.json(
          { error: 'Invalid date of birth — use ISO 8601 (YYYY-MM-DD).' },
          { status: 400 }
        );
      }
    }

    const nameValidation = validateLength(full_name, 'full_name', INPUT_LIMITS.member.full_name);
    if (!nameValidation.valid) {
      return NextResponse.json({ error: nameValidation.error }, { status: 400 });
    }

    const memberCodeValidation = validateLength(
      member_code ?? null,
      'member_code',
      { min: 0, max: INPUT_LIMITS.member.member_code.max }
    );
    if (!memberCodeValidation.valid) {
      return NextResponse.json({ error: memberCodeValidation.error }, { status: 400 });
    }

    const emailValidation = validateEmail(email ?? null);
    if (!emailValidation.valid) {
      return NextResponse.json({ error: emailValidation.error }, { status: 400 });
    }

    const phoneValidation = validatePhone(phone ?? null);
    if (!phoneValidation.valid) {
      return NextResponse.json({ error: phoneValidation.error }, { status: 400 });
    }

    const trimmedMemberCode = typeof member_code === 'string' ? member_code.trim() : null;
    const { data, error } = await supabaseServer.rpc('create_member', {
      p_full_name: full_name,
      p_email: email ?? null,
      p_phone: phone ?? null,
      p_member_code: trimmedMemberCode ? trimmedMemberCode : null,
    });

    if (error) {
      if (error.code === '23505' || error.message?.includes('MEMBER_UNIQUE_CONFLICT')) {
        return NextResponse.json({ error: 'Member code/email/phone already exists' }, { status: 409 });
      }
      const isValidationError =
        error.message?.includes('Member edits are only allowed during SETUP, NOMINATION, or NOMINATION_CLOSED phases.') ||
        error.message?.includes('Member creation is only allowed during SETUP, NOMINATION, or NOMINATION_CLOSED phases') ||
        error.message?.includes('full_name is required');
      if (isValidationError) {
        return NextResponse.json({ error: error.message }, { status: 400 });
      }
      return NextResponse.json({ error: error.message }, { status: 500 });
    }

    // Post-creation eligibility determination (Wave 5 pattern): derived
    // in-memory — the DOB is NEVER persisted or logged. Safe in all phases:
    // the table default is ELIGIBLE, so this can only restrict (AGE_UNDER_MIN)
    // or affirm the default — never expand eligibility during VOTING.
    if (dobProvided || assertedProvided) {
      const { data: elig } = await supabaseServer
        .from('election_settings')
        .select('age_requirement_enabled, minimum_voting_age, voting_start')
        .eq('id', 1)
        .single();
      const ageEnabled = !!elig?.age_requirement_enabled;
      const minAge = elig?.minimum_voting_age ?? null;
      const asOf = elig?.voting_start ? new Date(elig.voting_start) : new Date();

      let votingEligible = true;
      let eligibilityReason = 'ELIGIBLE';
      let eligibilitySource = 'SYSTEM_DEFAULT';

      if (assertedProvided) {
        // Admin asserts age eligibility without collecting a DOB (check-in path).
        votingEligible = true;
        eligibilityReason = 'ELIGIBLE';
        eligibilitySource = 'ADMIN_ADJUDICATION';
      } else if (ageEnabled && minAge !== null && dobParsed) {
        let age = asOf.getFullYear() - dobParsed.getFullYear();
        const m = asOf.getMonth() - dobParsed.getMonth();
        if (m < 0 || (m === 0 && asOf.getDate() < dobParsed.getDate())) age--;
        if (age >= minAge) {
          votingEligible = true;
          eligibilityReason = 'ELIGIBLE';
        } else {
          votingEligible = false;
          eligibilityReason = 'AGE_UNDER_MIN';
        }
        eligibilitySource = 'SYSTEM_RECOMPUTE';
      }

      await supabaseServer
        .from('members')
        .update({
          voting_eligible: votingEligible,
          eligibility_reason: eligibilityReason,
          eligibility_source: eligibilitySource,
        })
        .eq('id', data.id);
    }

    await insertAuditLog({
      action: 'MEMBER_CREATED',
      adminId: adminSession?.id || null,
      memberId: data.id,
      details: { member_code: data.member_code, full_name: data.full_name, admin_ip: adminSession?.ip_address },
    });

    return NextResponse.json({ success: true, member: data });
  } catch (err: unknown) {
    const errorMsg = err instanceof Error ? err.message : 'Server error';
    return NextResponse.json({ error: errorMsg }, { status: 500 });
  }
}
