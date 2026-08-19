import { NextResponse } from 'next/server';
import QRCode from 'qrcode';
import { supabaseServer } from '@/lib/supabase-server';
import { requireAdmin } from '../auth';

export async function GET(req: Request) {
  const authFail = await requireAdmin();
  if (authFail) return authFail;

  try {
    const { searchParams } = new URL(req.url);
    const query = searchParams.get('q')?.trim() || '';

    if (query.length < 2) {
      return NextResponse.json({ members: [] });
    }

    const { data, error } = await supabaseServer
      .from('members')
      .select('id, member_code, full_name, email, phone, is_active')
      .eq('is_active', true)
      .ilike('full_name', `%${query}%`)
      .limit(20);

    if (error) {
      return NextResponse.json({ error: error.message }, { status: 500 });
    }

    // For each member, check voting status
    const membersWithStatus = await Promise.all(
      (data || []).map(async (m) => {
        // Check digital vote
        const { data: token } = await supabaseServer
          .from('tokens')
          .select('is_used')
          .eq('member_id', m.id)
          .eq('type', 'VOTING')
          .maybeSingle();

        // Check paper ballot
        const { data: paper, error: paperErr } = await supabaseServer
          .from('paper_ballots')
          .select('status, ballot_id, short_code, issued_at, issued_to_voter_at, voted_at')
          .eq('member_id', m.id)
          .in('status', ['ISSUED', 'ISSUED_TO_VOTER', 'VOTED'])
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

        let status: 'ELIGIBLE' | 'DIGITAL_VOTED' | 'PAPER_ISSUED' | 'PAPER_VOTED' = 'ELIGIBLE';
        if (token?.is_used) status = 'DIGITAL_VOTED';
        else if (paper?.status === 'VOTED') status = 'PAPER_VOTED';
        else if (paper?.status === 'ISSUED' || paper?.status === 'ISSUED_TO_VOTER')
          status = 'PAPER_ISSUED';

        let paperBallotObj = null;
        if (paper) {
          let qrSvg = '';
          let qrDataUrl = '';
          try {
            // Encode as URL so native phone cameras recognize the QR as actionable.
            const baseUrl = process.env.APP_BASE_URL || 'http://localhost:3000';
            const qrPayload = `${baseUrl}/verify?ballot_id=${encodeURIComponent(paper.ballot_id)}`;
            qrDataUrl = await QRCode.toDataURL(qrPayload, {
              width: 512,
              margin: 2,
              errorCorrectionLevel: 'M',
              color: { dark: '#000000', light: '#ffffff' },
            });
            qrSvg = await QRCode.toString(qrPayload, {
              type: 'svg',
              errorCorrectionLevel: 'M',
              margin: 2,
              width: 512,
              color: { dark: '#000000', light: '#ffffff' },
            });
          } catch {
            // fallback empty
          }
          paperBallotObj = {
            ballotId: paper.ballot_id,
            shortCode: paper.short_code,
            qrDataUrl,
            qrSvg,
            issuedAt: paper.issued_to_voter_at || paper.issued_at,
            votedAt: paper.voted_at,
          };
        }

        return {
          ...m,
          votingStatus: status,
          paperBallot: paperBallotObj,
        };
      })
    );

    return NextResponse.json({ members: membersWithStatus });
  } catch {
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}
