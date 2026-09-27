import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { requireAdminWithCsrf, getAdminSession } from '../auth';
import { insertAuditLog } from '@/lib/audit-log';

// Audit-only endpoint for the client-side member CSV export. The member data
// itself flows through the auth-gated members-manage GET (the dashboard
// already displays it); this records the EXPORT event in the governance
// ledger for accountability (who exported, when, how many rows). The row
// count is computed server-side, not trusted from the client.

export async function POST(req: Request) {
  const authFail = await requireAdminWithCsrf(req);
  if (authFail) return authFail;

  const adminSession = await getAdminSession();

  try {
    const { count, error } = await supabaseServer
      .from('members')
      .select('id', { count: 'exact', head: true });
    if (error) {
      return NextResponse.json({ error: 'Audit failed' }, { status: 500 });
    }

    await insertAuditLog({
      action: 'MEMBER_DATA_EXPORTED',
      adminId: adminSession?.id || null,
      details: { row_count: count ?? 0, admin_ip: adminSession?.ip_address },
    });

    return NextResponse.json({ success: true });
  } catch {
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}
