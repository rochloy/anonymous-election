import { NextResponse } from 'next/server';
import { requireAdmin } from '../auth';

export async function GET() {
  const authFail = await requireAdmin();
  if (authFail) return authFail;

  return NextResponse.json({ authenticated: true });
}