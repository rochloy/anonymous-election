import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import crypto from 'crypto';
import { rateLimitError, validationError } from '@/lib/api-errors';

const IP_WINDOW = 60;
const IP_MAX = 30;
const TOK_WINDOW = 60;
const TOK_MAX = 12;

export async function POST(req: Request) {
  const ip = req.headers.get('x-forwarded-for')?.split(',')[0] || 'unknown';

  try {
    const { rawToken, query } = await req.json();
    if (!rawToken || typeof query !== 'string') {
      return validationError('Missing input');
    }
    if (query.trim().length < 2) {
      return NextResponse.json({ results: [] });
    }

    const tokenHash = crypto.createHash('sha256').update(rawToken).digest('hex');

    const { data: ipRl } = await supabaseServer.rpc('check_rate_limit', {
      p_identifier: `nominate_search_ip:${ip}`,
      p_window_seconds: IP_WINDOW,
      p_max_requests: IP_MAX,
    });
    if (ipRl && !ipRl.allowed) {
      return rateLimitError(IP_WINDOW);
    }

    const { data: tokRl } = await supabaseServer.rpc('check_rate_limit', {
      p_identifier: `nominate_search_tok:${tokenHash}`,
      p_window_seconds: TOK_WINDOW,
      p_max_requests: TOK_MAX,
    });
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
