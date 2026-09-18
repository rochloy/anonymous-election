import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { getAdminSession, requireAdminWithCsrf } from '../auth';

export async function POST(req: Request) {
  const authFail = await requireAdminWithCsrf(req);
  if (authFail) return authFail;

  const adminSession = await getAdminSession();

  try {
    const { ballotId, shortCode, reason } = await req.json();

    if ((ballotId && shortCode) || (!ballotId && !shortCode)) {
      return NextResponse.json(
        { error: 'Provide exactly one of ballotId or shortCode' },
        { status: 400 }
      );
    }

    const spoilReason = reason || 'Spoiled by admin';

    if (shortCode) {
      const { data, error } = await supabaseServer.rpc('spoil_paper_check_in', {
        p_short_code: shortCode,
        p_reason: spoilReason,
        p_admin_id: adminSession?.id ?? null,
      });

      if (error || !data || !data[0]?.success) {
        return NextResponse.json(
          { error: data?.[0]?.message || error?.message || 'Failed to spoil paper check-in.' },
          { status: 400 }
        );
      }

      return NextResponse.json({ success: true, message: data[0].message });
    }

    const { data, error } = await supabaseServer.rpc('void_anonymous_paper_blank', {
      p_ballot_id: ballotId,
      p_reason: spoilReason,
      p_admin_id: adminSession?.id ?? null,
    });

    if (error || !data || !data[0]?.success) {
      return NextResponse.json(
        { error: data?.[0]?.message || error?.message || 'Failed to void anonymous paper blank.' },
        { status: 400 }
      );
    }

    return NextResponse.json({ success: true, message: data[0].message });
  } catch (err: unknown) {
    const errorMsg = err instanceof Error ? err.message : 'Server error';
    return NextResponse.json({ error: errorMsg }, { status: 500 });
  }
}
