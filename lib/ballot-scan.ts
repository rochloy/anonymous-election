import { validateScannedBallotId } from './ballot';

/**
 * Scan-time ballot validation for the mobile wizard (Record/Spoil).
 *
 * Two layers:
 * 1. Client-side format gate (validateScannedBallotId) — free and instant;
 *    rejects garbage, digital ballots, and malformed IDs before any request.
 * 2. Server-side existence + status (GET /api/admin/paper-ballot-status) —
 *    only accepts ballots actually created by this application, in a state
 *    the mode's confirm-time RPC would accept.
 *
 * The confirm-time RPCs remain the security boundary; this is UX-grade
 * defense-in-depth so the admin gets feedback at scan time.
 */

export type BallotScanResult =
  | { ok: true; ballotId: string; status: string }
  | { ok: false; error: string };

// Mirrors the RPC rules on anonymous_paper_blanks (the member-blind blank
// pool; migration_wave6_paper_severance.sql):
// submit_paper_vote → blank.status <> 'AVAILABLE' rejects ("already cast or voided")
// void_anonymous_paper_blank → blank.status <> 'AVAILABLE' rejects ("only AVAILABLE can be voided")
// Both modes therefore proceed only for AVAILABLE blanks.
const BLANK_STATUSES = {
  CAST: 'Already recorded',
  VOIDED: 'Already spoiled',
} as const;

export async function validateBallotScan(raw: string): Promise<BallotScanResult> {
  // 1. Format gate
  const format = validateScannedBallotId(raw);
  if (!format.valid || !format.ballotId) {
    return { ok: false, error: format.error || 'Invalid ballot QR payload' };
  }

  // 2. Existence + status
  let res: Response;
  try {
    res = await fetch(
      `/api/admin/paper-ballot-status?ballot_id=${encodeURIComponent(format.ballotId)}`
    );
  } catch {
    return { ok: false, error: 'Network error while validating ballot' };
  }
  if (res.status === 429) {
    return { ok: false, error: 'Too many requests — wait a moment and rescan' };
  }
  if (!res.ok) {
    return { ok: false, error: 'Could not validate the ballot — try again' };
  }
  const data = (await res.json().catch(() => null)) as
    | { exists?: boolean; status?: string | null }
    | null;
  if (!data || typeof data.exists !== 'boolean') {
    return { ok: false, error: 'Could not validate the ballot — try again' };
  }
  if (!data.exists) {
    return {
      ok: false,
      error: 'Not a valid paper ballot — not created by this application',
    };
  }

  const status = String(data.status ?? '');
  if (status === 'CAST') {
    return { ok: false, error: BLANK_STATUSES.CAST };
  }
  if (status === 'VOIDED') {
    return { ok: false, error: BLANK_STATUSES.VOIDED };
  }
  // Both confirm-time RPCs require an AVAILABLE blank; anything else is an
  // unexpected state — reject rather than let confirm fail opaquely.
  if (status !== 'AVAILABLE') {
    return { ok: false, error: 'Ballot is in an unexpected state — try again' };
  }

  return { ok: true, ballotId: format.ballotId, status };
}
