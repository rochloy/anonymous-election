import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { requireAdminWithCsrf, getAdminSession } from '../../auth';

type Decision = 'PROMOTE' | 'MERGE' | 'DISCARD';

export async function POST(req: Request) {
  const authFail = await requireAdminWithCsrf(req);
  if (authFail) return authFail;

  const admin = await getAdminSession();

  try {
    const {
      decision,
      nomineeMemberId,
      nomineeName,
      affectedNominationIds,
      candidateStatement,
      candidateId,
      note,
    } = await req.json();

    if (!['PROMOTE', 'MERGE', 'DISCARD'].includes(decision)) {
      return NextResponse.json({ error: 'Invalid decision' }, { status: 400 });
    }

    const normalizedDecision = decision as Decision;
    const nominationIds: string[] = Array.isArray(affectedNominationIds)
      ? affectedNominationIds.filter((id) => typeof id === 'string')
      : [];

    if (nominationIds.length === 0) {
      return NextResponse.json({ error: 'affectedNominationIds is required' }, { status: 400 });
    }

    if (!admin) return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });

    const { data, error } = await supabaseServer.rpc('adjudicate_nomination', {
      p_decision: normalizedDecision,
      p_admin_session_id: admin.id,
      p_affected_nomination_ids: nominationIds,
      p_nominee_member_id: nomineeMemberId ?? null,
      p_nominee_name: typeof nomineeName === 'string' ? nomineeName : null,
      p_candidate_statement: typeof candidateStatement === 'string' ? candidateStatement : null,
      p_candidate_id: typeof candidateId === 'string' ? candidateId : null,
      p_note: typeof note === 'string' ? note : null,
    });

    const row = Array.isArray(data) ? data[0] : data;

    if (error) {
      const lowerMessage = (error.message || '').toLowerCase();
      if (lowerMessage.includes('idx_adjudication_one_promote_per_nominee') || error.code === '23505') {
        return NextResponse.json({ error: 'Nominee already promoted.' }, { status: 409 });
      }
      return NextResponse.json({ error: error.message }, { status: 400 });
    }

    if (!row?.success) {
      return NextResponse.json({ error: row?.message || 'Adjudication failed' }, { status: 400 });
    }

    return NextResponse.json({ success: true, decision: normalizedDecision, candidateId: row.candidate_id });
  } catch {
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}
