import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import crypto from 'crypto';
import { validationError, notFoundError } from '@/lib/api-errors';
import { logError } from '@/lib/safe-log';

export async function POST(req: Request) {
  try {
    const { rawToken } = await req.json();
    if (!rawToken) return validationError('Token required');

    const tokenHash = crypto.createHash('sha256').update(rawToken).digest('hex');

    const { data: settings, error: settingsError } = await supabaseServer
      .from('election_settings').select('current_phase').single();
    if (settingsError || !settings) {
      logError('auth/verify-token election settings missing', settingsError ?? new Error('Election settings not found'));
      return NextResponse.json({ error: 'Server error' }, { status: 500 });
    }
    const { data: tokenRecord, error } = await supabaseServer
      .from('tokens').select('id, type, is_used, expires_at, voided_at').eq('token_hash', tokenHash).single();

    if (error || !tokenRecord)
      return notFoundError('Invalid token.');
    if (tokenRecord.voided_at)
      return notFoundError('Invalid token.');
    if (new Date(tokenRecord.expires_at) < new Date()) {
      return notFoundError('Invalid token.');
    }
    if (tokenRecord.is_used)
      return NextResponse.json({ valid: false, message: 'This link has already been used.' }, { status: 410 });

    // Return minimal info - candidate list fetched separately when needed
    return NextResponse.json({ 
      valid: true, 
      tokenType: tokenRecord.type, 
      currentPhase: settings.current_phase 
    });
  } catch (err) {
    logError('auth/verify-token route error', err);
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}
