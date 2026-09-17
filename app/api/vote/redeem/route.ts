import { NextResponse } from 'next/server';
import crypto from 'crypto';
import { supabaseServer } from '@/lib/supabase-server';

export async function POST(req: Request) {
  try {
    const { token } = await req.json();

    if (!token || typeof token !== 'string') {
      return NextResponse.json({ success: false, message: 'Missing token' }, { status: 400 });
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

    const tokenHash = crypto.createHash('sha256').update(token).digest('hex');

    const { data, error } = await supabaseServer.rpc('redeem_voting_token', {
      p_token_hash: tokenHash,
    });

    if (error) {
      return NextResponse.json({ success: false, message: error.message }, { status: 500 });
    }

    const result = Array.isArray(data) ? data[0] : data;

    if (!result?.o_success) {
      return NextResponse.json({ success: false, message: result?.o_message || 'Redeem failed.' }, { status: 400 });
    }

    return NextResponse.json({
      success: true,
      message: result.o_message,
      credential: result.o_credential,
      ttlSeconds: result.o_ttl_seconds,
    });
  } catch (err: unknown) {
    const errorMsg = err instanceof Error ? err.message : 'Server error';
    return NextResponse.json({ success: false, message: errorMsg }, { status: 500 });
  }
}
