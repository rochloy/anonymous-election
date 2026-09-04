import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import crypto from 'crypto';
import { rateLimitError, validationError } from '@/lib/api-errors';
import { isValidRawToken, NOMINATION_LIMITS } from '@/lib/input-validation';

const IP_WINDOW = 60;
const IP_MAX = 30;
const TOK_WINDOW = 60;
const TOK_MAX = 12;

// SEC-02: de-correlate the per-token rate-limit identifier from tokens.token_hash.
// A dedicated pepper is preferred; fall back to ADMIN_SECRET so no new required env
// var is introduced. Both are server-only secrets, never shipped to the client.
const RATE_LIMIT_SECRET = process.env.RATE_LIMIT_SECRET || process.env.ADMIN_SECRET || '';

export async function POST(req: Request) {
  const ip = req.headers.get('x-forwarded-for')?.split(',')[0] || 'unknown';

  try {
    const { rawToken, query } = await req.json();
    if (!isValidRawToken(rawToken) || typeof query !== 'string') {
      return validationError('Missing input');
    }
    if (query.length > NOMINATION_LIMITS.searchQueryMax) {
      return validationError(
        `Query exceeds ${NOMINATION_LIMITS.searchQueryMax} characters.`
      );
    }
    if (query.trim().length < 2) {
      return NextResponse.json({ results: [] });
    }

    const tokenHash = crypto.createHash('sha256').update(rawToken).digest('hex');
    // SEC-02: HMAC the token hash so the stored rate-limit identifier is not a
    // direct join key back to tokens.token_hash.
    const tokenRlId = crypto
      .createHmac('sha256', RATE_LIMIT_SECRET)
      .update(tokenHash)
      .digest('hex');

    const { data: ipRl, error: ipRlError } = await supabaseServer.rpc('check_rate_limit', {
      p_identifier: `nominate_search_ip:${ip}`,
      p_window_seconds: IP_WINDOW,
      p_max_requests: IP_MAX,
    });
    if (ipRlError) {
      console.error('[nominate/search] IP rate limit RPC error:', ipRlError);
      return NextResponse.json({ error: 'Rate limit unavailable' }, { status: 503 });
    }
    if (ipRl && !ipRl.allowed) {
      return rateLimitError(IP_WINDOW);
    }

    const { data: tokRl, error: tokRlError } = await supabaseServer.rpc('check_rate_limit', {
      p_identifier: `nominate_search_tok:${tokenRlId}`,
      p_window_seconds: TOK_WINDOW,
      p_max_requests: TOK_MAX,
    });
    if (tokRlError) {
      console.error('[nominate/search] token rate limit RPC error:', tokRlError);
      return NextResponse.json({ error: 'Rate limit unavailable' }, { status: 503 });
    }
    if (tokRl && !tokRl.allowed) {
      return rateLimitError(TOK_WINDOW);
    }

    let { data, error } = await supabaseServer.rpc('search_members_for_nomination', {
      p_token_hash: tokenHash,
      p_query: query,
    });

    if (error) {
      try {
        const res = await supabaseServer.schema('private').rpc('search_members_for_nomination', {
          p_token_hash: tokenHash,
          p_query: query,
        });
        if (!res.error) {
          data = res.data;
          error = null;
        }
      } catch {
        // keep original error
      }
    }

    if (error) {
      return NextResponse.json({ results: [] });
    }

    return NextResponse.json({
      results: (data || []).map((r: { member_id: string; full_name: string }) => ({
        memberId: r.member_id,
        fullName: r.full_name,
      })),
    });
  } catch {
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}
