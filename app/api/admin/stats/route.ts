import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { requireAdmin } from '../auth';

export async function GET(req: Request) {
  const authFail = requireAdmin(req);
  if (authFail) return authFail;

  try {
    const { data: settings } = await supabaseServer
      .from('election_settings').select('current_phase').single();
    const phase = settings?.current_phase || 'SETUP';

    const { count: totalMembers } = await supabaseServer
      .from('members').select('*', { count: 'exact', head: true }).eq('is_active', true);
    const { count: votesCast } = await supabaseServer
      .from('tokens').select('*', { count: 'exact', head: true })
      .eq('type', 'VOTING').eq('is_used', true);

    const members = totalMembers || 0;
    const votes = votesCast || 0;

    // During active voting, return only total members (no live turnout — anti-coercion).
    if (phase === 'VOTING') {
      return NextResponse.json({ totalMembers: members, currentPhase: phase, liveTurnoutHidden: true });
    }

    return NextResponse.json({
      totalMembers: members,
      votesCast: votes,
      remainingVotes: Math.max(0, members - votes),
      turnoutPercentage: members > 0 ? parseFloat(((votes / members) * 100).toFixed(1)) : 0,
      currentPhase: phase,
    });
  } catch {
    return NextResponse.json({ error: 'Error fetching stats' }, { status: 500 });
  }
}
