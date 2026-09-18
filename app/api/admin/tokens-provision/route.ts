import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { requireAdminWithCsrf, getAdminSession } from '../auth';
import { insertAuditLog } from '@/lib/audit-log';

export async function POST(req: Request) {
  const authFail = await requireAdminWithCsrf(req);
  if (authFail) return authFail;

  const adminSession = await getAdminSession();

  try {
    const { memberIds } = await req.json();

    if (memberIds !== undefined && (!Array.isArray(memberIds) || memberIds.length === 0)) {
      return NextResponse.json({ error: 'memberIds must be a non-empty array or omitted for all active eligible members' }, { status: 400 });
    }

    const { data, error } = await supabaseServer.rpc('provision_voting_entitlements', {
      p_member_ids: memberIds ?? null,
      p_admin_id: adminSession?.id ?? null,
    });

    if (error || !data || !data[0]) {
      return NextResponse.json(
        { error: data?.[0]?.message || error?.message || 'Failed to provision voting entitlements' },
        { status: 400 }
      );
    }

    const res = data[0];

    // Audit log (RPC already writes ENTITLEMENTS_PROVISIONED via insert_audit_log,
    // but we also log at app layer for consistency with other admin actions)
    await insertAuditLog({
      action: 'ENTITLEMENTS_PROVISIONED_API',
      adminId: adminSession?.id || null,
      details: {
        requested: res.requested_count,
        created: res.created_count,
        existing: res.existing_count,
        ineligible: res.ineligible_count,
        consumed: res.consumed_count,
        integrity_failed: res.integrity_failed_count,
        admin_ip: adminSession?.ip_address,
      },
    });

    return NextResponse.json({
      success: true,
      requested: res.requested_count,
      created: res.created_count,
      existing: res.existing_count,
      ineligible: res.ineligible_count,
      consumed: res.consumed_count,
      integrityFailed: res.integrity_failed_count,
    });
  } catch (err: unknown) {
    const errorMsg = err instanceof Error ? err.message : 'Server error';
    return NextResponse.json({ error: errorMsg }, { status: 500 });
  }
}