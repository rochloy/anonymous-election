type SanitizedError = {
  code?: string;
  message: string;
};

const EMAIL_PATTERN = /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/gi;
const PG_KEY_VALUE_PATTERN = /\(([^)]*)\)=\(([^)]*)\)/g;
const UUID_PATTERN = /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi;
// Ballot IDs / receipt codes (PAPER:…, DIGITAL:…, VC-…) and member codes (M-…).
const APP_ID_PATTERN = /\b(?:PAPER|DIGITAL)[:][^\s,;)]+|\bVC-[0-9a-f]+\b|\bM-[0-9a-f]{4,}\b/gi;
// Tokens, hashes, HMAC signatures.
const LONG_HEX_PATTERN = /\b[0-9a-f]{16,}\b/gi;
// Phone numbers and other long digit runs (spaces/dashes/parens allowed inside).
const LONG_NUMBER_PATTERN = /\+?\d[\d ().-]{6,}\d/g;
// Only plain SQLSTATE / PostgREST-style codes are logged.
const SAFE_CODE_PATTERN = /^[A-Za-z0-9_]{1,16}$/;

function redactMessage(message: string): string {
  // Truncate generously first (bounds regex work), redact, then truncate to the
  // final length — redaction never relies on the cut.
  let truncated = message.slice(0, 1000);
  // An opening quote whose closing quote was cut off by the pre-truncation
  // (odd quote count): redact everything after the last, unpaired quote.
  for (const q of ['"', "'"]) {
    if ((truncated.split(q).length - 1) % 2 === 1) {
      truncated = truncated.slice(0, truncated.lastIndexOf(q)) + q + '<redacted>';
    }
  }
  let redacted = truncated
    .replace(/"[^"]*"/g, '"<redacted>"')
    .replace(/'[^']*'/g, "'<redacted>'")
    .replace(EMAIL_PATTERN, '<email>')
    .replace(PG_KEY_VALUE_PATTERN, '(<redacted>)=(<redacted>)')
    .replace(UUID_PATTERN, '<uuid>')
    .replace(APP_ID_PATTERN, '<id>')
    .replace(LONG_HEX_PATTERN, '<hex>')
    .replace(LONG_NUMBER_PATTERN, '<number>');

  if (redacted.length > 200) {
    redacted = redacted.slice(0, 200);
  }

  return redacted;
}

export function sanitizeErrorForLog(err: unknown): SanitizedError {
  const code =
    typeof err === 'object' &&
    err !== null &&
    'code' in err &&
    typeof (err as { code?: unknown }).code === 'string' &&
    SAFE_CODE_PATTERN.test((err as { code: string }).code)
      ? (err as { code: string }).code
      : undefined;

  const rawMessage =
    err instanceof Error
      ? err.message
      : typeof err === 'object' &&
          err !== null &&
          'message' in err &&
          typeof (err as { message?: unknown }).message === 'string'
        ? (err as { message: string }).message
        : 'unknown error';

  return {
    code,
    message: redactMessage(rawMessage),
  };
}

export function logError(context: string, err: unknown): void {
  const { code, message } = sanitizeErrorForLog(err);
  console.error(`[${context}]`, { code, message });
}
