import { NextResponse } from 'next/server';
import { cookies } from 'next/headers';
import { supabaseServer } from '@/lib/supabase-server';
import crypto from 'crypto';

const SESSION_COOKIE_NAME = 'admin_session';

// Validate the admin session from the HttpOnly cookie.
// Returns null if valid, or a 401 NextResponse if invalid/missing/expired.
export async function requireAdmin(): Promise<NextResponse | null> {
  const cookieStore = await cookies();
  const sessionToken = cookieStore.get(SESSION_COOKIE_NAME)?.value;

  if (!sessionToken) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }

  const tokenHash = crypto.createHash('sha256').update(sessionToken).digest('hex');

  // Verify session exists and is not expired
  const { data: session, error } = await supabaseServer
    .from('admin_sessions')
    .select('expires_at')
    .eq('token_hash', tokenHash)
    .single();

  if (error || !session) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }

  if (new Date(session.expires_at) < new Date()) {
    // Session expired - delete it
    await supabaseServer.from('admin_sessions').delete().eq('token_hash', tokenHash);
    return NextResponse.json({ error: 'Session expired' }, { status: 401 });
  }

  return null;
}

// Get admin session info for audit logging
// Returns session ID and metadata if valid, null otherwise
export async function getAdminSession(): Promise<{ id: string; ip_address: string | null; user_agent: string | null } | null> {
  const cookieStore = await cookies();
  const sessionToken = cookieStore.get(SESSION_COOKIE_NAME)?.value;

  if (!sessionToken) return null;

  const tokenHash = crypto.createHash('sha256').update(sessionToken).digest('hex');

  const { data: session, error } = await supabaseServer
    .from('admin_sessions')
    .select('id, ip_address, user_agent, expires_at')
    .eq('token_hash', tokenHash)
    .single();

  if (error || !session) return null;
  if (new Date(session.expires_at) < new Date()) return null;

  return {
    id: session.id,
    ip_address: session.ip_address,
    user_agent: session.user_agent,
  };
}

// Legacy function for backward compatibility during transition
// Validates the admin secret from the x-admin-secret header.
// Returns null if valid, or a 401 NextResponse if invalid/missing.
export function requireAdminLegacy(req: Request): NextResponse | null {
  const secret = req.headers.get('x-admin-secret');
  const expected = process.env.ADMIN_SECRET;
  if (!expected || secret !== expected) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }
  return null;
}