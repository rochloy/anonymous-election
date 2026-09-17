import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';

export async function POST(req: Request) {
  try {
    const { credential, candidateId } = await req.json();

    if (!credential || typeof credential !== 'string' || !candidateId || typeof candidateId !== 'string') {
      return NextResponse.json({ success: false, message: 'Missing input' }, { status: 400 });
    }

    const { data: settings, error: settingsError } = await supabaseServer
      .from('election_settings')
      .select('digital_write_mode')
      .eq('id', 1)
      .maybeSingle();

    const digitalWriteMode = settingsError ? 'LEGACY' : settings?.digital_write_mode ?? 'LEGACY';

    if (digitalWriteMode !== 'TWO_PHASE') {
      return NextResponse.json(
        {
          success: false,
          message: 'Digital voting is in single-phase mode. Use /api/vote.',
          code: 'LEGACY_MODE',
        },
        { status: 409 }
      );
    }

    const { data, error } = await supabaseServer.rpc('cast_anonymous_digital_vote', {
      p_credential: credential,
      p_candidate_id: candidateId,
    });

    if (error) {
      return NextResponse.json({ success: false, message: error.message }, { status: 500 });
    }

    const result = Array.isArray(data) ? data[0] : data;

    if (!result?.o_success) {
      return NextResponse.json({ success: false, message: result?.o_message || 'Vote failed.' }, { status: 400 });
    }

    return NextResponse.json({
      success: true,
      message: result.o_message,
      receiptCode: result.o_receipt_code,
      ballotId: result.o_ballot_id,
    });
  } catch (err: unknown) {
    const errorMsg = err instanceof Error ? err.message : 'Server error';
    return NextResponse.json({ success: false, message: errorMsg }, { status: 500 });
  }
}
