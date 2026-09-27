import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { requireAdminWithCsrf, getAdminSession } from '../auth';

// In-app "Danger zone" database wipe (new-election setup). SETUP-only
// (enforced server-side by the RPC), atomic (one RPC = one transaction),
// data-only (the seed.sql truncate list; HMAC key + schema untouched),
// governance-logged (WIPE_STARTED/WIPE_COMPLETED to the wipe-surviving
// ledger, inside the transaction). NOTE: admin_sessions is wiped — the
// calling admin is logged out immediately after a successful wipe.

export async function POST(req: Request) {
  const authFail = await requireAdminWithCsrf(req);
  if (authFail) return authFail;

  const adminSession = await getAdminSession();

  try {
    // Client-side UX gate mirrored server-side by the RPC.
    const { data: settings } = await supabaseServer
      .from('election_settings')
      .select('current_phase')
      .eq('id', 1)
      .single();
    if (settings?.current_phase !== 'SETUP') {
      return NextResponse.json(
        { error: 'Database wipe is only allowed during SETUP phase.' },
        { status: 400 }
      );
    }

    const { data, error } = await supabaseServer.rpc('wipe_election_data', {
      p_admin_id: adminSession?.id ?? null,
    });

    if (error) {
      return NextResponse.json({ error: error.message }, { status: 500 });
    }
    if (!data || !data[0]?.success) {
      return NextResponse.json(
        { error: data?.[0]?.message || 'Database wipe failed.' },
        { status: 400 }
      );
    }

    return NextResponse.json({ success: true, message: data[0].message });
  } catch (err: unknown) {
    const errorMsg = err instanceof Error ? err.message : 'Server error';
    return NextResponse.json({ error: errorMsg }, { status: 500 });
  }
}
