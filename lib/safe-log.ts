// Personal-data-safe server error logging.
//
// Logs ONLY fixed, non-free-text fields: a developer-supplied context string,
// a validated error code, a category derived from that code, and an allow-listed
// error kind. Error message text, `details`, `hint`, `cause` and stacks are never
// logged — Postgres/PostgREST messages and details can embed row values (emails,
// names, tokens), and free text such as a bare name cannot be reliably redacted.
// Full error text remains available in Supabase's own (access-restricted) logs.

export type ErrorCategory =
  | 'connection'
  | 'invalid_input'
  | 'cardinality'
  | 'integrity'
  | 'transaction'
  | 'auth'
  | 'permission'
  | 'undefined_object'
  | 'syntax'
  | 'resource'
  | 'db_raised'
  | 'api_schema'
  | 'api'
  | 'network'
  | 'runtime'
  | 'unknown';

export type ErrorClassification = {
  code?: string;
  category: ErrorCategory;
  kind: string;
};

const SAFE_CODE_PATTERN = /^[A-Za-z0-9_]{1,16}$/;
const SAFE_KINDS = new Set([
  'Error',
  'TypeError',
  'RangeError',
  'SyntaxError',
  'ReferenceError',
  'AbortError',
  'TimeoutError',
  'FetchError',
  'PostgrestError',
  'AuthApiError',
]);

function categoryForCode(code: string): ErrorCategory {
  if (code.startsWith('PGRST')) {
    // PGRST2xx = schema cache / unknown function or table.
    return code.startsWith('PGRST2') ? 'api_schema' : 'api';
  }
  if (code === '42501') return 'permission';
  if (code === '42883' || code === '42P01' || code === '42703') return 'undefined_object';
  if (code === '21000') return 'cardinality'; // e.g. pg-safeupdate "DELETE requires a WHERE clause"
  switch (code.slice(0, 2)) {
    case '08':
      return 'connection';
    case '22':
      return 'invalid_input';
    case '23':
      return 'integrity';
    case '25':
    case '40':
      return 'transaction';
    case '28':
      return 'auth';
    case '42':
      return 'syntax';
    case '53':
    case '54':
    case '57':
    case '58':
      return 'resource';
    case 'P0':
      return 'db_raised';
    default:
      return 'unknown';
  }
}

export function classifyError(err: unknown): ErrorClassification {
  const obj = typeof err === 'object' && err !== null ? (err as Record<string, unknown>) : null;

  const rawCode = obj?.code;
  const code =
    typeof rawCode === 'string' && SAFE_CODE_PATTERN.test(rawCode) ? rawCode : undefined;

  const rawName = obj?.name;
  const kind =
    typeof rawName === 'string' && SAFE_KINDS.has(rawName)
      ? rawName
      : err instanceof Error
        ? 'Error'
        : obj
          ? 'object'
          : typeof err;

  let category: ErrorCategory;
  if (code) {
    category = categoryForCode(code);
  } else if (kind === 'AbortError' || kind === 'TimeoutError' || kind === 'FetchError') {
    category = 'network';
  } else if (kind === 'TypeError' && obj?.message === 'fetch failed') {
    // The message is only compared against a constant — never logged.
    category = 'network';
  } else if (err instanceof Error) {
    category = 'runtime';
  } else {
    category = 'unknown';
  }

  return { code, category, kind };
}

export function logError(context: string, err: unknown): void {
  const { code, category, kind } = classifyError(err);
  console.error(`[${context}]`, { code, category, kind });
}
