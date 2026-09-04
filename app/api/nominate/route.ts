import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import crypto from 'crypto';
import { rateLimitError, validationError } from '@/lib/api-errors';

const WINDOW = 60;
const MAX = 5;

export async function POST(req: Request) {
  const ip = req.headers.get('x-forwarded-for')?.split(',')[0] || 'unknown';
  try {
    const { data: rl, error: rlError } = await supabaseServer.rpc('check_rate_limit', {
      p_identifier: `nominate:${ip}`,
      p_window_seconds: WINDOW,
      p_max_requests: MAX,
    });
    if (rlError) {
      console.error('[nominate] rate limit RPC error:', rlError);
    } else if (!rl?.allowed) {
      return rateLimitError(WINDOW);
    }
  } catch (err) {
    console.error('[nominate] rate limit failed:', err);
  }

  try {
    const { rawToken, nominees } = await req.json();
    if (!rawToken || !Array.isArray(nominees) || nominees.length === 0) {
      return validationError('Missing input');
    }

    const tokenHash = crypto.createHash('sha256').update(rawToken).digest('hex');

    let { data, error } = await supabaseServer.rpc('submit_nomination', {
      p_token_hash: tokenHash,
      p_nominees: nominees,
    });

    if (error) {
      try {
        const res = await supabaseServer.schema('private').rpc('submit_nomination', {
          p_token_hash: tokenHash,
          p_nominees: nominees,
        });
        if (!res.error && res.data) {
          data = res.data;
          error = null;
        }
      } catch {
        // keep original error
      }
    }

    if (error || !data || !data[0]?.success) {
      return NextResponse.json(
        { error: data?.[0]?.message || 'Nomination failed.' },
        { status: 400 }
      );
    }

    return NextResponse.json({ success: true, insertedCount: data[0].inserted_count });
  } catch {
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}
