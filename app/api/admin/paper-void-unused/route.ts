import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { getAdminSession, requireAdminWithCsrf } from '../auth';

export async function POST(req: Request) {
  const authFail = await requireAdminWithCsrf(req);
  if (authFail) return authFail;

  const adminSession = await getAdminSession();

  try {
    const { reason } = await req.json();

    const { data, error } = await supabaseServer.rpc('void_unused_anonymous_paper_blanks', {
      p_admin_id: adminSession?.id ?? null,
      p_reason: reason || undefined,
    });

    if (error || !data || !data[0]) {
      return NextResponse.json(
        { error: error?.message || 'Failed to void unused paper ballots.' },
        { status: 400 }
      );
    }

    return NextResponse.json({
      success: true,
      voidedCount: data[0].voided_count,
      message: data[0].message,
    });
  } catch (err: unknown) {
    const errorMsg = err instanceof Error ? err.message : 'Server error';
    return NextResponse.json({ error: errorMsg }, { status: 500 });
  }
}
