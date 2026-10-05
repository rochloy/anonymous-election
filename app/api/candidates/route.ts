import { createClient } from '@supabase/supabase-js';
import { NextResponse } from 'next/server';
import { logError } from '@/lib/safe-log';

function getSupabaseServer() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (!url || !key) {
    throw new Error('Missing Supabase env vars');
  }

  return createClient(url, key, { auth: { persistSession: false } });
}

export async function GET() {
  try {
    const supabase = getSupabaseServer();

    const { data, error } = await supabase
      .from('candidates')
      .select('id, full_name, statement, photo_url')
      .eq('is_active', true)
      .order('created_at', { ascending: true });

    if (error) {
      logError('candidates query failed', error);
      return NextResponse.json({ error: 'Server error' }, { status: 500 });
    }

    return NextResponse.json(data || []);
  } catch (err) {
    logError('candidates API error', err);
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}
