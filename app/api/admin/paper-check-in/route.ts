import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { requireAdminWithCsrf, getAdminSession } from '../auth';
import { insertAuditLog } from '@/lib/audit-log';

export async function POST(req: Request) {
  const authFail = await requireAdminWithCsrf(req);
  if (authFail) return authFail;

  const adminSession = await getAdminSession();

  try {
    const { shortCode, memberId } = await req.json();

    if (!shortCode || !memberId) {
      return NextResponse.json({ error: 'shortCode and memberId are required' }, { status: 400 });
    }

    const { data, error } = await supabaseServer.rpc('check_in_paper_voter', {
      p_short_code: shortCode.trim().toUpperCase(),
      p_member_id: memberId,
      p_admin_id: adminSession?.id ?? null,
    });

    if (error || !data || !data[0]?.success) {
      return NextResponse.json(
        { error: data?.[0]?.message || error?.message || 'Failed to check in paper voter' },
        { status: 400 }
      );
    }

    const res = data[0];

    // Audit log (RPC writes PARTICIPATION_AUDIT, but we also log at app layer)
    await insertAuditLog({
      action: 'PAPER_CHECK_IN_API',
      adminId: adminSession?.id || null,
      memberId,
      details: {
        short_code: res.short_code,
        member_name: res.member_name,
        member_code: res.member_code,
        participation_date: res.participation_date,
        status: res.status,
        admin_ip: adminSession?.ip_address,
      },
    });

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