import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';

export async function GET(req: Request) {
  try {
    const { searchParams } = new URL(req.url);
    const receiptCode = searchParams.get('receipt')?.trim().toUpperCase();

    const { data: settings } = await supabaseServer
      .from('election_settings').select('current_phase').single();
    const phase = settings?.current_phase || 'SETUP';
    const isPublished = ['VOTING_CLOSED', 'COMPLETED'].includes(phase);

    if (!isPublished) {
      return NextResponse.json({ published: false, phase });
    }

    const { data: candidates } = await supabaseServer
      .from('candidates').select('id, full_name, statement, photo_url').eq('is_active', true);
    const { data: ballots } = await supabaseServer
      .from('ballots').select('candidate_id, receipt_code, channel');

    const totalVotes = ballots?.length || 0;
    const counts: Record<string, number> = {};
    ballots?.forEach((b: { candidate_id: string }) => { counts[b.candidate_id] = (counts[b.candidate_id] || 0) + 1; });

    const results = (candidates || [])
      .map((c: { id: string; full_name: string; statement: string | null; photo_url: string | null }) => ({
        ...c,
        votes: counts[c.id] || 0,
        percentage: totalVotes > 0 ? parseFloat((((counts[c.id] || 0) / totalVotes) * 100).toFixed(1)) : 0,
      }))
      .sort((a: { votes: number }, b: { votes: number }) => b.votes - a.votes);

    let receiptStatus = null;
    if (receiptCode) {
      const match = ballots?.find((b: { receipt_code: string }) => b.receipt_code.toUpperCase() === receiptCode);
      receiptStatus = { searchedCode: receiptCode, found: !!match };
    }

    return NextResponse.json({ published: true, phase, totalVotes, results, receiptStatus });
  } catch {
    return NextResponse.json({ error: 'Error fetching results' }, { status: 500 });
  }
}
