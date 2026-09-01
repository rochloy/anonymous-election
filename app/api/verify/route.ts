import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';

type VerifyResult = {
  found: true;
  channel: string;
  candidate_name?: string;
  cast_date: string;
  receipt_match?: boolean;
};

export async function GET(req: Request) {
  try {
    const { searchParams } = new URL(req.url);
    const ballotId = searchParams.get('ballot_id')?.trim();
    const receiptCode = searchParams.get('receipt_code')?.trim().toUpperCase();

    if (!ballotId) {
      return NextResponse.json({ error: 'ballot_id is required' }, { status: 400 });
    }

    // Look up ballot by ballot_id
    const { data: ballot, error } = await supabaseServer
      .from('ballots')
      .select('ballot_id, candidate_id, receipt_code, channel, cast_date')
      .eq('ballot_id', ballotId)
      .single();

    if (error || !ballot) {
      return NextResponse.json({ found: false });
    }

    const { data: settings } = await supabaseServer
      .from('election_settings')
      .select('current_phase')
      .eq('id', 1)
      .single();

    const isVotingOpen = settings?.current_phase === 'VOTING';

    const result: VerifyResult = {
      found: true,
      channel: ballot.channel,
      cast_date: ballot.cast_date,
    };

    if (!isVotingOpen) {
      // Only reveal candidate choice after voting is closed
      const { data: candidate } = await supabaseServer
        .from('candidates')
        .select('full_name')
        .eq('id', ballot.candidate_id)
        .single();

      result.candidate_name = candidate?.full_name || 'Unknown';
    }

    // If receipt_code provided, verify it matches
    if (receiptCode) {
      result.receipt_match = ballot.receipt_code.toUpperCase() === receiptCode;
    }

    return NextResponse.json(result);
  } catch {
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}
