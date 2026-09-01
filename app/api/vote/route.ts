import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import crypto from 'crypto';
import { rateLimitError, validationError } from '@/lib/api-errors';

const VOTE_RATE_LIMIT_WINDOW = 60; // seconds
const VOTE_RATE_LIMIT_MAX = 5; // requests per window

export async function POST(req: Request) {
  // Rate limiting by IP
  const ip = req.headers.get('x-forwarded-for')?.split(',')[0] || 'unknown';
  try {
    const { data: rateLimitData, error: rlError } = await supabaseServer.rpc('check_rate_limit', {
      p_identifier: `vote:${ip}`,
      p_window_seconds: VOTE_RATE_LIMIT_WINDOW,
      p_max_requests: VOTE_RATE_LIMIT_MAX,
    });

    if (rlError) {
      console.error('[vote] Rate limit RPC error:', rlError);
    } else if (!rateLimitData?.allowed) {
      return rateLimitError(VOTE_RATE_LIMIT_WINDOW);
    }
  } catch (err) {
    console.error('[vote] Rate limit check failed:', err);
    // Fail open
  }

  try {
    const { rawToken, candidateId } = await req.json();
    if (!rawToken || !candidateId)
      return validationError('Missing input');

    const tokenHash = crypto.createHash('sha256').update(rawToken).digest('hex');

    // Defense in depth: enforce token expiry at route layer before RPC submission
    const { data: tokenRecord, error: tokenLookupError } = await supabaseServer
      .from('tokens')
      .select('expires_at')
      .eq('token_hash', tokenHash)
      .eq('type', 'VOTING')
      .single();

    if (tokenLookupError || !tokenRecord || !tokenRecord.expires_at || new Date(tokenRecord.expires_at) < new Date()) {
      return NextResponse.json({ error: 'Invalid or expired voting token.' }, { status: 400 });
    }

    // RPC generates the receipt code internally with CSPRNG + retry.
    // Call public wrapper RPC directly (which delegates to private.submit_anonymous_vote)
    let { data, error } = await supabaseServer.rpc('submit_anonymous_vote', {
      p_token_hash: tokenHash,
      p_candidate_id: candidateId,
    });

    // Fallback: try private schema explicitly if public wrapper not present
    if (error) {
      try {
        const resPrivate = await supabaseServer.schema('private').rpc('submit_anonymous_vote', {
          p_token_hash: tokenHash,
          p_candidate_id: candidateId,
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
      return NextResponse.json({ error: data?.[0]?.message || 'Vote failed.' }, { status: 400 });
    }

    return NextResponse.json({ success: true, receiptCode: data[0].receipt_code });
  } catch {
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}
