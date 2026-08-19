import { NextResponse } from 'next/server';

const isProd = process.env.NODE_ENV === 'production';

/**
 * Standardized error response for API routes.
 * In production, returns generic error messages to avoid information leakage.
 * In development, returns detailed error messages for debugging.
 */
export function apiError(error: unknown, fallbackMessage = 'Internal server error'): NextResponse {
  const message = error instanceof Error ? error.message : fallbackMessage;
  
  if (isProd) {
    // Log detailed error server-side only
    console.error('[API Error]', error);
    return NextResponse.json({ error: fallbackMessage }, { status: 500 });
  }
  
  return NextResponse.json({ error: message }, { status: 500 });
}

/**
 * Standardized validation error response.
 */
export function validationError(message: string): NextResponse {
  return NextResponse.json({ error: message }, { status: 400 });
}

/**
 * Standardized not found error response.
 */
export function notFoundError(message = 'Resource not found'): NextResponse {
  return NextResponse.json({ error: message }, { status: 404 });
}

/**
 * Standardized unauthorized error response.
 */
export function unauthorizedError(message = 'Unauthorized'): NextResponse {
  return NextResponse.json({ error: message }, { status: 401 });
}

/**
 * Standardized rate limit error response.
 */
export function rateLimitError(retryAfter = 60): NextResponse {
  return NextResponse.json(
    { error: 'Rate limit exceeded', retryAfter },
    { status: 429, headers: { 'Retry-After': String(retryAfter) } }
  );
}