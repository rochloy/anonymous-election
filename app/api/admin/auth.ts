import { NextResponse } from 'next/server';
import { cookies } from 'next/headers';
import { supabaseServer } from '@/lib/supabase-server';
import crypto from 'crypto';

export const SESSION_COOKIE_NAME = 'admin_session';
export const CSRF_COOKIE_NAME = 'admin_csrf';
export const CSRF_HEADER_NAME = 'x-csrf-token';
const DESKTOP_IDLE_MS = 10 * 60 * 1000;
const DESKTOP_ABSOLUTE_MS = 4 * 60 * 60 * 1000;

type Admin401Reason = 'idle_expired' | 'absolute_expired' | 'unauthorized' | 'revoked';

function adminUnauthorized(reason: Admin401Reason, error = 'Unauthorized'): NextResponse {
  return NextResponse.json({ error, reason }, { status: 401 });
}

function toTokenHash(sessionToken: string): string {
  return crypto.createHash('sha256').update(sessionToken).digest('hex');
}

function computeAbsoluteExpiry(createdAt: string): Date {
  return new Date(new Date(createdAt).getTime() + DESKTOP_ABSOLUTE_MS);
}

async function revokeSessionByTokenHash(tokenHash: string, reason: string): Promise<void> {
  await supabaseServer
    .from('admin_sessions')
    .update({ revoked_at: new Date().toISOString(), revoke_reason: reason })
    .eq('token_hash', tokenHash);
}

async function bumpDesktopIdle(tokenHash: string, absoluteExpiresAt: Date): Promise<void> {
  const now = new Date();
  const newIdle = new Date(Math.min(now.getTime() + DESKTOP_IDLE_MS, absoluteExpiresAt.getTime()));
  await supabaseServer
    .from('admin_sessions')
    .update({ expires_at: newIdle.toISOString() })
    .eq('token_hash', tokenHash)
    .is('revoked_at', null)
    .gte('expires_at', now.toISOString());
}

// Validate the admin session from the HttpOnly cookie.
// Returns null if valid, or a 401 NextResponse if invalid/missing/expired.
export async function requireAdmin(options?: { bumpIdle?: boolean }): Promise<NextResponse | null> {
  const bumpIdle = options?.bumpIdle ?? false;
  const cookieStore = await cookies();
  const sessionToken = cookieStore.get(SESSION_COOKIE_NAME)?.value;

  if (!sessionToken) {
    return adminUnauthorized('unauthorized');
  }

  const tokenHash = toTokenHash(sessionToken);
  const now = new Date();

  // Verify session exists and is not expired
  const { data: session, error } = await supabaseServer
    .from('admin_sessions')
    .select('created_at, expires_at, revoked_at, revoke_reason, scope')
    .eq('token_hash', tokenHash)
    .single();

  if (error || !session) {
    return adminUnauthorized('unauthorized');
  }

  if (session.revoked_at) {
    if (session.revoke_reason === 'absolute_expired') return adminUnauthorized('absolute_expired', 'Session expired');
    if (session.revoke_reason === 'idle_expired') return adminUnauthorized('idle_expired', 'Session expired');
    return adminUnauthorized('revoked');
  }

  const expiresAt = new Date(session.expires_at);
  if (session.scope === 'mobile') {
    if (now > expiresAt) {
      await revokeSessionByTokenHash(tokenHash, 'absolute_expired');
      return adminUnauthorized('absolute_expired', 'Session expired');
    }
    return null;
  }

  const absoluteExpiresAt = computeAbsoluteExpiry(session.created_at);
  if (now > absoluteExpiresAt) {
    await revokeSessionByTokenHash(tokenHash, 'absolute_expired');
    return adminUnauthorized('absolute_expired', 'Session expired');
  }

  if (now > expiresAt) {
    await revokeSessionByTokenHash(tokenHash, 'idle_expired');
    return adminUnauthorized('idle_expired', 'Session expired');
  }

  if (bumpIdle) {
    await bumpDesktopIdle(tokenHash, absoluteExpiresAt);
  }

  return null;
}

// Validate CSRF token for state-changing requests
// Returns null if valid, or a 403 NextResponse if invalid/missing
export async function requireCsrf(req: Request): Promise<NextResponse | null> {
  const cookieStore = await cookies();
  const csrfCookie = cookieStore.get(CSRF_COOKIE_NAME)?.value;
  const csrfHeader = req.headers.get(CSRF_HEADER_NAME);

  if (!csrfCookie || !csrfHeader) {
    return NextResponse.json({ error: 'CSRF token required' }, { status: 403 });
  }

  if (csrfCookie !== csrfHeader) {
    return NextResponse.json({ error: 'Invalid CSRF token' }, { status: 403 });
  }

  return null;
}

// Combined auth + CSRF validation for state-changing requests
export async function requireAdminWithCsrf(req: Request): Promise<NextResponse | null> {
  const authFail = await requireAdmin({ bumpIdle: false });
  if (authFail) return authFail;

  const csrfFail = await requireCsrf(req);
  if (csrfFail) return csrfFail;

  const cookieStore = await cookies();
  const sessionToken = cookieStore.get(SESSION_COOKIE_NAME)?.value;
  if (!sessionToken) return adminUnauthorized('unauthorized');

  const tokenHash = toTokenHash(sessionToken);
  const { data: session } = await supabaseServer
    .from('admin_sessions')
    .select('created_at, expires_at, revoked_at, scope')
    .eq('token_hash', tokenHash)
    .maybeSingle();

  if (session && !session.revoked_at && session.scope === 'desktop') {
    const absoluteExpiresAt = computeAbsoluteExpiry(session.created_at);
    await bumpDesktopIdle(tokenHash, absoluteExpiresAt);
  }

  return null;
}

// Get admin session info for audit logging
// Returns session ID and metadata if valid, null otherwise
export async function getAdminSession(): Promise<{ id: string; ip_address: string | null; user_agent: string | null; expires_at: string | null; scope: 'desktop' | 'mobile' } | null> {
  const cookieStore = await cookies();
  const sessionToken = cookieStore.get(SESSION_COOKIE_NAME)?.value;

  if (!sessionToken) return null;

  const tokenHash = toTokenHash(sessionToken);

  const { data: session, error } = await supabaseServer
    .from('admin_sessions')
    .select('id, ip_address, user_agent, created_at, expires_at, revoked_at, scope')
    .eq('token_hash', tokenHash)
    .single();

  if (error || !session) return null;
  if (session.revoked_at) return null;

  const now = new Date();
  const expiresAt = new Date(session.expires_at);
  if (session.scope === 'mobile') {
    if (now > expiresAt) {
      await revokeSessionByTokenHash(tokenHash, 'absolute_expired');
      return null;
    }
  } else {
    const absoluteExpiresAt = computeAbsoluteExpiry(session.created_at);
    if (now > absoluteExpiresAt) {
      await revokeSessionByTokenHash(tokenHash, 'absolute_expired');
      return null;
    }
    if (now > expiresAt) {
      await revokeSessionByTokenHash(tokenHash, 'idle_expired');
      return null;
    }
  }

  return {
    id: session.id,
    ip_address: session.ip_address,
    user_agent: session.user_agent,
    expires_at: session.expires_at,
    scope: session.scope,
  };
}

// Generate CSRF token and set cookie
export function generateCsrfToken(): string {
  return crypto.randomBytes(32).toString('hex');
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
