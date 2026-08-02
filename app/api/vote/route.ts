import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import crypto from 'crypto';

export async function POST(req: Request) {
  try {
    const { rawToken, candidateId } = await req.json();
    if (!rawToken || !candidateId)
      return NextResponse.json({ error: 'Missing input' }, { status: 400 });

    const tokenHash = crypto.createHash('sha256').update(rawToken).digest('hex');

    // RPC generates the receipt code internally with CSPRNG + retry.
    const { data, error } = await supabaseServer.rpc('submit_anonymous_vote', {
      p_token_hash: tokenHash,
      p_candidate_id: candidateId,
    });

    if (error || !data || !data[0]?.success) {
      return NextResponse.json({ error: data?.[0]?.message || 'Vote failed.' }, { status: 400 });
    }

    return NextResponse.json({ success: true, receiptCode: data[0].receipt_code });
  } catch {
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}
