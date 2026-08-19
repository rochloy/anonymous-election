import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import crypto from 'crypto';

const SESSION_COOKIE_NAME = 'admin_session';
const SESSION_TTL_SECONDS = 30 * 60; // 30 minutes

export async function POST(req: Request) {
  try {
    const { secret } = await req.json();
    const expected = process.env.ADMIN_SECRET;

    if (!expected || secret !== expected) {
      return NextResponse.json({ error: 'Invalid admin secret' }, { status: 401 });
    }

    // Generate session token
    const sessionToken = crypto.randomBytes(32).toString('hex');
    const tokenHash = crypto.createHash('sha256').update(sessionToken).digest('hex');
    const expiresAt = new Date(Date.now() + SESSION_TTL_SECONDS * 1000);

    // Store session in database
    const { error: insertError } = await supabaseServer
      .from('admin_sessions')
      .insert({
        token_hash: tokenHash,
        expires_at: expiresAt.toISOString(),
        user_agent: req.headers.get('user-agent') || null,
        ip_address: req.headers.get('x-forwarded-for')?.split(',')[0] || null,
      });

    if (insertError) {
      console.error('[admin/login] Failed to create session:', insertError);
      return NextResponse.json({ error: 'Failed to create session' }, { status: 500 });
    }

    // Set HttpOnly cookie
    const res = NextResponse.json({ success: true });
    res.cookies.set(SESSION_COOKIE_NAME, sessionToken, {
      httpOnly: true,
      secure: process.env.NODE_ENV === 'production',
      sameSite: 'strict',
      maxAge: SESSION_TTL_SECONDS,
      path: '/',
    });

    return res;
  } catch (err: unknown) {
    console.error('[admin/login] error:', err);
    return NextResponse.json({ error: 'Internal server error' }, { status: 500 });
  }
}