import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { requireAdmin } from '../auth';

export async function POST(req: Request) {
  const authFail = requireAdmin(req);
  if (authFail) return authFail;

  try {
    const { ballotId, reason } = await req.json();
    if (!ballotId) {
      return NextResponse.json({ error: 'ballotId is required' }, { status: 400 });
    }

    // Call public wrapper RPC directly (which delegates to private.submit_paper_invalid)
    let { data, error } = await supabaseServer.rpc('submit_paper_invalid', {
      p_ballot_id: ballotId,
      p_reason: reason || 'Spoiled by admin',
    });

    // Fallback: try private schema explicitly if public wrapper not present
    if (error) {
      try {
        const resPrivate = await supabaseServer.schema('private').rpc('submit_paper_invalid', {
          p_ballot_id: ballotId,
          p_reason: reason || 'Spoiled by admin',
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
      return NextResponse.json(
        { error: data?.[0]?.message || error?.message || 'Failed to spoil ballot.' },
        { status: 400 }
      );
    }

    return NextResponse.json({ success: true, message: data[0].message });
  } catch (err: unknown) {
    const errorMsg = err instanceof Error ? err.message : 'Server error';
    return NextResponse.json({ error: errorMsg }, { status: 500 });
  }
}
