import { NextResponse } from 'next/server';

// Validate the admin secret from the x-admin-secret header.
// Returns null if valid, or a 401 NextResponse if invalid/missing.
export function requireAdmin(req: Request): NextResponse | null {
  const secret = req.headers.get('x-admin-secret');
  const expected = process.env.ADMIN_SECRET;
  if (!expected || secret !== expected) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }
  return null;
}
