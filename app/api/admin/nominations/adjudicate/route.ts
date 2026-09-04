import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { requireAdminWithCsrf, getAdminSession } from '../../auth';
import { insertAuditLog } from '@/lib/audit-log';

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

    let resolvedCandidateId: string | null = null;
    let resolvedNomineeName = typeof nomineeName === 'string' ? nomineeName.trim() : '';

    if (normalizedDecision === 'PROMOTE') {
      if (nomineeMemberId) {
        const { data: member, error: memberError } = await supabaseServer
          .from('members')
          .select('full_name')
          .eq('id', nomineeMemberId)
          .single();

        if (memberError || !member) {
          return NextResponse.json({ error: 'Nominee member not found' }, { status: 400 });
        }

        resolvedNomineeName = member.full_name as string;
      }

      if (!resolvedNomineeName) {
        return NextResponse.json({ error: 'Nominee name is required for promote' }, { status: 400 });
      }

      const { data: candidate, error: candidateError } = await supabaseServer
        .from('candidates')
        .insert({
          full_name: resolvedNomineeName,
          statement: typeof candidateStatement === 'string' ? candidateStatement : null,
          is_active: true,
        })
        .select('id')
        .single();

      if (candidateError || !candidate) {
        return NextResponse.json({ error: candidateError?.message || 'Failed to create candidate' }, { status: 500 });
      }

      resolvedCandidateId = candidate.id as string;
    }

    if (normalizedDecision === 'MERGE') {
      if (!candidateId || typeof candidateId !== 'string') {
        return NextResponse.json({ error: 'candidateId is required for merge' }, { status: 400 });
      }
      resolvedCandidateId = candidateId;
    }

    const { error: adjudicationError } = await supabaseServer
      .from('nomination_adjudications')
      .insert({
        admin_id: admin?.id || null,
        decision: normalizedDecision,
        candidate_id: resolvedCandidateId,
        nominee_member_id: nomineeMemberId ?? null,
        affected_nomination_ids: nominationIds,
        note: typeof note === 'string' ? note : null,
      });

    if (adjudicationError) {
      const msg = adjudicationError.message || 'Failed to record adjudication';
      if (msg.toLowerCase().includes('idx_adjudication_one_promote_per_nominee')) {
        return NextResponse.json({ error: 'Nominee already promoted.' }, { status: 409 });
      }
      return NextResponse.json({ error: msg }, { status: 400 });
    }

    await insertAuditLog({
      action: 'ADMIN_ACTION',
      adminId: admin?.id || null,
      details: {
        op: 'adjudicate_nomination',
        decision: normalizedDecision,
        nomineeMemberId: nomineeMemberId ?? null,
        candidateId: resolvedCandidateId,
        affectedNominationIds: nominationIds,
        admin_ip: admin?.ip_address,
      },
    });

    return NextResponse.json({ success: true, decision: normalizedDecision, candidateId: resolvedCandidateId });
  } catch {
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}
