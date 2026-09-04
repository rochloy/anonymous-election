import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { requireAdminWithCsrf, getAdminSession } from '../../auth';
import { insertAuditLog } from '@/lib/audit-log';

export async function POST(req: Request) {
  const authFail = await requireAdminWithCsrf(req);
  if (authFail) return authFail;

  const admin = await getAdminSession();

  try {
    const { nomineeMemberId, nomineeName, reason } = await req.json();

    let { data, error } = await supabaseServer.rpc('admin_add_nomination', {
      p_nominee_member_id: nomineeMemberId ?? null,
      p_nominee_name: nomineeName ?? null,
      p_reason: reason ?? null,
    });

    if (error) {
      try {
        const res = await supabaseServer.schema('private').rpc('admin_add_nomination', {
          p_nominee_member_id: nomineeMemberId ?? null,
          p_nominee_name: nomineeName ?? null,
          p_reason: reason ?? null,
        });
        if (!res.error && res.data) {
          data = res.data;
          error = null;
        }
      } catch {
        // keep original error
      }
    }

    if (error || !data || !data[0]?.success) {
      return NextResponse.json({ error: data?.[0]?.message || 'Add failed.' }, { status: 400 });
    }

    await insertAuditLog({
      action: 'ADMIN_ACTION',
      adminId: admin?.id || null,
      details: {
        op: 'add_nomination',
        nomineeMemberId: nomineeMemberId ?? null,
        admin_ip: admin?.ip_address,
      },
    });

    return NextResponse.json({ success: true });
  } catch {
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}
