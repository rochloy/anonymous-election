import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { getAdminSession, requireAdminWithCsrf } from '../auth';

export async function POST(req: Request) {
  const authFail = await requireAdminWithCsrf(req);
  if (authFail) return authFail;

  const adminSession = await getAdminSession();

  try {
    const { memberId } = await req.json();
    if (!memberId) {
      return NextResponse.json({ error: 'memberId is required' }, { status: 400 });
    }

    const { data, error } = await supabaseServer.rpc('issue_paper_ballot', {
      p_member_id: memberId,
      p_admin_id: adminSession?.id ?? null,
    });

    if (error || !data || !data[0]?.success) {
      return NextResponse.json(
        { error: data?.[0]?.message || error?.message || 'Failed to issue paper ballot.' },
        { status: 400 }
      );
    }

    const res = data[0];

    return NextResponse.json({
      success: true,
      message: res.message,
      memberName: res.member_name,
      memberCode: res.member_code,
      shortCode: res.short_code,
      participationDate: res.participation_date,
      status: res.status,
    });
  } catch (err: unknown) {
    const errorMsg = err instanceof Error ? err.message : 'Server error';
    return NextResponse.json({ error: errorMsg }, { status: 500 });
  }
}
