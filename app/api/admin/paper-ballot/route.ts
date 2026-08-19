import { NextResponse } from 'next/server';
import QRCode from 'qrcode';
import { supabaseServer } from '@/lib/supabase-server';
import { requireAdmin, requireAdminWithCsrf } from '../auth';

export async function POST(req: Request) {
  const authFail = await requireAdminWithCsrf(req);
  if (authFail) return authFail;

  try {
    const { memberId } = await req.json();
    if (!memberId) {
      return NextResponse.json({ error: 'memberId is required' }, { status: 400 });
    }

    // Call public wrapper RPC directly (which delegates to private.issue_paper_ballot)
    let { data, error } = await supabaseServer.rpc('issue_paper_ballot', {
      p_member_id: memberId,
    });

    // Fallback: try private schema explicitly if public wrapper not present
    if (error) {
      try {
        const resPrivate = await supabaseServer.schema('private').rpc('issue_paper_ballot', {
          p_member_id: memberId,
        });
        if (!resPrivate.error && resPrivate.data) {
          data = resPrivate.data;
          error = null;
        }
      } catch {
        // keep original error
      }
    }

    if (error || !data || !data[0]?.success) {
      return NextResponse.json(
        { error: data?.[0]?.message || error?.message || 'Failed to issue paper ballot.' },
        { status: 400 }
      );
    }

    const res = data[0];
    // Override the DB-side placeholder SVG with a real, scannable QR code.
    // The QR encodes a URL pointing to /verify?ballot_id=<ballot_id> so that
    // native phone cameras (iOS/Android) recognize it as an actionable link.
    // The in-app admin scanner extracts the ballot_id from the URL query param.
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
