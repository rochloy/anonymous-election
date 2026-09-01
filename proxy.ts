import { NextResponse } from 'next/server';
import type { NextRequest } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';

// Distributed rate limiter using Supabase (per-IP, 120 req/min in production, 1000 in dev).
// Uses a sliding window with atomic increments via SECURITY DEFINER RPC.

const WINDOW_SECONDS = 60;
const MAX_HITS = process.env.NODE_ENV === 'production' ? 120 : 1000;

export async function proxy(req: NextRequest) {
  if (req.nextUrl.pathname.startsWith('/api/admin')) {
    const ip = req.headers.get('x-forwarded-for')?.split(',')[0] || 'unknown';

    try {
      const { data, error } = await supabaseServer.rpc('check_rate_limit', {
        p_identifier: ip,
        p_window_seconds: WINDOW_SECONDS,
        p_max_requests: MAX_HITS,
      });

      if (error) {
        console.error('[rate-limit] RPC error:', error);
        // Fail open - allow request if rate limiter fails
        return NextResponse.next();
      }

      if (!data?.allowed) {
        return NextResponse.json(
          { error: 'Rate limit exceeded', retryAfter: WINDOW_SECONDS },
          { status: 429, headers: { 'Retry-After': String(WINDOW_SECONDS) } }
        );
      }
    } catch (err) {
      console.error('[rate-limit] Unexpected error:', err);
      // Fail open
      return NextResponse.next();
    }
  }
  return NextResponse.next();
}

export const config = {
  matcher: ['/api/admin/:path*'],
};