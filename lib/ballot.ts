const MAX_SCANNED_BALLOT_LENGTH = 400;
const PAPER_BALLOT_ID_REGEX = /^PAPER:[A-Fa-f0-9]{64}\.[A-Fa-f0-9]{64}$/;

/**
 * Examples:
 * - https://example.com/verify?ballot_id=PAPER%3A<64hex>.<64hexsig> -> PAPER:<64hex>.<64hexsig>
 * - PAPER:<64hex>.<64hexsig> -> PAPER:<64hex>.<64hexsig>
 */
export function extractBallotId(raw: string): string | null {
  if (typeof raw !== 'string') return null;

  const trimmed = raw.trim();
  if (!trimmed) return null;

  if (/^https?:\/\//i.test(trimmed)) {
    try {
      const url = new URL(trimmed);
      const id = url.searchParams.get('ballot_id');
      if (!id) return null;
      const decoded = decodeURIComponent(id).trim();
      return decoded || null;
    } catch {
      return null;
    }
  }

  return trimmed;
}

export function validateScannedBallotId(raw: string): { valid: boolean; ballotId: string | null; error?: string } {
  const ballotId = extractBallotId(raw);

  if (!ballotId) {
    return { valid: false, ballotId: null, error: 'Invalid or empty ballot QR payload' };
  }

  if (ballotId.length > MAX_SCANNED_BALLOT_LENGTH) {
    return { valid: false, ballotId: null, error: 'Ballot ID is too long' };
  }

  if (ballotId.startsWith('DIGITAL:')) {
    return { valid: false, ballotId: null, error: 'Digital ballot IDs cannot be assigned as paper ballots' };
  }

  if (!ballotId.startsWith('PAPER:')) {
    return { valid: false, ballotId: null, error: 'Ballot ID must start with PAPER:' };
  }

  if (!PAPER_BALLOT_ID_REGEX.test(ballotId)) {
    return { valid: false, ballotId: null, error: 'Malformed paper ballot ID' };
  }

  return { valid: true, ballotId };
}
