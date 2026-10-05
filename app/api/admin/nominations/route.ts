import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { requireAdmin } from '../auth';

type Suggestion = { memberId: string; fullName: string };
type UnmatchedNominationRow = {
  id: string;
  nominee_name: string;
  reason: string | null;
  submitted_date: string | null;
};

const PENDING_PAGE_SIZE = 200;
const PENDING_MAX_PAGES = 100;

export async function GET() {
  const authFail = await requireAdmin();
  if (authFail) return authFail;

  try {
    const { data: matchedRows, error: matchedError } = await supabaseServer
      .from('anonymous_nominations')
      .select('id, nominee_member_id, nominee_name')
      .not('nominee_member_id', 'is', null);

    if (matchedError) {
      return NextResponse.json({ error: matchedError.message }, { status: 500 });
    }

    const countByMember = new Map<string, { count: number; nomineeName: string; nominationIds: string[] }>();
    for (const row of matchedRows || []) {
      const memberId = row.nominee_member_id as string;
      const current = countByMember.get(memberId);
      if (current) {
        current.count += 1;
        current.nominationIds.push(row.id as string);
      } else {
        countByMember.set(memberId, {
          count: 1,
          nomineeName: row.nominee_name as string,
          nominationIds: [row.id as string],
        });
      }
    }

    const memberIds = Array.from(countByMember.keys());
    let memberNames = new Map<string, string>();
    if (memberIds.length > 0) {
      const { data: members, error: membersError } = await supabaseServer
        .from('members')
        .select('id, full_name')
        .in('id', memberIds);

      if (membersError) {
        return NextResponse.json({ error: membersError.message }, { status: 500 });
      }

      memberNames = new Map((members || []).map((m) => [m.id as string, m.full_name as string]));
    }

    const { data: promotedRows, error: promotedError } = await supabaseServer
      .from('nomination_adjudications')
      .select('nominee_member_id, candidate_id')
      .eq('decision', 'PROMOTE')
      .not('nominee_member_id', 'is', null);

    if (promotedError) {
      return NextResponse.json({ error: promotedError.message }, { status: 500 });
    }

    const promotedByMember = new Map<string, string | null>();
    for (const row of promotedRows || []) {
      promotedByMember.set(row.nominee_member_id as string, (row.candidate_id as string | null) ?? null);
    }

    const matched = memberIds.map((memberId) => ({
      nomineeMemberId: memberId,
      fullName: memberNames.get(memberId) || countByMember.get(memberId)?.nomineeName || 'Unknown',
      nominationCount: countByMember.get(memberId)?.count || 0,
      affectedNominationIds: countByMember.get(memberId)?.nominationIds || [],
      alreadyPromoted: promotedByMember.has(memberId),
      promotedCandidateId: promotedByMember.get(memberId) || null,
    }));

    const pendingRows: UnmatchedNominationRow[] = [];
    let cursorDate: string | null = null;
    let cursorId: string | null = null;
    for (let page = 0; page < PENDING_MAX_PAGES; page += 1) {
      const { data: batch, error: batchError } = await supabaseServer.rpc(
        'get_pending_unmatched_nominations',
        { p_limit: PENDING_PAGE_SIZE, p_cursor_date: cursorDate, p_cursor_id: cursorId }
      );

      if (batchError) {
        return NextResponse.json({ error: batchError.message }, { status: 500 });
      }

      const rows = (batch || []) as UnmatchedNominationRow[];
      pendingRows.push(...rows);

      if (rows.length < PENDING_PAGE_SIZE) {
        break;
      }

      const last = rows[rows.length - 1];
      cursorDate = last.submitted_date;
      cursorId = last.id;

      if (page === PENDING_MAX_PAGES - 1) {
        return NextResponse.json({ error: 'Pending nominations pagination limit reached' }, { status: 500 });
      }
    }

    const unmatched = await Promise.all(
      pendingRows.map(async (row) => {
        const name = (row.nominee_name as string) || '';
        const token = name.trim().split(/\s+/)[0] || name.trim();

        let suggestions: Suggestion[] = [];
        if (token.length >= 2) {
          const { data: suggestionRows } = await supabaseServer
            .from('members')
            .select('id, full_name')
            .eq('is_active', true)
            .ilike('full_name', `%${token}%`)
            .limit(3);

          suggestions = (suggestionRows || []).map((s) => ({
            memberId: s.id as string,
            fullName: s.full_name as string,
          }));
        }

        return {
          id: row.id as string,
          nomineeName: row.nominee_name as string,
          reason: (row.reason as string | null) ?? null,
          suggestions,
        };
      })
    );

    return NextResponse.json({ matched, unmatched });
  } catch {
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}
