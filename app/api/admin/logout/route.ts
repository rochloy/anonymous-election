import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { cookies } from 'next/headers';
import crypto from 'crypto';

const SESSION_COOKIE_NAME = 'admin_session';

export async function POST() {
  try {
    const cookieStore = await cookies();
    const sessionToken = cookieStore.get(SESSION_COOKIE_NAME)?.value;

    if (sessionToken) {
      const tokenHash = crypto.createHash('sha256').update(sessionToken).digest('hex');

      // Delete session from database
      await supabaseServer
        .from('admin_sessions')
        .delete()
        .eq('token_hash', tokenHash);
    }

    // Clear cookie
    const res = NextResponse.json({ success: true });
    res.cookies.set(SESSION_COOKIE_NAME, '', {
      httpOnly: true,
      secure: process.env.NODE_ENV === 'production',
      sameSite: 'strict',
      maxAge: 0,
      path: '/',
    });

    return res;
  } catch (err: unknown) {
    console.error('[admin/logout] error:', err);
    return NextResponse.json({ error: 'Internal server error' }, { status: 500 });
  }
}