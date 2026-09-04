import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import crypto from 'crypto';
import { rateLimitError, validationError } from '@/lib/api-errors';
import {
  isValidRawToken,
  isValidUuid,
  NOMINATION_LIMITS,
} from '@/lib/input-validation';

const WINDOW = 60;
const MAX = 5;

export async function POST(req: Request) {
  const ip = req.headers.get('x-forwarded-for')?.split(',')[0] || 'unknown';
  try {
    const { data: rl, error: rlError } = await supabaseServer.rpc('check_rate_limit', {
      p_identifier: `nominate:${ip}`,
      p_window_seconds: WINDOW,
      p_max_requests: MAX,
    });
    if (rlError) {
      console.error('[nominate] rate limit RPC error:', rlError);
      return NextResponse.json({ error: 'Rate limit unavailable' }, { status: 503 });
    } else if (!rl?.allowed) {
      return rateLimitError(WINDOW);
    }
  } catch (err) {
    console.error('[nominate] rate limit failed:', err);
    return NextResponse.json({ error: 'Rate limit unavailable' }, { status: 503 });
  }

  try {
    const { rawToken, nominees } = await req.json();
    if (!isValidRawToken(rawToken) || !Array.isArray(nominees) || nominees.length === 0) {
      return validationError('Missing input');
    }

    // SEC-04: defense-in-depth boundary validation (DB re-enforces these caps).
    // Absolute nominee ceiling; the DB checks the configured per-member max too.
    if (nominees.length > NOMINATION_LIMITS.maxNominees) {
      return validationError(
        `At most ${NOMINATION_LIMITS.maxNominees} nominee(s) allowed.`
      );
    }
    for (const n of nominees) {
      if (n === null || typeof n !== 'object') {
        return validationError('Malformed nominee.');
      }
      const { nominee_member_id, nominee_name, reason } = n as {
        nominee_member_id?: unknown;
        nominee_name?: unknown;
        reason?: unknown;
      };
      // Reject malformed IDs before they reach the Postgres ::UUID cast (avoids 500s).
      if (
        nominee_member_id !== undefined &&
        nominee_member_id !== null &&
        nominee_member_id !== '' &&
        !isValidUuid(nominee_member_id)
      ) {
        return validationError('Invalid nominee id.');
      }
      if (
        typeof nominee_name === 'string' &&
        nominee_name.length > NOMINATION_LIMITS.nomineeNameMax
      ) {
        return validationError(
          `Nominee name exceeds ${NOMINATION_LIMITS.nomineeNameMax} characters.`
        );
      }
      if (
        typeof reason === 'string' &&
        reason.length > NOMINATION_LIMITS.reasonMax
      ) {
        return validationError(
          `Reason exceeds ${NOMINATION_LIMITS.reasonMax} characters.`
        );
      }
    }

    const tokenHash = crypto.createHash('sha256').update(rawToken).digest('hex');

    let { data, error } = await supabaseServer.rpc('submit_nomination', {
      p_token_hash: tokenHash,
      p_nominees: nominees,
    });

    if (error) {
      try {
        const res = await supabaseServer.schema('private').rpc('submit_nomination', {
          p_token_hash: tokenHash,
          p_nominees: nominees,
        });
        if (!res.error && res.data) {
          data = res.data;
          error = null;
        }
      } catch {
        // keep original error
      }
    }

    if (error || !data || !data[0]?.success) {
      return NextResponse.json(
        { error: data?.[0]?.message || 'Nomination failed.' },
        { status: 400 }
      );
    }

    return NextResponse.json({ success: true, insertedCount: data[0].inserted_count });
  } catch {
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}
