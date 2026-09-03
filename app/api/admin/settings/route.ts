import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { requireAdmin, requireAdminWithCsrf, getAdminSession } from '../auth';
import { insertAuditLog } from '@/lib/audit-log';

const MIN_VOTING_TOKEN_TTL_HOURS = 1;
const MAX_VOTING_TOKEN_TTL_HOURS = 2160;

export async function GET() {
  const authFail = await requireAdmin();
  if (authFail) return authFail;

  try {
    const { data, error } = await supabaseServer
      .from('election_settings')
      .select('voting_token_ttl_hours')
      .eq('id', 1)
      .single();

    if (error) {
      return NextResponse.json({ error: error.message }, { status: 500 });
    }

    return NextResponse.json({ votingTokenTtlHours: data.voting_token_ttl_hours });
  } catch {
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}

export async function PATCH(req: Request) {
  const authFail = await requireAdminWithCsrf(req);
  if (authFail) return authFail;

  const adminSession = await getAdminSession();

  try {
    const { votingTokenTtlHours } = await req.json();

    if (
      !Number.isInteger(votingTokenTtlHours) ||
      votingTokenTtlHours < MIN_VOTING_TOKEN_TTL_HOURS ||
      votingTokenTtlHours > MAX_VOTING_TOKEN_TTL_HOURS
    ) {
      return NextResponse.json(
        {
          error: `votingTokenTtlHours must be an integer between ${MIN_VOTING_TOKEN_TTL_HOURS} and ${MAX_VOTING_TOKEN_TTL_HOURS}`,
        },
        { status: 400 }
      );
    }

    const { data: updatedSettings, error } = await supabaseServer
      .from('election_settings')
      .update({ voting_token_ttl_hours: votingTokenTtlHours })
      .eq('id', 1)
      .select('voting_token_ttl_hours')
      .single();

    if (error || !updatedSettings) {
      return NextResponse.json(
        { error: error?.message || 'Failed to update election settings' },
        { status: 500 }
      );
    }

    await insertAuditLog({
      action: 'SETTINGS_UPDATED',
      adminId: adminSession?.id || null,
      details: {
        voting_token_ttl_hours: votingTokenTtlHours,
        admin_ip: adminSession?.ip_address,
      },
    });

    return NextResponse.json({
      success: true,
      votingTokenTtlHours: updatedSettings.voting_token_ttl_hours,
    });
  } catch (err: unknown) {
    const errorMsg = err instanceof Error ? err.message : 'Server error';
    return NextResponse.json({ error: errorMsg }, { status: 500 });
  }
}
