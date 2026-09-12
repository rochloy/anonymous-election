import { NextResponse } from 'next/server';
import { getAdminSession, requireAdmin } from '../auth';

export async function GET() {
  const authFail = await requireAdmin();
  if (authFail) return authFail;

  const session = await getAdminSession();

  return NextResponse.json({
    authenticated: true,
    expiresAt: session?.expires_at ? new Date(session.expires_at).toISOString() : null,
    scope: session?.scope ?? 'desktop',
  });
}
