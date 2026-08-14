import { NextResponse } from 'next/server';
import QRCode from 'qrcode';
import { supabaseServer } from '@/lib/supabase-server';
import { requireAdmin } from '../auth';

export async function POST(req: Request) {
  const authFail = requireAdmin(req);
  if (authFail) return authFail;

  try {
    const { count } = await req.json();

    if (!Number.isInteger(count) || count < 1 || count > 1000) {
      return NextResponse.json({ error: 'count must be an integer between 1 and 1000' }, { status: 400 });
    }

    const { data, error } = await supabaseServer.rpc('generate_blank_paper_ballot_batch', {
      p_count: count,
    });

    if (error || !data || !data[0]) {
      return NextResponse.json(
        { error: error?.message || 'Failed to generate paper ballot batch.' },
        { status: 400 }
      );
    }

    const res = data[0];
    const batchId: string = res.batch_id;

    const { data: ballots, error: ballotsError } = await supabaseServer
      .from('paper_ballots')
      .select('ballot_id, short_code, batch_id, status')
      .eq('batch_id', batchId)
      .order('created_at', { ascending: true });

    if (ballotsError) {
      return NextResponse.json({ error: ballotsError.message }, { status: 500 });
    }

    const baseUrl = process.env.APP_BASE_URL || 'http://localhost:3000';
    const ballotsWithQr = await Promise.all(
      (ballots || []).map(async (b) => {
        const qrPayload = `${baseUrl}/verify?ballot_id=${encodeURIComponent(b.ballot_id)}`;
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
          ballotId: b.ballot_id,
          shortCode: b.short_code,
          qrDataUrl,
          qrSvg,
        };
      })
    );

    return NextResponse.json({
      success: true,
      batchId,
      generatedCount: res.generated_count,
      message: res.message,
      ballots: ballotsWithQr,
    });
  } catch (err: unknown) {
    const errorMsg = err instanceof Error ? err.message : 'Server error';
    return NextResponse.json({ error: errorMsg }, { status: 500 });
  }
}
