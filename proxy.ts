import { NextResponse } from 'next/server';
import type { NextRequest } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import {
  classifyRateLimitResult,
  logRateLimitDenied,
  logRateLimitFault,
} from '@/lib/rate-limit';

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
//
// F14 Tier-3 (2026-10-08): style-src is split. style-src-elem locks <style>
// ELEMENTS to 'self' in prod — verified against the deployed HTML (zero
// inline <style> tags; all CSS ships as one 'self' stylesheet), closing the
// CSS-exfiltration and UI-redressing vectors for an HTML-injection attacker.
// Dev appends 'unsafe-inline' because HMR injects <style> elements at runtime
// (script-created style elements are governed by style-src-elem too).
// style-src-attr keeps 'unsafe-inline' in BOTH modes: style attributes cannot
// contain selector rules, so they are not an exfiltration vector, and the
// app's 3 style={{}} props plus html5-qrcode's element styling depend on them
// (html5-qrcode verified: no <style>-element injection in its bundled builds).
function buildCspHeader(nonce: string): string {
  return [
    "default-src 'self'",
    `script-src 'self' 'nonce-${nonce}' 'strict-dynamic'${isProd ? '' : " 'unsafe-eval'"}`,
    `style-src-elem 'self'${isProd ? '' : " 'unsafe-inline'"}`,
    "style-src-attr 'unsafe-inline'",
    // blob:: file-scan loads the user-picked photo via URL.createObjectURL()
    // (mobile wizard "Scan from photo"); blob URLs are same-origin scoped.
    // No external image hosts: candidate photos were removed entirely (item 51,
    // 2026-10-08) — the only <img> in the app is the QR code (data: URL).
    "img-src 'self' data: blob:",
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

      const rateLimitOutcome = classifyRateLimitResult({ data, error });

      if (rateLimitOutcome === 'deny') {
        logRateLimitDenied('admin_proxy');
        const deniedResponse = NextResponse.json(
          { error: 'Rate limit exceeded', retryAfter: WINDOW_SECONDS },
          { status: 429, headers: { 'Retry-After': String(WINDOW_SECONDS) } }
        );
        deniedResponse.headers.set('Content-Security-Policy', csp);
        return deniedResponse;
      }

      if (rateLimitOutcome === 'fault') {
        logRateLimitFault('admin_proxy');
        // Fail open - allow request if rate limiter fails (keep the CSP header)
        return response;
      }
    } catch (err) {
      void err;
      logRateLimitFault('admin_proxy');
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
