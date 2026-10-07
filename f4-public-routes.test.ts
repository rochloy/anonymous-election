import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

type RpcResult = { data: unknown; error: { code?: string; message?: string } | null };

const state = vi.hoisted(() => ({
  createClientCalls: [] as Array<{ url: string | undefined; key: string | undefined; options: unknown }>,
  rpcCalls: [] as Array<{ fn: string; args: Record<string, unknown> | undefined }>,
  fromCalls: 0,
  rpcByFn: new Map<string, RpcResult>(),
}));

vi.mock('@supabase/supabase-js', () => ({
  createClient: vi.fn((url: string | undefined, key: string | undefined, options: unknown) => {
    state.createClientCalls.push({ url, key, options });
    return {
      rpc: vi.fn(async (fn: string, args?: Record<string, unknown>) => {
        state.rpcCalls.push({ fn, args });
        return state.rpcByFn.get(fn) ?? { data: null, error: null };
      }),
      from: vi.fn(() => {
        state.fromCalls += 1;
        throw new Error('direct from() usage is forbidden in F4 public routes');
      }),
    };
  }),
}));

const projectRoot = process.cwd();

function hasForbiddenPublicRouteSource(source: string): boolean {
  return (
    source.includes('SUPABASE_SERVICE_ROLE_KEY') ||
    source.includes('supabaseServer') ||
    /\.from\(\s*['\"][a-z_]+['\"]\s*\)/.test(source)
  );
}

function noSensitiveMessage(payload: unknown): boolean {
  const s = JSON.stringify(payload).toLowerCase();
  return !s.includes('permission denied') && !s.includes('relation ') && !s.includes('service role');
}

async function importFreshRoute(modulePath: string) {
  vi.resetModules();
  return import(modulePath);
}

describe('F4 public routes RPC cutover', () => {
  beforeEach(() => {
    state.createClientCalls = [];
    state.rpcCalls = [];
    state.fromCalls = 0;
    state.rpcByFn = new Map();
    vi.stubEnv('NEXT_PUBLIC_SUPABASE_URL', 'https://example.supabase.co');
    vi.stubEnv('NEXT_PUBLIC_SUPABASE_ANON_KEY', 'anon-key-test');
    vi.stubEnv('SUPABASE_SERVICE_ROLE_KEY', 'service-role-should-not-be-used');
  });

  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllEnvs();
  });

  it('RED static guards reject known-bad privileged and direct-from source snippets', () => {
    const badPrivileged = "const key = process.env.SUPABASE_SERVICE_ROLE_KEY;";
    const badDirectFrom = "await client.from('ballots').select('id');";
    expect(hasForbiddenPublicRouteSource(badPrivileged)).toBe(true);
    expect(hasForbiddenPublicRouteSource(badDirectFrom)).toBe(true);
  });

  it('RED simulated privileged import is rejected by static guard', () => {
    const badImport = "import { supabaseServer } from '@/lib/supabase-server';";
    expect(hasForbiddenPublicRouteSource(badImport)).toBe(true);
  });

  it('all 4 public routes use f4 rpc and do not read service-role/direct tables', () => {
    for (const file of [
      'app/api/election/status/route.ts',
      'app/api/candidates/route.ts',
      'app/api/verify/route.ts',
      'app/api/results/route.ts',
    ]) {
      const src = readFileSync(resolve(projectRoot, file), 'utf8');
      expect(src).toContain(".rpc('f4_");
      expect(hasForbiddenPublicRouteSource(src)).toBe(false);
    }
  });

  it('shared public helper is anon-only', () => {
    const src = readFileSync(resolve(projectRoot, 'lib/supabase-public-read.ts'), 'utf8');
    expect(src).toContain('createClient');
    expect(src).toContain('NEXT_PUBLIC_SUPABASE_ANON_KEY');
    expect(src).not.toContain('SUPABASE_SERVICE_ROLE_KEY');
  });

  it('status projects exact 8 keys from f4_election_status and drops extras', async () => {
    state.rpcByFn.set('f4_election_status', {
      data: {
        phase: 'VOTING',
        current_phase: 'VOTING',
        nomination_start: null,
        nomination_end: null,
        voting_start: '2026-02-01T00:00:00.000Z',
        voting_end: '2026-02-01T12:00:00.000Z',
        allow_write_ins: true,
        max_nominees_per_member: 3,
        leak: 'x',
      },
      error: null,
    });
    const { GET } = await importFreshRoute('@/app/api/election/status/route');
    const res = await GET();
    expect(await res.json()).toEqual({
      phase: 'VOTING',
      current_phase: 'VOTING',
      nomination_start: null,
      nomination_end: null,
      voting_start: '2026-02-01T00:00:00.000Z',
      voting_end: '2026-02-01T12:00:00.000Z',
      allow_write_ins: true,
      max_nominees_per_member: 3,
    });
    expect(res.status).toBe(200);
  });

  it('status returns generic 500 on empty/null malformed data', async () => {
    state.rpcByFn.set('f4_election_status', { data: null, error: null });
    const { GET } = await importFreshRoute('@/app/api/election/status/route');
    const res = await GET();
    const body = await res.json();
    expect(res.status).toBe(500);
    expect(body).toEqual({ error: 'Server error' });
    expect(noSensitiveMessage(body)).toBe(true);
  });

  it('status handles rpc error and phase contradiction with generic 500', async () => {
    const { GET } = await importFreshRoute('@/app/api/election/status/route');

    state.rpcByFn.set('f4_election_status', {
      data: null,
      error: { code: '42501', message: 'permission denied for relation election_state' },
    });
    const rpcError = await GET();
    expect(rpcError.status).toBe(500);
    expect(await rpcError.json()).toEqual({ error: 'Server error' });

    state.rpcByFn.set('f4_election_status', {
      data: {
        phase: 'VOTING',
        current_phase: 'NOMINATION',
        nomination_start: null,
        nomination_end: null,
        voting_start: '2026-02-01T00:00:00.000Z',
        voting_end: '2026-02-01T12:00:00.000Z',
        allow_write_ins: true,
        max_nominees_per_member: 3,
      },
      error: null,
    });
    const contradiction = await GET();
    expect(contradiction.status).toBe(500);
    expect(await contradiction.json()).toEqual({ error: 'Server error' });
  });

  it('candidates projects exact public candidate shape', async () => {
    state.rpcByFn.set('f4_candidates', {
      data: [{ id: 'c1', full_name: 'Candidate One', statement: 'S1', photo_url: null, internal: 'drop-me' }],
      error: null,
    });
    const { GET } = await importFreshRoute('@/app/api/candidates/route');
    const res = await GET();
    expect(await res.json()).toEqual([{ id: 'c1', full_name: 'Candidate One', statement: 'S1', photo_url: null }]);
    expect(res.status).toBe(200);
  });

  it('candidates handles empty, rpc-error, and malformed row shape', async () => {
    const { GET } = await importFreshRoute('@/app/api/candidates/route');

    state.rpcByFn.set('f4_candidates', { data: [], error: null });
    const empty = await GET();
    expect(empty.status).toBe(200);
    expect(await empty.json()).toEqual([]);

    state.rpcByFn.set('f4_candidates', {
      data: null,
      error: { code: '42501', message: 'permission denied for relation candidates' },
    });
    const rpcError = await GET();
    const rpcErrorBody = await rpcError.json();
    expect(rpcError.status).toBe(500);
    expect(rpcErrorBody).toEqual({ error: 'Server error' });
    expect(noSensitiveMessage(rpcErrorBody)).toBe(true);

    state.rpcByFn.set('f4_candidates', {
      data: [{ id: 'c1', full_name: 'Candidate One', statement: 7, photo_url: null }],
      error: null,
    });
    const malformed = await GET();
    const malformedBody = await malformed.json();
    expect(malformed.status).toBe(500);
    expect(malformedBody).toEqual({ error: 'Server error' });
    expect(noSensitiveMessage(malformedBody)).toBe(true);
  });

  it('verify supports valid paired and unpaired requests via f4_verify_ballot', async () => {
    state.rpcByFn.set('f4_verify_ballot', {
      data: { found: true, channel: 'DIGITAL', cast_date: '2026-02-01', receipt_match: null },
      error: null,
    });
    const { GET } = await importFreshRoute('@/app/api/verify/route');
    const unpaired = await GET(new Request('http://localhost/api/verify?receipt_code=VC-AAAAAAAAAA'));
    expect(await unpaired.json()).toEqual({ found: true, channel: 'DIGITAL', cast_date: '2026-02-01' });

    state.rpcByFn.set('f4_verify_ballot', {
      data: { found: true, channel: 'PAPER', cast_date: '2026-02-03', receipt_match: false },
      error: null,
    });
    const paired = await GET(new Request('http://localhost/api/verify?ballot_id=b1&receipt_code=VC-BBBBBBBBBB'));
    expect(await paired.json()).toEqual({ found: true, channel: 'PAPER', cast_date: '2026-02-03', receipt_match: false });
  });

  it('verify returns found:false for not-found and invalid receipt guard', async () => {
    const { GET } = await importFreshRoute('@/app/api/verify/route');
    state.rpcByFn.set('f4_verify_ballot', { data: { found: false }, error: null });
    const notFound = await GET(new Request('http://localhost/api/verify?ballot_id=missing'));
    expect(await notFound.json()).toEqual({ found: false });

    const invalid = await GET(new Request('http://localhost/api/verify?receipt_code=bad-input'));
    expect(await invalid.json()).toEqual({ found: false });
  });

  it('verify missing input returns 400 and no rpc call', async () => {
    const { GET } = await importFreshRoute('@/app/api/verify/route');
    const res = await GET(new Request('http://localhost/api/verify'));
    const body = await res.json();
    expect(res.status).toBe(400);
    expect(body).toEqual({ error: 'ballot_id or receipt_code is required' });
    expect(state.rpcCalls.length).toBe(0);
  });

  it('verify handles malformed/null response and simultaneous data+error with generic 500', async () => {
    const { GET } = await importFreshRoute('@/app/api/verify/route');
    state.rpcByFn.set('f4_verify_ballot', {
      data: { found: true, channel: 'DIGITAL', cast_date: null, receipt_match: null },
      error: null,
    });
    const malformed = await GET(new Request('http://localhost/api/verify?receipt_code=VC-AAAAAAAAAA'));
    const malformedBody = await malformed.json();
    expect(malformed.status).toBe(500);
    expect(malformedBody).toEqual({ error: 'Server error' });
    expect(noSensitiveMessage(malformedBody)).toBe(true);

    state.rpcByFn.set('f4_verify_ballot', {
      data: { found: false },
      error: { code: '42501', message: 'permission denied for relation ballots' },
    });
    const both = await GET(new Request('http://localhost/api/verify?ballot_id=x'));
    const bothBody = await both.json();
    expect(both.status).toBe(500);
    expect(bothBody).toEqual({ error: 'Server error' });
    expect(noSensitiveMessage(bothBody)).toBe(true);
  });

  it('results unpublished projects exact {published:false, phase}', async () => {
    state.rpcByFn.set('f4_results', { data: { published: false, phase: 'VOTING', totalVotes: 999 }, error: null });
    const { GET } = await importFreshRoute('@/app/api/results/route');
    const res = await GET(new Request('http://localhost/api/results?receipt=VC-AAAAAAAAAA'));
    expect(await res.json()).toEqual({ published: false, phase: 'VOTING' });
    expect(res.status).toBe(200);
  });

  it('results published handles VC and PB receipt_found and keeps strict public projection', async () => {
    const { GET } = await importFreshRoute('@/app/api/results/route');

    state.rpcByFn.set('f4_results', {
      data: {
        published: true,
        phase: 'COMPLETED',
        totalVotes: 2,
        results: [{ id: 'c1', full_name: 'Candidate One', statement: null, photo_url: null, votes: 2, percentage: 100, leak: 'x' }],
        receipt_found: true,
      },
      error: null,
    });
    const vc = await GET(new Request('http://localhost/api/results?receipt=VC-AAAAAAAAAA'));
    expect(await vc.json()).toEqual({
      published: true,
      phase: 'COMPLETED',
      totalVotes: 2,
      results: [{ id: 'c1', full_name: 'Candidate One', statement: null, photo_url: null, votes: 2, percentage: 100 }],
      receiptStatus: { searchedCode: 'VC-AAAAAAAAAA', found: true },
    });

    state.rpcByFn.set('f4_results', {
      data: {
        published: true,
        phase: 'VOTING_CLOSED',
        totalVotes: 2,
        results: [{ id: 'c1', full_name: 'Candidate One', statement: null, photo_url: null, votes: 2, percentage: 100 }],
        receipt_found: false,
      },
      error: null,
    });
    const pb = await GET(new Request('http://localhost/api/results?receipt=PB-ABCDEF1234'));
    expect(pb.status).toBe(200);
    expect((await pb.json()).receiptStatus).toEqual({ searchedCode: 'PB-ABCDEF1234', found: false });
  });

  it('results malformed and simultaneous data+error both return generic failure without raw DB text', async () => {
    const { GET } = await importFreshRoute('@/app/api/results/route');

    state.rpcByFn.set('f4_results', {
      data: { published: true, phase: 'COMPLETED', totalVotes: 1, results: [null], receipt_found: true },
      error: null,
    });
    const malformed = await GET(new Request('http://localhost/api/results?receipt=VC-AAAAAAAAAA'));
    const malformedBody = await malformed.json();
    expect(malformed.status).toBe(500);
    expect(malformedBody).toEqual({ error: 'Error fetching results' });
    expect(noSensitiveMessage(malformedBody)).toBe(true);

    state.rpcByFn.set('f4_results', {
      data: { published: false, phase: 'COMPLETED' },
      error: { code: '42501', message: 'permission denied for relation ballots' },
    });
    const both = await GET(new Request('http://localhost/api/results?receipt=VC-AAAAAAAAAA'));
    const bothBody = await both.json();
    expect(both.status).toBe(500);
    expect(bothBody).toEqual({ error: 'Error fetching results' });
    expect(noSensitiveMessage(bothBody)).toBe(true);
  });

  it('results malformed totalVotes and published-without-receipt_found both fail generic 500', async () => {
    const { GET } = await importFreshRoute('@/app/api/results/route');

    state.rpcByFn.set('f4_results', {
      data: {
        published: true,
        phase: 'COMPLETED',
        totalVotes: '2',
        results: [{ id: 'c1', full_name: 'Candidate One', statement: null, photo_url: null, votes: 2, percentage: 100 }],
        receipt_found: true,
      },
      error: null,
    });
    const badTotal = await GET(new Request('http://localhost/api/results?receipt=VC-AAAAAAAAAA'));
    const badTotalBody = await badTotal.json();
    expect(badTotal.status).toBe(500);
    expect(badTotalBody).toEqual({ error: 'Error fetching results' });

    state.rpcByFn.set('f4_results', {
      data: {
        published: true,
        phase: 'COMPLETED',
        totalVotes: 2,
        results: [{ id: 'c1', full_name: 'Candidate One', statement: null, photo_url: null, votes: 2, percentage: 100 }],
      },
      error: null,
    });
    const missingReceiptFound = await GET(new Request('http://localhost/api/results?receipt=VC-AAAAAAAAAA'));
    const missingReceiptFoundBody = await missingReceiptFound.json();
    expect(missingReceiptFound.status).toBe(500);
    expect(missingReceiptFoundBody).toEqual({ error: 'Error fetching results' });
  });

  it('results rejects unpublished closed/completed phase as malformed RPC response', async () => {
    const { GET } = await importFreshRoute('@/app/api/results/route');

    state.rpcByFn.set('f4_results', {
      data: { published: false, phase: 'VOTING_CLOSED' },
      error: null,
    });

    const res = await GET(new Request('http://localhost/api/results?receipt=PB-ABCDEF1234'));
    const body = await res.json();
    expect(res.status).toBe(500);
    expect(body).toEqual({ error: 'Error fetching results' });
    expect(noSensitiveMessage(body)).toBe(true);
  });

  it('results overlong receipt returns 400 without rpc call and without receipt echo', async () => {
    const { GET } = await importFreshRoute('@/app/api/results/route');
    const res = await GET(new Request(`http://localhost/api/results?receipt=${'a'.repeat(33)}`));
    const body = await res.json();
    expect(res.status).toBe(400);
    expect(body).toEqual({ error: 'Invalid request' });
    expect(body).not.toHaveProperty('receiptStatus');
    expect(state.rpcCalls.length).toBe(0);
  });

  it('results published trims+uppercases caller receipt, passes lowercase to rpc, and echoes caller-normalized code', async () => {
    const { GET } = await importFreshRoute('@/app/api/results/route');

    state.rpcByFn.set('f4_results', {
      data: {
        published: true,
        phase: 'COMPLETED',
        totalVotes: 1,
        results: [{ id: 'c1', full_name: 'Candidate One', statement: null, photo_url: null, votes: 1, percentage: 100 }],
        receipt_found: true,
      },
      error: null,
    });

    const res = await GET(new Request('http://localhost/api/results?receipt=%20pb-abcdef1234%20'));
    const body = await res.json();
    expect(res.status).toBe(200);
    expect(state.rpcCalls.at(-1)).toEqual({ fn: 'f4_results', args: { p_receipt_code: 'pb-abcdef1234' } });
    expect(body.receiptStatus).toEqual({ searchedCode: 'PB-ABCDEF1234', found: true });
  });

  it('runtime never constructs client with service-role key and never calls from()', async () => {
    state.rpcByFn.set('f4_election_status', {
      data: {
        phase: 'SETUP',
        current_phase: 'SETUP',
        nomination_start: null,
        nomination_end: null,
        voting_start: null,
        voting_end: null,
        allow_write_ins: false,
        max_nominees_per_member: 1,
      },
      error: null,
    });
    const { GET } = await importFreshRoute('@/app/api/election/status/route');
    await GET();
    expect(state.createClientCalls.some((c) => c.key === 'service-role-should-not-be-used')).toBe(false);
    expect(state.fromCalls).toBe(0);
  });
});
