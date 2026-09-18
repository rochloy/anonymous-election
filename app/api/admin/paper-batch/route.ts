import { NextResponse } from 'next/server';
import QRCode from 'qrcode';
import { supabaseServer } from '@/lib/supabase-server';
import { getAdminSession, requireAdminWithCsrf } from '../auth';

export async function POST(req: Request) {
  const authFail = await requireAdminWithCsrf(req);
  if (authFail) return authFail;

  const adminSession = await getAdminSession();

  try {
    const { count } = await req.json();

    if (!Number.isInteger(count) || count < 1 || count > 1000) {
      return NextResponse.json({ error: 'count must be an integer between 1 and 1000' }, { status: 400 });
    }

    const { data, error } = await supabaseServer.rpc('generate_anonymous_blank_ballot_pool', {
      p_count: count,
      p_admin_id: adminSession?.id ?? null,
    });

    if (error || !data || !data[0]) {
      return NextResponse.json(
        { error: error?.message || 'Failed to generate paper ballot batch.' },
        { status: 400 }
      );
    }

    const res = data[0];
    const ballotIds: string[] = res.ballot_ids || [];

    const baseUrl = process.env.APP_BASE_URL || 'http://localhost:3000';
    const ballotsWithQr = await Promise.all(
      ballotIds.map(async (ballotId) => {
        const qrPayload = `${baseUrl}/verify?ballot_id=${encodeURIComponent(ballotId)}`;
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

        return {
          ballotId,
          qrDataUrl,
          qrSvg,
        };
      })
    );

    return NextResponse.json({
      success: true,
      generatedCount: res.generated_count,
      message: res.message,
      ballots: ballotsWithQr,
    });
  } catch (err: unknown) {
    const errorMsg = err instanceof Error ? err.message : 'Server error';
    return NextResponse.json({ error: errorMsg }, { status: 500 });
  }
}
