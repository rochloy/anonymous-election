import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { requireAdmin } from '../auth';

// Election-progress reporting for the admin dashboard (Reporting tab).
// Available in VOTING/VOTING_CLOSED/COMPLETED phases; on-demand fetch.
// All metrics are aggregate counts or candidate-level tallies — no member
// identity is exposed (anonymity invariant).
export async function GET() {
  const authFail = await requireAdmin();
  if (authFail) return authFail;

  try {
    const { data: settings, error: settingsError } = await supabaseServer
      .from('election_settings')
      .select('current_phase')
      .eq('id', 1)
      .single();

    if (settingsError) {
      return NextResponse.json({ error: settingsError.message }, { status: 500 });
    }

    const phase = settings?.current_phase || 'SETUP';
    const available = ['VOTING', 'VOTING_CLOSED', 'COMPLETED'].includes(phase);

    if (!available) {
      return NextResponse.json({ available: false, phase });
    }

    const { count: checkedInCount, error: checkInError } = await supabaseServer
      .from('participation_audit')
      .select('id', { count: 'exact', head: true })
      .eq('action', 'PAPER_CHECK_IN');

    const { count: paperRecordedCount, error: paperError } = await supabaseServer
      .from('anonymous_paper_blanks')
      .select('ballot_id', { count: 'exact', head: true })
      .eq('status', 'CAST');

    const { count: digitalVoteCount, error: digitalError } = await supabaseServer
      .from('ballots')
      .select('ballot_id', { count: 'exact', head: true })
      .eq('channel', 'DIGITAL');

    const { data: ballots, error: ballotsError } = await supabaseServer
      .from('ballots')
      .select('candidate_id');

    const firstError = checkInError || paperError || digitalError || ballotsError;
    if (firstError) {
      return NextResponse.json({ error: firstError.message }, { status: 500 });
    }

    const { data: candidates, error: candidatesError } = await supabaseServer
      .from('candidates')
      .select('id, full_name')
      .eq('is_active', true);

    if (candidatesError) {
      return NextResponse.json({ error: candidatesError.message }, { status: 500 });
    }

    const totalVoteCount = ballots?.length || 0;
    const counts: Record<string, number> = {};
    ballots?.forEach((b: { candidate_id: string }) => {
      counts[b.candidate_id] = (counts[b.candidate_id] || 0) + 1;
    });

    const results = (candidates || [])
      .map((c: { id: string; full_name: string }) => ({
        id: c.id,
        full_name: c.full_name,
        votes: counts[c.id] || 0,
        percentage:
          totalVoteCount > 0
            ? parseFloat((((counts[c.id] || 0) / totalVoteCount) * 100).toFixed(1))
            : 0,
      }))
      .sort((a: { votes: number }, b: { votes: number }) => b.votes - a.votes);

    return NextResponse.json({
      available: true,
      phase,
      checkedInCount: checkedInCount || 0,
      paperRecordedCount: paperRecordedCount || 0,
      digitalVoteCount: digitalVoteCount || 0,
      totalVoteCount,
      results,
    });
  } catch {
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}