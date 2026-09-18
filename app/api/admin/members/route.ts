import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { requireAdmin } from '../auth';
import { rateLimitError } from '@/lib/api-errors';

const SEARCH_RATE_LIMIT_WINDOW = 60; // seconds
const SEARCH_RATE_LIMIT_MAX = 30; // requests per window

export async function GET(req: Request) {
  const authFail = await requireAdmin();
  if (authFail) return authFail;

  // Rate limiting for search
  const ip = req.headers.get('x-forwarded-for')?.split(',')[0] || 'unknown';
  try {
    const { data: rateLimitData, error: rlError } = await supabaseServer.rpc('check_rate_limit', {
      p_identifier: `search:${ip}`,
      p_window_seconds: SEARCH_RATE_LIMIT_WINDOW,
      p_max_requests: SEARCH_RATE_LIMIT_MAX,
    });

    if (rlError) {
      console.error('[members/search] Rate limit RPC error:', rlError);
    } else if (!rateLimitData?.allowed) {
      return rateLimitError(SEARCH_RATE_LIMIT_WINDOW);
    }
  } catch (err) {
    console.error('[members/search] Rate limit check failed:', err);
  }

  try {
    await supabaseServer.rpc('sweep_expired_digital_reservations');

    const { searchParams } = new URL(req.url);
    const query = searchParams.get('q')?.trim() || '';
    const mode = searchParams.get('mode');
    const isAssignMode = mode === 'assign';

    if (query.length < 2) {
      return NextResponse.json({ members: [] });
    }

    const { data, error } = await supabaseServer
      .from('members')
      .select('id, member_code, full_name, email, phone, is_active, voting_eligible, eligibility_reason, eligibility_source')
      .eq('is_active', true)
      .ilike('full_name', `%${query}%`)
      .limit(20);

    if (error) {
      return NextResponse.json({ error: error.message }, { status: 500 });
    }

    // For each member, check voting status
    const membersWithStatus = await Promise.all(
      (data || []).map(async (m) => {
        // Check voting entitlements / digital state
        const { data: tokens } = await supabaseServer
          .from('tokens')
          .select('id, type, is_used, channel_sent, reserved_channel, expires_at')
          .eq('member_id', m.id)
          .is('voided_at', null);
        const votingTokens = (tokens || []).filter((t) => t.type === 'VOTING');

        // Check paper ballot
        const { data: paper, error: paperErr } = await supabaseServer
          .from('paper_ballots')
          .select('status, short_code, checked_in_at, checked_in_date')
          .eq('member_id', m.id)
          .in('status', ['ISSUED', 'ISSUED_TO_VOTER', 'VOTED'])
          .order('created_at', { ascending: false })
          .limit(1)
          .maybeSingle();

        // A real DB/permission error here must NOT be silently treated as
        // "no ballot" — that would wrongly mark an already-issued member as
        // ELIGIBLE. Surface it so the failure is visible (see
        // migration_fix_service_role_grants.sql for the historical cause).
        if (paperErr) {
          console.error(
            `[members] paper_ballots query failed for ${m.id}: ${paperErr.code} ${paperErr.message}`
          );
          throw new Error(`paper_ballots query failed: ${paperErr.message}`);
        }

        let status:
          | 'INELIGIBLE'
          | 'PAPER_VOTED'
          | 'DIGITAL_VOTED'
          | 'PAPER_ISSUED'
          | 'DIGITAL_RESERVED'
          | 'DIGITAL_ISSUED'
          | 'ENTITLED'
          | 'NO_ENTITLEMENT' = 'NO_ENTITLEMENT';

        const hasDigitalVoted = votingTokens.some(
          (t) => t.is_used === true && t.channel_sent === 'DIGITAL'
        );
        const hasDigitalReserved = votingTokens.some(
          (t) => t.is_used === false && t.reserved_channel === 'DIGITAL'
        );
        const hasDigitalIssued = votingTokens.some(
          (t) =>
            t.is_used === false &&
            t.channel_sent === 'EMAIL' &&
            t.reserved_channel !== 'DIGITAL'
        );
        const hasEntitled = votingTokens.some(
          (t) =>
            t.is_used === false &&
            t.channel_sent !== 'EMAIL' &&
            t.reserved_channel !== 'DIGITAL'
        );

        if (m.voting_eligible !== true) status = 'INELIGIBLE';
        else if (paper?.status === 'VOTED') status = 'PAPER_VOTED';
        else if (hasDigitalVoted) status = 'DIGITAL_VOTED';
        else if (paper?.status === 'ISSUED' || paper?.status === 'ISSUED_TO_VOTER')
          status = 'PAPER_ISSUED';
        else if (hasDigitalReserved) status = 'DIGITAL_RESERVED';
        else if (hasDigitalIssued) status = 'DIGITAL_ISSUED';
        else if (hasEntitled) status = 'ENTITLED';
        else status = 'NO_ENTITLEMENT';

        const paperCheckIn =
          paper && !isAssignMode
            ? {
                shortCode: paper.short_code,
                status: paper.status,
                checkedInAt: paper.checked_in_at ?? null,
                checkedInDate: paper.checked_in_date ?? null,
              }
            : null;

        if (isAssignMode) {
          return {
            id: m.id,
            member_code: m.member_code,
            full_name: m.full_name,
            votingStatus: status,
          };
        }

        return {
          ...m,
          votingStatus: status,
          tokens: tokens || [],
          paperCheckIn,
        };
      })
    );

    return NextResponse.json({ members: membersWithStatus });
  } catch (err: unknown) {
    console.error('[members/search] GET failed:', err);
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}
