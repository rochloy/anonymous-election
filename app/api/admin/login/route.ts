import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import crypto from 'crypto';
import { cookies } from 'next/headers';
import { generateCsrfToken, CSRF_COOKIE_NAME, SESSION_COOKIE_NAME } from '../auth';
import { rateLimitError } from '@/lib/api-errors';

const SESSION_TTL_SECONDS = 10 * 60; // 10 minutes idle
const DESKTOP_COOKIE_MAX_AGE_SECONDS = 4 * 60 * 60; // 4 hours absolute
const MOBILE_SESSION_TTL_SECONDS = 12 * 60;
const LOGIN_RATE_LIMIT_WINDOW = 60;
const LOGIN_RATE_LIMIT_MAX = 5;

export async function POST(req: Request) {
  try {
    const { secret, scope } = await req.json();
    const ip = req.headers.get('x-forwarded-for')?.split(',')[0]?.trim() || 'unknown';

    const { data: rateLimitData, error: rlError } = await supabaseServer.rpc('check_rate_limit', {
      p_identifier: `admin-login:${ip}`,
      p_window_seconds: LOGIN_RATE_LIMIT_WINDOW,
      p_max_requests: LOGIN_RATE_LIMIT_MAX,
    });

    if (rlError || !rateLimitData?.allowed) {
      if (rlError) {
        console.error('[admin/login] Rate limit RPC error:', rlError);
      }
      return rateLimitError(LOGIN_RATE_LIMIT_WINDOW);
    }

    const expected = process.env.ADMIN_SECRET;
    const sessionScope = scope === 'mobile' ? 'mobile' : 'desktop';
    const isMobileScope = sessionScope === 'mobile';
    const sessionTtlSeconds = isMobileScope ? MOBILE_SESSION_TTL_SECONDS : SESSION_TTL_SECONDS;

    if (!expected || secret !== expected) {
      return NextResponse.json({ error: 'Invalid admin secret' }, { status: 401 });
    }

    const cookieStore = await cookies();
    const existingSessionToken = cookieStore.get(SESSION_COOKIE_NAME)?.value;
    if (existingSessionToken) {
      try {
        const existingTokenHash = crypto.createHash('sha256').update(existingSessionToken).digest('hex');
        const { error: revokeError } = await supabaseServer
          .from('admin_sessions')
          .update({ revoked_at: new Date().toISOString(), revoke_reason: 'reauth', token_hash: null })
          .eq('token_hash', existingTokenHash)
          .is('revoked_at', null);
        if (revokeError) {
          console.warn('[admin/login] Failed to revoke previous session during reauth:', revokeError);
        }
      } catch (revokeErr) {
        console.warn('[admin/login] Failed to revoke previous session during reauth:', revokeErr);
      }
    }

    // Generate session token
    const sessionToken = crypto.randomBytes(32).toString('hex');
    const tokenHash = crypto.createHash('sha256').update(sessionToken).digest('hex');
    const expiresAt = new Date(Date.now() + sessionTtlSeconds * 1000);

    // Generate CSRF token
    const csrfToken = generateCsrfToken();

    // Store session in database
    const { error: insertError } = await supabaseServer
      .from('admin_sessions')
      .insert({
        token_hash: tokenHash,
        scope: sessionScope,
        expires_at: expiresAt.toISOString(),
        user_agent: req.headers.get('user-agent') || null,
        ip_address: ip,
      });

    if (insertError) {
      console.error('[admin/login] Failed to create session:', insertError);
      return NextResponse.json({ error: 'Failed to create session' }, { status: 500 });
    }

    // Set HttpOnly session cookie + CSRF cookie (not HttpOnly so JS can read it)
    const res = NextResponse.json({ success: true, csrfToken, expiresAt: expiresAt.toISOString() });
    res.headers.set('Cache-Control', 'no-store');
    res.cookies.set(SESSION_COOKIE_NAME, sessionToken, {
      httpOnly: true,
      secure: process.env.NODE_ENV === 'production',
      sameSite: 'strict',
      maxAge: isMobileScope ? MOBILE_SESSION_TTL_SECONDS : DESKTOP_COOKIE_MAX_AGE_SECONDS,
      path: '/',
    });
    res.cookies.set(CSRF_COOKIE_NAME, csrfToken, {
      httpOnly: false, // Must be readable by JavaScript for double-submit pattern
      secure: process.env.NODE_ENV === 'production',
      sameSite: 'strict',
      maxAge: isMobileScope ? MOBILE_SESSION_TTL_SECONDS : DESKTOP_COOKIE_MAX_AGE_SECONDS,
      path: '/',
    });

    return res;
  } catch (err: unknown) {
    console.error('[admin/login] error:', err);
    return NextResponse.json({ error: 'Internal server error' }, { status: 500 });
  }
}
