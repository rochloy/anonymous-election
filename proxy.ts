import { NextResponse } from 'next/server';
import type { NextRequest } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';

// Distributed rate limiter using Supabase (per-IP, 120 req/min in production, 1000 in dev).
// Uses a sliding window with atomic increments via SECURITY DEFINER RPC.

const WINDOW_SECONDS = 60;
const MAX_HITS = process.env.NODE_ENV === 'production' ? 120 : 1000;
const isProd = process.env.NODE_ENV === 'production';

// F14 Tier-2: per-request CSP nonce. Prod: 'self' 'nonce-<n>' 'strict-dynamic'
// (no 'unsafe-inline'/'unsafe-eval'). Dev appends 'unsafe-eval' (React/Next dev
// requirement — documented in docs/plans/2026-09-18-f14-csp-tier2-nonce.md).
// The CSP header is emitted ONLY here — next.config.ts no longer sets a CSP
// header (double-CSP headers intersect in browsers and silently break inline
// scripts). Next auto-propagates the nonce parsed from the request CSP header
// to its framework/bootstrap inline scripts and page JS bundles.
function buildCspHeader(nonce: string): string {
  return [
    "default-src 'self'",
    `script-src 'self' 'nonce-${nonce}' 'strict-dynamic'${isProd ? '' : " 'unsafe-eval'"}`,
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data: https:",
    "font-src 'self'",
    "connect-src 'self' https://*.supabase.co https://api.resend.com",
    "frame-ancestors 'none'",
    "form-action 'self'",
    "base-uri 'self'",
  ].join('; ');
}

export async function proxy(req: NextRequest) {
  // F14 Tier-2: nonce + CSP on every matched request (pages + APIs; the CSP
  // header is inert on JSON responses). The request-header copy is what Next
  // parses for nonce auto-propagation; the response-header copy is what the
  // browser enforces.
  const nonce = Buffer.from(crypto.randomUUID()).toString('base64');
  const csp = buildCspHeader(nonce);
  const requestHeaders = new Headers(req.headers);
  requestHeaders.set('x-nonce', nonce);
  requestHeaders.set('Content-Security-Policy', csp);
  const response = NextResponse.next({ request: { headers: requestHeaders } });
  response.headers.set('Content-Security-Policy', csp);

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
        // Fail open - allow request if rate limiter fails (keep the CSP header)
        return response;
      }

      if (!data?.allowed) {
        return NextResponse.json(
          { error: 'Rate limit exceeded', retryAfter: WINDOW_SECONDS },
          { status: 429, headers: { 'Retry-After': String(WINDOW_SECONDS) } }
        );
      }
    } catch (err) {
      console.error('[rate-limit] Unexpected error:', err);
      // Fail open (keep the CSP header)
      return response;
    }
  }
  return response;
}

export const config = {
  // Cover all routes except static assets (they are not documents and need no
  // CSP). /api/admin stays covered so rate-limiting still fires; the CSP header
  // on API JSON is inert. Per Step 0: no page exclusions — every page is a
  // 'use client' shell, so flipping static pages to Dynamic loses only shell
  // CDN caching, no functionality.
  matcher: ['/((?!_next/static|_next/image|favicon.ico).*)'],
};
