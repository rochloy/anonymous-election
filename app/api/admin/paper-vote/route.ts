import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { requireAdmin } from '../auth';

export async function POST(req: Request) {
  const authFail = requireAdmin(req);
  if (authFail) return authFail;

  try {
    const { memberCode, candidateId } = await req.json();
    if (!memberCode || !candidateId)
      return NextResponse.json({ error: 'memberCode and candidateId required' }, { status: 400 });

    const { data, error } = await supabaseServer.rpc('submit_paper_vote', {
      p_member_code: memberCode,
      p_candidate_id: candidateId,
    });

    if (error || !data || !data[0]?.success) {
      return NextResponse.json({ error: data?.[0]?.message || 'Paper vote failed.' }, { status: 400 });
    }

    return NextResponse.json({ success: true, message: data[0].message });
  } catch {
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}
