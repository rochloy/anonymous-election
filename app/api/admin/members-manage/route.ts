import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { requireAdmin, requireAdminWithCsrf, getAdminSession } from '../auth';
import { insertAuditLog } from '@/lib/audit-log';

export async function GET(req: Request) {
  const authFail = await requireAdmin();
  if (authFail) return authFail;

  try {
    const { searchParams } = new URL(req.url);
    const limit = parseInt(searchParams.get('limit') || '100', 10);
    const offset = parseInt(searchParams.get('offset') || '0', 10);
    const activeOnly = searchParams.get('active_only') === 'true';

    let query = supabaseServer
      .from('members')
      .select('id, member_code, full_name, email, phone, is_active, created_at')
      .order('created_at', { ascending: false })
      .range(offset, offset + limit - 1);

    if (activeOnly) {
      query = query.eq('is_active', true);
    }

    const { data, error } = await query;

    if (error) {
      return NextResponse.json({ error: error.message }, { status: 500 });
    }

    return NextResponse.json({ members: data || [] });
  } catch {
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}

export async function PATCH(req: Request) {
  const authFail = await requireAdminWithCsrf(req);
  if (authFail) return authFail;

  const adminSession = await getAdminSession();

  try {
    const { id, is_active } = await req.json();

    if (!id) {
      return NextResponse.json({ error: 'Member ID is required' }, { status: 400 });
    }

    if (typeof is_active !== 'boolean') {
      return NextResponse.json({ error: 'is_active must be a boolean' }, { status: 400 });
    }

    const { data, error } = await supabaseServer
      .from('members')
      .update({ is_active })
      .eq('id', id)
      .select('id, member_code, full_name, email, is_active')
      .single();

    if (error) {
      return NextResponse.json({ error: error.message }, { status: 500 });
    }

    // Audit log
    await insertAuditLog({
      action: is_active ? 'MEMBER_ACTIVATED' : 'MEMBER_DEACTIVATED',
      adminId: adminSession?.id || null,
      memberId: id,
      details: { member_code: data.member_code, full_name: data.full_name, admin_ip: adminSession?.ip_address },
    });

    return NextResponse.json({ success: true, member: data });
  } catch (err: unknown) {
    const errorMsg = err instanceof Error ? err.message : 'Server error';
    return NextResponse.json({ error: errorMsg }, { status: 500 });
  }
}