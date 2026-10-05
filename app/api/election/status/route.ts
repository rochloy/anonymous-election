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
      .from('election_settings')
      .select(
        'current_phase, nomination_start, nomination_end, voting_start, voting_end, allow_write_ins, max_nominees_per_member'
      )
      .eq('id', 1)
      .single();

    if (error || !data) {
      return NextResponse.json({ phase: 'SETUP' });
    }

    // Map current_phase -> phase for frontend compatibility
    return NextResponse.json({
      ...data,
      phase: data.current_phase,
    });
  } catch (err) {
    logError('election/status error', err);
    return NextResponse.json({ phase: 'SETUP' });
  }
}
