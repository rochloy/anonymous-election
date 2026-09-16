import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { requireAdminWithCsrf, getAdminSession } from '../auth';
import { insertAuditLog } from '@/lib/audit-log';

export async function POST(req: Request) {
  const authFail = await requireAdminWithCsrf(req);
  if (authFail) return authFail;

  const admin = await getAdminSession();

  try {
    const { stage, confirm } = await req.json();

    if (stage !== 'CONTACT' && stage !== 'IDENTITY') {
      return NextResponse.json({ error: 'stage must be CONTACT or IDENTITY' }, { status: 400 });
    }

    if (typeof confirm !== 'string') {
      return NextResponse.json({ error: 'confirm is required' }, { status: 400 });
    }

    if (!admin) return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });

    const { data, error } = await supabaseServer.rpc('purge_roster_pii', {
      p_admin_id: admin.id,
      p_stage: stage,
      p_confirm: confirm,
    });

    const row = Array.isArray(data) ? data[0] : data;

    if (error) {
      return NextResponse.json({ error: error.message }, { status: 500 });
    }

    if (!row?.success) {
      const message = row?.message || 'Roster purge failed';
      if (
        message === 'Stage CONTACT requires VOTING_CLOSED/COMPLETED' ||
        message === 'Stage IDENTITY requires 30-day dispute window elapsed'
      ) {
        return NextResponse.json({ error: message }, { status: 409 });
      }
      return NextResponse.json({ error: message }, { status: 400 });
    }

    await insertAuditLog({
      action: 'ROSTER_PII_PURGED',
      adminId: admin.id,
      details: {
        stage: row.stage,
        members_touched: row.members_touched,
      },
    });

    return NextResponse.json({
      success: true,
      stage: row.stage,
      members_touched: row.members_touched,
      message: row.message,
    });
  } catch {
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}
