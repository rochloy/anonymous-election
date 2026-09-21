import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { requireAdminWithCsrf, getAdminSession } from '../auth';
import { insertAuditLog } from '@/lib/audit-log';

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

export async function POST(req: Request) {
  const authFail = await requireAdminWithCsrf(req);
  if (authFail) return authFail;

  const admin = await getAdminSession();
  if (!admin) return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });

  try {
    // Phase gate: eligibility can only be changed during SETUP phase.
    // Once the election process starts (NOMINATION or later), eligibility is locked.
    const { data: settings, error: settingsError } = await supabaseServer
      .from('election_settings')
      .select('current_phase')
      .eq('id', 1)
      .maybeSingle();

    if (settingsError) {
      return NextResponse.json({ error: settingsError.message }, { status: 500 });
    }

    const currentPhase = settings?.current_phase || 'SETUP';
    if (currentPhase !== 'SETUP') {
      return NextResponse.json(
        { error: 'Eligibility can only be changed during SETUP phase.' },
        { status: 400 }
      );
    }

    const { member_id, voting_eligible, eligibility_reason, note } = await req.json();

    if (typeof member_id !== 'string' || !isUuid(member_id)) {
      return NextResponse.json({ error: 'member_id must be a valid UUID' }, { status: 400 });
    }

    if (typeof voting_eligible !== 'boolean') {
      return NextResponse.json({ error: 'voting_eligible must be a boolean' }, { status: 400 });
    }

    if (typeof eligibility_reason !== 'string' || !eligibility_reason.trim()) {
      return NextResponse.json({ error: 'eligibility_reason is required' }, { status: 400 });
    }

    if (note !== undefined && note !== null && typeof note !== 'string') {
      return NextResponse.json({ error: 'note must be a string or null' }, { status: 400 });
    }

    const { data, error } = await supabaseServer.rpc('adjudicate_eligibility', {
      p_admin_session_id: admin.id,
      p_member_id: member_id,
      p_new_voting_eligible: voting_eligible,
      p_new_eligibility_reason: eligibility_reason,
      p_note: note ?? null,
    });

    const row = Array.isArray(data) ? data[0] : data;

    if (error) {
      return NextResponse.json({ error: error.message }, { status: 500 });
    }

    if (!row?.success) {
      return NextResponse.json({ error: row?.message || 'Eligibility adjudication failed' }, { status: 400 });
    }

    await insertAuditLog({
      action: 'ELIGIBILITY_ADJUDICATED',
      adminId: admin.id,
      memberId: member_id,
      details: {
        member_id,
        voting_eligible,
        eligibility_reason,
      },
    });

    return NextResponse.json({ success: true, message: row.message });
  } catch {
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}
