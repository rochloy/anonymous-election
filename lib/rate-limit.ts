export type RateLimitOutcome = 'allow' | 'deny' | 'fault';

export function classifyRateLimitResult(params: {
  data: unknown;
  error: unknown;
}): RateLimitOutcome {
  if (params.error) return 'fault';

  const allowed =
    params.data &&
    typeof params.data === 'object' &&
    'allowed' in params.data
      ? (params.data as { allowed?: unknown }).allowed
      : undefined;

  if (allowed === true) return 'allow';
  if (allowed === false) return 'deny';
  return 'fault';
}

type RateLimitSurface =
  | 'admin_login'
  | 'admin_proxy'
  | 'legacy_vote'
  | 'admin_members_search'
  | 'nominate_submit'
  | 'nominate_search_ip'
  | 'nominate_search_token';

export function logRateLimitDenied(surface: RateLimitSurface): void {
  console.warn('[rate-limit]', { event: 'limit_denied', surface });
}

export function logRateLimitFault(surface: RateLimitSurface): void {
  console.warn('[rate-limit]', { event: 'limiter_unavailable', surface });
}
