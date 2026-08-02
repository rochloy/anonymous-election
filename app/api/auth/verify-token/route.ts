import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import crypto from 'crypto';

export async function POST(req: Request) {
  try {
    const { rawToken } = await req.json();
    if (!rawToken) return NextResponse.json({ error: 'Token required' }, { status: 400 });

    const tokenHash = crypto.createHash('sha256').update(rawToken).digest('hex');

    const { data: settings } = await supabaseServer
      .from('election_settings').select('*').single();
    const { data: tokenRecord, error } = await supabaseServer
      .from('tokens').select('id, type, is_used').eq('token_hash', tokenHash).single();

    if (error || !tokenRecord)
      return NextResponse.json({ valid: false, message: 'Invalid token.' }, { status: 404 });
    if (tokenRecord.is_used)
      return NextResponse.json({ valid: false, message: 'This link has already been used.' }, { status: 410 });

    let candidates: Array<{ id: string; full_name: string; statement: string | null; photo_url: string | null }> = [];
    if (tokenRecord.type === 'VOTING' && settings.current_phase === 'VOTING') {
      const { data } = await supabaseServer
        .from('candidates').select('id, full_name, statement, photo_url').eq('is_active', true);
      candidates = data || [];
    }

    return NextResponse.json({ valid: true, tokenType: tokenRecord.type, currentPhase: settings.current_phase, candidates });
  } catch {
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}
