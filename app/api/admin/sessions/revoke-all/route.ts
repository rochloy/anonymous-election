import { NextResponse } from 'next/server';
import { requireAdminWithCsrf, CSRF_COOKIE_NAME, SESSION_COOKIE_NAME } from '../../auth';
import { supabaseServer } from '@/lib/supabase-server';

export async function POST(req: Request) {
  const authFail = await requireAdminWithCsrf(req);
  if (authFail) return authFail;

  try {
    const { data, error } = await supabaseServer
      .from('admin_sessions')
      .update({ revoked_at: new Date().toISOString(), revoke_reason: 'revoke_all', token_hash: null })
      .is('revoked_at', null)
      .select('id');

    if (error) {
      return NextResponse.json({ error: 'Failed to revoke sessions' }, { status: 500 });
    }

    const res = NextResponse.json({ success: true, revoked: Array.isArray(data) ? data.length : null });
    res.cookies.set(SESSION_COOKIE_NAME, '', {
      httpOnly: true,
      secure: process.env.NODE_ENV === 'production',
      sameSite: 'strict',
      maxAge: 0,
      path: '/',
    });
    res.cookies.set(CSRF_COOKIE_NAME, '', {
      httpOnly: false,
      secure: process.env.NODE_ENV === 'production',
      sameSite: 'strict',
      maxAge: 0,
      path: '/',
    });

    return res;
  } catch (err: unknown) {
    console.error('[admin/sessions/revoke-all] error:', err);
    return NextResponse.json({ error: 'Internal server error' }, { status: 500 });
  }
}
