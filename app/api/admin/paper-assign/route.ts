import { NextResponse } from 'next/server';
import QRCode from 'qrcode';
import { supabaseServer } from '@/lib/supabase-server';
import { requireAdmin } from '../auth';

export async function POST(req: Request) {
  const authFail = requireAdmin(req);
  if (authFail) return authFail;

  try {
    const { ballotId: rawBallotId, memberId } = await req.json();
    let ballotId = rawBallotId;

    if (ballotId && ballotId.startsWith('http')) {
      try {
        const u = new URL(ballotId);
        const id = u.searchParams.get('ballot_id');
        if (id) ballotId = decodeURIComponent(id);
      } catch {
        // not a valid URL — use as-is
      }
    }

    if (!ballotId || !memberId) {
      return NextResponse.json({ error: 'ballotId and memberId required' }, { status: 400 });
    }

    const { data, error } = await supabaseServer.rpc('issue_preprinted_paper_ballot', {
      p_ballot_id: ballotId,
      p_member_id: memberId,
    });

    if (error || !data || !data[0]?.success) {
      return NextResponse.json(
        { error: data?.[0]?.message || error?.message || 'Failed to assign paper ballot.' },
        { status: 400 }
      );
    }

    const res = data[0];
    const baseUrl = process.env.APP_BASE_URL || 'http://localhost:3000';
    const qrPayload = `${baseUrl}/verify?ballot_id=${encodeURIComponent(res.ballot_id)}`;
    const qrDataUrl = await QRCode.toDataURL(qrPayload, {
      width: 512,
      margin: 2,
      errorCorrectionLevel: 'M',
      color: { dark: '#000000', light: '#ffffff' },
    });
    const qrSvg = await QRCode.toString(qrPayload, {
      type: 'svg',
      errorCorrectionLevel: 'M',
      margin: 2,
      width: 512,
      color: { dark: '#000000', light: '#ffffff' },
    });

    return NextResponse.json({
      success: true,
      message: res.message,
      ballotId: res.ballot_id,
      shortCode: res.short_code,
      qrDataUrl,
      qrSvg,
    });
  } catch (err: unknown) {
    const errorMsg = err instanceof Error ? err.message : 'Server error';
    return NextResponse.json({ error: errorMsg }, { status: 500 });
  }
}
