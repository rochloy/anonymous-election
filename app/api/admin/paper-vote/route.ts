import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { requireAdmin, requireAdminWithCsrf } from '../auth';

export async function POST(req: Request) {
  const authFail = await requireAdminWithCsrf(req);
  if (authFail) return authFail;

  try {
    const { ballotId: rawBallotId, candidateId } = await req.json();
    // Defensive: if a full verify URL is pasted instead of a raw ballot_id,
    // extract the ballot_id query param. Handles both new URL-format and
    // legacy raw payloads.
    let ballotId = rawBallotId;
    if (ballotId && ballotId.startsWith('http')) {
      try {
        const u = new URL(ballotId);
        const id = u.searchParams.get('ballot_id');
        if (id) ballotId = decodeURIComponent(id);
      } catch {
        // not a valid URL — use as-is
      }
    }
    if (!ballotId || !candidateId)
      return NextResponse.json({ error: 'ballotId and candidateId required' }, { status: 400 });

    // Call public wrapper RPC directly (which delegates to private.submit_paper_vote)
    let { data, error } = await supabaseServer.rpc('submit_paper_vote', {
      p_ballot_id: ballotId,
      p_candidate_id: candidateId,
    });

    // Fallback: try private schema explicitly if public wrapper not present
    if (error) {
      try {
        const resPrivate = await supabaseServer.schema('private').rpc('submit_paper_vote', {
          p_ballot_id: ballotId,
          p_candidate_id: candidateId,
        });
        if (!resPrivate.error && resPrivate.data) {
          data = resPrivate.data;
          error = null;
        }
      } catch {
        // keep original error
      }
    }

    if (error || !data || !data[0]?.success) {
      return NextResponse.json({ error: data?.[0]?.message || 'Paper vote failed.' }, { status: 400 });
    }

    return NextResponse.json({
      success: true,
      message: data[0].message,
      receiptCode: data[0].receipt_code,
    });
  } catch {
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}
