import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import crypto from 'crypto';
import { validationError, notFoundError, apiError } from '@/lib/api-errors';

export async function POST(req: Request) {
  try {
    const { rawToken } = await req.json();
    if (!rawToken) return validationError('Token required');

    const tokenHash = crypto.createHash('sha256').update(rawToken).digest('hex');

    const { data: settings, error: settingsError } = await supabaseServer
      .from('election_settings').select('current_phase').single();
    if (settingsError || !settings) {
      return apiError(new Error('Election settings not found'));
    }
    const { data: tokenRecord, error } = await supabaseServer
      .from('tokens').select('id, type, is_used').eq('token_hash', tokenHash).single();

    if (error || !tokenRecord)
      return notFoundError('Invalid token.');
    if (tokenRecord.is_used)
      return NextResponse.json({ valid: false, message: 'This link has already been used.' }, { status: 410 });

    // Return minimal info - candidate list fetched separately when needed
    return NextResponse.json({ 
      valid: true, 
      tokenType: tokenRecord.type, 
      currentPhase: settings.current_phase 
    });
  } catch (err) {
    return apiError(err);
  }
}