import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { requireAdmin } from '../auth';

// Scan-time ballot validation for the mobile wizard (Record/Spoil).
// Queries anonymous_paper_blanks — the member-blind blank pool (columns:
// ballot_id, status, generated/cast/voided timestamps, void_reason; no
// member/voter identity columns exist). Returns ONLY existence + status —
// never member_id or the ballot payload — so the anonymity property holds
// at the UI level. The confirm-time RPCs (submit_paper_vote /
// void_anonymous_paper_blank) remain the security boundary: they HMAC-verify
// and enforce status inside the database.

const MAX_BALLOT_ID_LENGTH = 200; // real IDs are ~135 chars

export async function GET(req: Request) {
  const authFail = await requireAdmin();
  if (authFail) return authFail;

  const { searchParams } = new URL(req.url);
  const ballotId = searchParams.get('ballot_id')?.trim() || '';
  if (!ballotId) {
    return NextResponse.json({ error: 'ballot_id required' }, { status: 400 });
  }
  if (ballotId.length > MAX_BALLOT_ID_LENGTH) {
    return NextResponse.json({ error: 'ballot_id too long' }, { status: 400 });
  }

  try {
    const { data, error } = await supabaseServer
      .from('anonymous_paper_blanks')
      .select('status')
      .eq('ballot_id', ballotId)
      .maybeSingle();

    if (error) {
      return NextResponse.json({ error: 'Lookup failed' }, { status: 500 });
    }

    return NextResponse.json({
      exists: Boolean(data),
      status: data?.status ?? null,
    });
  } catch {
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}
