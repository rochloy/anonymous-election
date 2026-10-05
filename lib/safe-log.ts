type SanitizedError = {
  code?: string;
  message: string;
};

const EMAIL_PATTERN = /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/gi;
const PG_KEY_VALUE_PATTERN = /\(([^)]*)\)=\(([^)]*)\)/g;

function redactMessage(message: string): string {
  let redacted = message
    .replace(/"[^"]*"/g, '"<redacted>"')
    .replace(/'[^']*'/g, "'<redacted>'")
    .replace(EMAIL_PATTERN, '<email>')
    .replace(PG_KEY_VALUE_PATTERN, '(<redacted>)=(<redacted>)');

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
    typeof (err as { code?: unknown }).code === 'string'
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
