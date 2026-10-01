import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { NextRequest } from 'next/server';

type RpcResult = { data: unknown; error: unknown };
type RpcAction = RpcResult | { throwMessage: string };

type FromQueryConfig = {
  maybeSingle?: { data: unknown; error: unknown };
  single?: { data: unknown; error: unknown };
  limit?: { data: unknown; error: unknown };
  limitReturnsChain?: boolean;
};

const state = vi.hoisted(() => ({
  rpcQueue: [] as RpcAction[],
  insertCalls: [] as unknown[],
  requireAdminResult: null as Response | null,
  cookieGetValue: undefined as string | undefined,
  fromQueue: [] as FromQueryConfig[],
  schemaRpcQueue: [] as RpcResult[],
  unexpectedCalls: [] as string[],
}));

vi.mock('@/lib/supabase-server', () => {
  const nextFromConfig = () => {
    const next = state.fromQueue.shift();
    if (!next) {
      state.unexpectedCalls.push('from.select');
      throw new Error('UNEXPECTED_FROM_SELECT_CALL');
    }
    return next;
  };

  const makeFromChain = (config: FromQueryConfig) => {
    const chain = {
      eq: vi.fn(() => chain),
      ilike: vi.fn(() => chain),
      in: vi.fn(() => chain),
      is: vi.fn(() => chain),
      order: vi.fn(() => chain),
      limit: vi.fn(() =>
        config.limitReturnsChain ? chain : (config.limit ?? { data: [], error: null })
      ),
      maybeSingle: vi.fn(async () => config.maybeSingle ?? { data: null, error: null }),
      single: vi.fn(async () => config.single ?? { data: null, error: null }),
    };
    return chain;
  };

  const mockClient = {
    rpc: vi.fn(async () => {
      const next = state.rpcQueue.shift();
      if (!next) {
        state.unexpectedCalls.push('rpc');
        throw new Error('UNEXPECTED_RPC_CALL');
      }
      if ('throwMessage' in next) throw new Error(next.throwMessage);
      return next;
    }),
    from: vi.fn(() => {
      return {
        insert: vi.fn(async (payload: unknown) => {
          state.insertCalls.push(payload);
          return { error: null };
        }),
        update: vi.fn(() => ({
          eq: vi.fn(() => ({
            is: vi.fn(async () => ({ error: null })),
          })),
        })),
        select: vi.fn(() => makeFromChain(nextFromConfig())),
      };
    }),
    schema: vi.fn(() => ({
      rpc: vi.fn(async () => {
        const next = state.schemaRpcQueue.shift();
        if (!next) {
          state.unexpectedCalls.push('schema.rpc');
          throw new Error('UNEXPECTED_SCHEMA_RPC_CALL');
        }
        return next;
      }),
    })),
  };
  return { supabaseServer: mockClient };
});

vi.mock('next/headers', () => ({
  cookies: vi.fn(async () => ({
    get: vi.fn(() =>
      state.cookieGetValue === undefined ? undefined : { value: state.cookieGetValue }
    ),
  })),
}));

vi.mock('@/app/api/admin/auth', () => ({
  SESSION_COOKIE_NAME: 'admin_session',
  CSRF_COOKIE_NAME: 'admin_csrf',
  generateCsrfToken: () => 'csrf-fixture',
  requireAdmin: vi.fn(async () => state.requireAdminResult),
}));

describe('rate-limit fault policy', () => {
  beforeEach(() => {
    state.rpcQueue = [];
    state.insertCalls = [];
    state.requireAdminResult = null;
    state.cookieGetValue = undefined;
    state.fromQueue = [];
    state.schemaRpcQueue = [];
    state.unexpectedCalls = [];
    vi.clearAllMocks();
    delete process.env.ADMIN_SECRET;
    delete process.env.RATE_LIMIT_SECRET;
  });

  afterEach(() => {
    expect(state.rpcQueue).toHaveLength(0);
    expect(state.fromQueue).toHaveLength(0);
    expect(state.schemaRpcQueue).toHaveLength(0);
    expect(state.unexpectedCalls).toEqual([]);
  });

  it('login: allowed=true + valid secret succeeds and writes session/cookies', async () => {
    process.env.ADMIN_SECRET = 'valid-secret';
    state.rpcQueue.push({ data: { allowed: true }, error: null });

    const { POST } = await import('@/app/api/admin/login/route');
    const res = await POST(
      new Request('http://test.local/api/admin/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'x-forwarded-for': '10.10.10.1' },
        body: JSON.stringify({ secret: 'valid-secret', scope: 'desktop' }),
      })
    );

    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.success).toBe(true);
    expect(body.csrfToken).toBe('csrf-fixture');
    expect(state.insertCalls.length).toBe(1);
    expect(JSON.stringify(state.insertCalls[0])).toContain('10.10.10.1');
    const setCookie = res.headers.get('set-cookie') ?? '';
    expect(setCookie).toContain('admin_session=');
    expect(setCookie).toContain('admin_csrf=csrf-fixture');
  });

  it('login: allowed=false returns 429 with retry-after', async () => {
    state.rpcQueue.push({ data: { allowed: false }, error: null });
    const { POST } = await import('@/app/api/admin/login/route');
    const res = await POST(
      new Request('http://test.local/api/admin/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ secret: 'anything', scope: 'desktop' }),
      })
    );

    expect(res.status).toBe(429);
    expect(res.headers.get('Retry-After')).toBe('60');
  });

  it('login: rpc error/throw/null/malformed all return same 503, no session write, sanitized log', async () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
    process.env.ADMIN_SECRET = 'valid-secret';
    const secretA = 'secret-fixture-a';
    const secretB = 'secret-fixture-b';

    const { POST } = await import('@/app/api/admin/login/route');

    state.rpcQueue.push({ data: null, error: { message: 'rpc-down-fixture' } });
    const resRpcError = await POST(
      new Request('http://test.local/api/admin/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ secret: secretA, scope: 'desktop' }),
      })
    );

    state.rpcQueue.push({ throwMessage: 'limiter-throw-fixture' });
    state.rpcQueue.push({ data: null, error: null });
    state.rpcQueue.push({ data: { nope: true }, error: null });
    state.rpcQueue.push({ data: { allowed: 'yes' }, error: null });

    const resThrown = await POST(
      new Request('http://test.local/api/admin/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ secret: secretB, scope: 'desktop' }),
      })
    );

    const resNull = await POST(
      new Request('http://test.local/api/admin/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ secret: secretA, scope: 'desktop' }),
      })
    );

    const resMissing = await POST(
      new Request('http://test.local/api/admin/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ secret: secretB, scope: 'desktop' }),
      })
    );

    const resNonBoolean = await POST(
      new Request('http://test.local/api/admin/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ secret: secretA, scope: 'desktop' }),
      })
    );

    const bodies = await Promise.all([
      resRpcError.json(),
      resThrown.json(),
      resNull.json(),
      resMissing.json(),
      resNonBoolean.json(),
    ]);
    expect(resRpcError.status).toBe(503);
    expect(resThrown.status).toBe(503);
    expect(resNull.status).toBe(503);
    expect(resMissing.status).toBe(503);
    expect(resNonBoolean.status).toBe(503);
    expect(bodies.every((b) => JSON.stringify(b) === JSON.stringify(bodies[0]))).toBe(true);
    expect(state.insertCalls.length).toBe(0);

    const warnText = warn.mock.calls.map((c: unknown[]) => JSON.stringify(c)).join(' ');
    expect(warnText).toContain('limiter_unavailable');
    expect(warnText).toContain('admin_login');
    expect(warnText).not.toContain(secretA);
    expect(warnText).not.toContain(secretB);
    expect(warnText).not.toContain('rpc-down-fixture');
    expect(warnText).not.toContain('limiter-throw-fixture');
  });

  it('proxy: deny/allow/fault/throw/malformed all preserve CSP and fault + login gives login-specific 503', async () => {
    const { proxy } = await import('@/proxy');
    const { POST: loginPost } = await import('@/app/api/admin/login/route');
    process.env.ADMIN_SECRET = 'proxy-compose-secret';

    state.rpcQueue.push({ data: { allowed: false }, error: null });
    const denyRes = await proxy(
      new NextRequest('http://test.local/api/admin/members', {
        headers: { 'x-forwarded-for': '1.2.3.4' },
      })
    );
    expect(denyRes.status).toBe(429);
    expect(denyRes.headers.get('Retry-After')).toBe('60');
    expect(denyRes.headers.get('Content-Security-Policy')).toContain("default-src 'self'");

    state.rpcQueue.push({ data: null, error: { message: 'proxy-rpc-error' } });
    const faultRes = await proxy(new NextRequest('http://test.local/api/admin/members'));
    expect(faultRes.status).toBe(200);
    expect(faultRes.headers.get('Content-Security-Policy')).toContain("script-src 'self'");

    state.rpcQueue.push({ data: { allowed: true }, error: null });
    const allowRes = await proxy(new NextRequest('http://test.local/api/admin/members'));
    expect(allowRes.status).toBe(200);
    expect(allowRes.headers.get('Content-Security-Policy')).toContain("img-src 'self' data: https: blob:");

    state.rpcQueue.push({ throwMessage: 'proxy-throw' });
    const throwRes = await proxy(new NextRequest('http://test.local/api/admin/members'));
    expect(throwRes.status).toBe(200);
    expect(throwRes.headers.get('Content-Security-Policy')).toContain("frame-ancestors 'none'");

    state.rpcQueue.push({ data: null, error: null });
    const nullRes = await proxy(new NextRequest('http://test.local/api/admin/members'));
    expect(nullRes.status).toBe(200);
    expect(nullRes.headers.get('Content-Security-Policy')).toContain("form-action 'self'");

    state.rpcQueue.push({ data: { allowed: 'no' }, error: null });
    const malformedRes = await proxy(new NextRequest('http://test.local/api/admin/members'));
    expect(malformedRes.status).toBe(200);
    expect(malformedRes.headers.get('Content-Security-Policy')).toContain("base-uri 'self'");

    state.rpcQueue.push({ data: null, error: { message: 'proxy-fault-before-login' } });
    const proxyBeforeLogin = await proxy(
      new NextRequest('http://test.local/api/admin/login', {
        headers: { 'x-forwarded-for': '6.6.6.6' },
      })
    );
    expect(proxyBeforeLogin.status).toBe(200);

    state.rpcQueue.push({ data: null, error: { message: 'login-limiter-down' } });
    const loginFaultRes = await loginPost(
      new Request('http://test.local/api/admin/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'x-forwarded-for': '6.6.6.6' },
        body: JSON.stringify({ secret: 'proxy-compose-secret', scope: 'desktop' }),
      })
    );
    expect(loginFaultRes.status).toBe(503);
    expect(await loginFaultRes.json()).toEqual({
      error: 'Login temporarily unavailable. Please try again shortly.',
    });
  });

  it('legacy vote: confirmed deny returns 429', async () => {
    const { POST: votePost } = await import('@/app/api/vote/route');

    state.rpcQueue.push({ data: { allowed: false }, error: null });
    const denied = await votePost(
      new Request('http://test.local/api/vote', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rawToken: 'fixture-vote-token', candidateId: 'candidate-1' }),
      })
    );

    expect(denied.status).toBe(429);
    expect(denied.headers.get('Retry-After')).toBe('60');
  });

  it('legacy vote fail-open reaches token guard and returns expected 400', async () => {
    const { POST: votePost } = await import('@/app/api/vote/route');

    state.rpcQueue.push({ data: null, error: { message: 'vote-limiter-down' } });
    state.fromQueue.push({ maybeSingle: { data: { digital_write_mode: 'LEGACY' }, error: null } });
    state.fromQueue.push({ single: { data: null, error: { message: 'not found' } } });

    const voteRes = await votePost(
      new Request('http://test.local/api/vote', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rawToken: 'fixture-vote-token', candidateId: 'candidate-1' }),
      })
    );

    expect(voteRes.status).toBe(400);
    expect(await voteRes.json()).toEqual({ error: 'Invalid or expired voting token.' });
  });

  it('legacy vote: limiter throw/null/malformed-nonboolean fail-open still hits normal token guard', async () => {
    const { POST: votePost } = await import('@/app/api/vote/route');

    state.rpcQueue.push({ throwMessage: 'vote-limiter-throw' });
    state.fromQueue.push({ maybeSingle: { data: { digital_write_mode: 'LEGACY' }, error: null } });
    state.fromQueue.push({ single: { data: null, error: { message: 'not found' } } });

    state.rpcQueue.push({ data: null, error: null });
    state.fromQueue.push({ maybeSingle: { data: { digital_write_mode: 'LEGACY' }, error: null } });
    state.fromQueue.push({ single: { data: null, error: { message: 'not found' } } });

    state.rpcQueue.push({ data: { bad: true }, error: null });
    state.fromQueue.push({ maybeSingle: { data: { digital_write_mode: 'LEGACY' }, error: null } });
    state.fromQueue.push({ single: { data: null, error: { message: 'not found' } } });

    state.rpcQueue.push({ data: { allowed: 'yes' }, error: null });
    state.fromQueue.push({ maybeSingle: { data: { digital_write_mode: 'LEGACY' }, error: null } });
    state.fromQueue.push({ single: { data: null, error: { message: 'not found' } } });

    const req = () =>
      new Request('http://test.local/api/vote', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rawToken: 'fixture-vote-token', candidateId: 'candidate-1' }),
      });

    const throwRes = await votePost(req());
    const nullRes = await votePost(req());
    const missingRes = await votePost(req());
    const nonBooleanRes = await votePost(req());

    for (const res of [throwRes, nullRes, missingRes, nonBooleanRes]) {
      expect(res.status).toBe(400);
      expect(await res.json()).toEqual({ error: 'Invalid or expired voting token.' });
    }
  });

  it('admin member search: unauthenticated remains 401; authenticated fail-open reaches search query', async () => {
    const { GET: membersGet } = await import('@/app/api/admin/members/route');

    state.requireAdminResult = new Response(JSON.stringify({ error: 'Unauthorized' }), {
      status: 401,
      headers: { 'Content-Type': 'application/json' },
    });
    const unauthRes = await membersGet(new Request('http://test.local/api/admin/members?q=ab'));
    expect(unauthRes.status).toBe(401);

    state.requireAdminResult = null;
    state.rpcQueue.push({ data: null, error: { message: 'members-limiter-down' } });
    state.rpcQueue.push({ data: null, error: null });
    state.fromQueue.push({
      limit: {
        data: [
          {
            id: 'member-1',
            member_code: 'M1',
            full_name: 'Alice Admin',
            email: null,
            phone: null,
            is_active: true,
            voting_eligible: true,
            eligibility_reason: null,
            eligibility_source: null,
          },
        ],
        error: null,
      },
    });
    state.fromQueue.push({ limit: { data: [], error: null } });
    state.fromQueue.push({ maybeSingle: { data: null, error: null }, limitReturnsChain: true });

    const authedRes = await membersGet(new Request('http://test.local/api/admin/members?q=alice'));
    expect(authedRes.status).toBe(200);
    const body = await authedRes.json();
    expect(Array.isArray(body.members)).toBe(true);
    expect(body.members[0].full_name).toBe('Alice Admin');
  });

  it('admin member search: malformed and thrown limiter outcomes fail-open, while auth still gates access', async () => {
    const { GET: membersGet } = await import('@/app/api/admin/members/route');

    state.requireAdminResult = new Response(JSON.stringify({ error: 'Unauthorized' }), {
      status: 401,
      headers: { 'Content-Type': 'application/json' },
    });
    state.rpcQueue.push({ data: { allowed: true }, error: null });
    const unauthRes = await membersGet(new Request('http://test.local/api/admin/members?q=alice'));
    expect(unauthRes.status).toBe(401);
    expect(state.rpcQueue).toHaveLength(1);
    state.rpcQueue = [];

    state.requireAdminResult = null;

    state.rpcQueue.push({ throwMessage: 'members-limiter-throw' });
    state.rpcQueue.push({ data: null, error: null });
    state.fromQueue.push({ limit: { data: [], error: null } });

    state.rpcQueue.push({ data: { allowed: 'nope' }, error: null });
    state.rpcQueue.push({ data: null, error: null });
    state.fromQueue.push({ limit: { data: [], error: null } });

    const throwRes = await membersGet(new Request('http://test.local/api/admin/members?q=alice'));
    const malformedRes = await membersGet(new Request('http://test.local/api/admin/members?q=alice'));

    expect(throwRes.status).toBe(200);
    expect(await throwRes.json()).toEqual({ members: [] });
    expect(malformedRes.status).toBe(200);
    expect(await malformedRes.json()).toEqual({ members: [] });
  });

  it('nomination submit: allow(true) continues; deny(false)=429; rpc error/throw/null/missing/nonboolean=503', async () => {
    const { POST: nominatePost } = await import('@/app/api/nominate/route');

    state.rpcQueue.push({ data: { allowed: true }, error: null });
    state.rpcQueue.push({ data: [{ success: true, inserted_count: 1 }], error: null });
    const allowRes = await nominatePost(
      new Request('http://test.local/api/nominate', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rawToken: 'a'.repeat(64), nominees: [{ nominee_name: 'Valid Name' }] }),
      })
    );
    expect(allowRes.status).toBe(200);

    state.rpcQueue.push({ data: { allowed: false }, error: null });
    const denyRes = await nominatePost(
      new Request('http://test.local/api/nominate', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rawToken: 'a'.repeat(64), nominees: [{ nominee_name: 'Valid Name' }] }),
      })
    );
    expect(denyRes.status).toBe(429);
    expect(denyRes.headers.get('Retry-After')).toBe('60');

    state.rpcQueue.push({ data: null, error: { message: 'nom-submit-rpc-error' } });
    const rpcErrRes = await nominatePost(
      new Request('http://test.local/api/nominate', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rawToken: 'a'.repeat(64), nominees: [{ nominee_name: 'Valid Name' }] }),
      })
    );
    expect(rpcErrRes.status).toBe(503);

    state.rpcQueue.push({ throwMessage: 'nom-submit-throw' });
    state.rpcQueue.push({ data: null, error: null });
    state.rpcQueue.push({ data: {}, error: null });
    state.rpcQueue.push({ data: { allowed: 'y' }, error: null });

    const throwRes = await nominatePost(
      new Request('http://test.local/api/nominate', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rawToken: 'a'.repeat(64), nominees: [{ nominee_name: 'Valid Name' }] }),
      })
    );
    expect(throwRes.status).toBe(503);

    const nullRes = await nominatePost(
      new Request('http://test.local/api/nominate', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rawToken: 'a'.repeat(64), nominees: [{ nominee_name: 'Valid Name' }] }),
      })
    );
    expect(nullRes.status).toBe(503);

    const missingRes = await nominatePost(
      new Request('http://test.local/api/nominate', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rawToken: 'a'.repeat(64), nominees: [{ nominee_name: 'Valid Name' }] }),
      })
    );
    expect(missingRes.status).toBe(503);

    const nonBooleanRes = await nominatePost(
      new Request('http://test.local/api/nominate', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rawToken: 'a'.repeat(64), nominees: [{ nominee_name: 'Valid Name' }] }),
      })
    );
    expect(nonBooleanRes.status).toBe(503);
  });

  it('nomination search: ip and token checks cover allow/deny/rpc error/throw/null/missing/nonboolean with sanitized 503 faults', async () => {
    const { POST: searchPost } = await import('@/app/api/nominate/search/route');
    process.env.RATE_LIMIT_SECRET = 'rate-limit-pepper';
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
    const sensitiveToken = 'a'.repeat(64);

    // allow -> allow -> reaches search query
    state.rpcQueue.push({ data: { allowed: true }, error: null });
    state.rpcQueue.push({ data: { allowed: true }, error: null });
    state.rpcQueue.push({ data: [{ member_id: 'm1', full_name: 'Alice Nominee' }], error: null });
    const allowRes = await searchPost(
      new Request('http://test.local/api/nominate/search', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'x-forwarded-for': '8.8.8.8' },
        body: JSON.stringify({ rawToken: sensitiveToken, query: 'alice' }),
      })
    );
    expect(allowRes.status).toBe(200);

    // ip deny
    state.rpcQueue.push({ data: { allowed: false }, error: null });
    const ipDenyRes = await searchPost(
      new Request('http://test.local/api/nominate/search', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rawToken: sensitiveToken, query: 'alice' }),
      })
    );
    expect(ipDenyRes.status).toBe(429);

    // ip rpc error
    state.rpcQueue.push({ data: null, error: { message: 'ip-rpc-error' } });
    const ipRpcErrorRes = await searchPost(
      new Request('http://test.local/api/nominate/search', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rawToken: sensitiveToken, query: 'alice' }),
      })
    );
    expect(ipRpcErrorRes.status).toBe(503);

    // ip null/missing/nonboolean
    state.rpcQueue.push({ data: null, error: null });
    const ipNullRes = await searchPost(
      new Request('http://test.local/api/nominate/search', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rawToken: sensitiveToken, query: 'alice' }),
      })
    );
    expect(ipNullRes.status).toBe(503);

    state.rpcQueue.push({ data: {}, error: null });
    const ipMissingRes = await searchPost(
      new Request('http://test.local/api/nominate/search', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rawToken: sensitiveToken, query: 'alice' }),
      })
    );
    expect(ipMissingRes.status).toBe(503);

    state.rpcQueue.push({ data: { allowed: 'no' }, error: null });
    const ipNonBooleanRes = await searchPost(
      new Request('http://test.local/api/nominate/search', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rawToken: sensitiveToken, query: 'alice' }),
      })
    );
    expect(ipNonBooleanRes.status).toBe(503);

    // token deny
    state.rpcQueue.push({ data: { allowed: true }, error: null });
    state.rpcQueue.push({ data: { allowed: false }, error: null });
    const tokenDenyRes = await searchPost(
      new Request('http://test.local/api/nominate/search', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rawToken: sensitiveToken, query: 'alice' }),
      })
    );
    expect(tokenDenyRes.status).toBe(429);

    // token rpc error
    state.rpcQueue.push({ data: { allowed: true }, error: null });
    state.rpcQueue.push({ data: null, error: { message: 'token-rpc-error' } });
    const tokenRpcErrorRes = await searchPost(
      new Request('http://test.local/api/nominate/search', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rawToken: sensitiveToken, query: 'alice' }),
      })
    );
    expect(tokenRpcErrorRes.status).toBe(503);

    // token null/missing/nonboolean
    state.rpcQueue.push({ data: { allowed: true }, error: null });
    state.rpcQueue.push({ data: null, error: null });
    const tokenNullRes = await searchPost(
      new Request('http://test.local/api/nominate/search', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rawToken: sensitiveToken, query: 'alice' }),
      })
    );
    expect(tokenNullRes.status).toBe(503);

    state.rpcQueue.push({ data: { allowed: true }, error: null });
    state.rpcQueue.push({ data: { bad: true }, error: null });
    const tokenMissingRes = await searchPost(
      new Request('http://test.local/api/nominate/search', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rawToken: sensitiveToken, query: 'alice' }),
      })
    );
    expect(tokenMissingRes.status).toBe(503);

    state.rpcQueue.push({ data: { allowed: true }, error: null });
    state.rpcQueue.push({ data: { allowed: 'bad' }, error: null });
    const tokenNonBooleanRes = await searchPost(
      new Request('http://test.local/api/nominate/search', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rawToken: sensitiveToken, query: 'alice' }),
      })
    );
    expect(tokenNonBooleanRes.status).toBe(503);

    state.rpcQueue.push({ throwMessage: 'ip-throw' });
    const ipThrowRes = await searchPost(
      new Request('http://test.local/api/nominate/search', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rawToken: sensitiveToken, query: 'alice' }),
      })
    );
    expect(ipThrowRes.status).toBe(503);

    state.rpcQueue.push({ data: { allowed: true }, error: null });
    state.rpcQueue.push({ throwMessage: 'token-throw' });
    const tokenThrowRes = await searchPost(
      new Request('http://test.local/api/nominate/search', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rawToken: sensitiveToken, query: 'alice' }),
      })
    );
    expect(tokenThrowRes.status).toBe(503);

    const warnText = warn.mock.calls.map((c: unknown[]) => JSON.stringify(c)).join(' ');
    expect(warnText).toContain('limiter_unavailable');
    expect(warnText).toContain('nominate_search_ip');
    expect(warnText).toContain('nominate_search_token');
    expect(warnText).not.toContain(sensitiveToken);
    expect(warnText).not.toContain('ip-throw');
    expect(warnText).not.toContain('token-throw');
  });

  it('diagnostics: denied/unavailable events across all required surfaces and no fixture leaks', async () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});

    const { POST: loginPost } = await import('@/app/api/admin/login/route');
    const { proxy } = await import('@/proxy');
    const { POST: votePost } = await import('@/app/api/vote/route');
    const { GET: membersGet } = await import('@/app/api/admin/members/route');
    const { POST: nominatePost } = await import('@/app/api/nominate/route');
    const { POST: searchPost } = await import('@/app/api/nominate/search/route');

    process.env.ADMIN_SECRET = 'diag-admin-secret';
    process.env.RATE_LIMIT_SECRET = 'diag-rate-secret';

    state.rpcQueue.push({ data: { allowed: false }, error: null });
    await loginPost(
      new Request('http://test.local/api/admin/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'x-forwarded-for': '3.3.3.3' },
        body: JSON.stringify({ secret: 'diag-admin-secret', scope: 'desktop' }),
      })
    );
    state.rpcQueue.push({ data: null, error: { message: 'login-rpc-fixture' } });
    await loginPost(
      new Request('http://test.local/api/admin/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'x-forwarded-for': '3.3.3.3' },
        body: JSON.stringify({ secret: 'diag-admin-secret', scope: 'desktop' }),
      })
    );

    state.rpcQueue.push({ data: { allowed: false }, error: null });
    await proxy(new NextRequest('http://test.local/api/admin/members', { headers: { 'x-forwarded-for': '2.2.2.2' } }));
    state.rpcQueue.push({ data: null, error: { message: 'proxy-rpc-fixture' } });
    await proxy(new NextRequest('http://test.local/api/admin/members', { headers: { 'x-forwarded-for': '2.2.2.2' } }));

    state.rpcQueue.push({ data: { allowed: false }, error: null });
    await votePost(
      new Request('http://test.local/api/vote', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rawToken: 'diag-vote-token', candidateId: 'x' }),
      })
    );
    state.rpcQueue.push({ data: null, error: { message: 'vote-rpc-fixture' } });
    state.fromQueue.push({ maybeSingle: { data: { digital_write_mode: 'LEGACY' }, error: null } });
    state.fromQueue.push({ single: { data: null, error: { message: 'missing' } } });
    await votePost(
      new Request('http://test.local/api/vote', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rawToken: 'diag-vote-token', candidateId: 'x' }),
      })
    );

    state.requireAdminResult = null;
    state.rpcQueue.push({ data: { allowed: false }, error: null });
    await membersGet(new Request('http://test.local/api/admin/members?q=ab'));
    state.rpcQueue.push({ data: null, error: { message: 'members-rpc-fixture' } });
    state.rpcQueue.push({ data: null, error: null });
    state.fromQueue.push({ limit: { data: [], error: null } });
    await membersGet(new Request('http://test.local/api/admin/members?q=ab'));

    state.rpcQueue.push({ data: { allowed: false }, error: null });
    await nominatePost(
      new Request('http://test.local/api/nominate', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rawToken: 'a'.repeat(64), nominees: [{ nominee_name: 'X' }] }),
      })
    );
    state.rpcQueue.push({ data: {}, error: null });
    await nominatePost(
      new Request('http://test.local/api/nominate', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rawToken: 'a'.repeat(64), nominees: [{ nominee_name: 'X' }] }),
      })
    );

    state.rpcQueue.push({ data: { allowed: false }, error: null });
    await searchPost(
      new Request('http://test.local/api/nominate/search', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rawToken: 'a'.repeat(64), query: 'ab' }),
      })
    );
    state.rpcQueue.push({ data: null, error: { message: 'search-ip-rpc-fixture' } });
    await searchPost(
      new Request('http://test.local/api/nominate/search', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rawToken: 'a'.repeat(64), query: 'ab' }),
      })
    );
    state.rpcQueue.push({ data: { allowed: true }, error: null });
    state.rpcQueue.push({ data: { allowed: false }, error: null });
    await searchPost(
      new Request('http://test.local/api/nominate/search', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rawToken: 'a'.repeat(64), query: 'ab' }),
      })
    );
    state.rpcQueue.push({ data: { allowed: true }, error: null });
    state.rpcQueue.push({ data: { bad: true }, error: null });
    await searchPost(
      new Request('http://test.local/api/nominate/search', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rawToken: 'a'.repeat(64), query: 'ab' }),
      })
    );

    const events = warn.mock.calls
      .map((c: unknown[]) => c[1])
      .filter(
        (entry: unknown): entry is { event: string; surface: string } =>
          entry !== null && typeof entry === 'object' && 'event' in entry && 'surface' in entry
      );
    const surfaces = [
      'admin_login',
      'admin_proxy',
      'legacy_vote',
      'admin_members_search',
      'nominate_submit',
      'nominate_search_ip',
      'nominate_search_token',
    ] as const;
    for (const surface of surfaces) {
      expect(events.some((e) => e.surface === surface && e.event === 'limit_denied'), `${surface} missing limit_denied`).toBe(true);
      expect(events.some((e) => e.surface === surface && e.event === 'limiter_unavailable'), `${surface} missing limiter_unavailable`).toBe(true);
    }

    const warnText = warn.mock.calls.map((c: unknown[]) => JSON.stringify(c)).join(' ');
    expect(warnText).not.toContain('diag-admin-secret');
    expect(warnText).not.toContain('diag-vote-token');
    expect(warnText).not.toContain('3.3.3.3');
    expect(warnText).not.toContain('2.2.2.2');
  });
});
