import { beforeEach, describe, expect, it, vi } from 'vitest';

const state = vi.hoisted(() => ({
  authFail: null as Response | null,
  membersSelectClauses: [] as string[],
  pendingRpcCalls: [] as Array<{ p_limit: number; p_cursor_date: string | null; p_cursor_id: string | null }>,
  pendingRpcPages: [] as Array<Array<{ id: string; nominee_name: string; reason: string | null; submitted_date: string | null }>>,
  pendingRpcErrorAtCall: -1,
  touchedLegacyUnmatchedRead: false,
}));

vi.mock('@/app/api/admin/auth', () => ({
  requireAdmin: vi.fn(async () => state.authFail),
}));

vi.mock('@/lib/supabase-server', () => {
  const from = vi.fn((table: string) => {
    if (table === 'anonymous_nominations') {
      return {
        select: vi.fn((fields: string) => {
          if (fields === 'id, nominee_member_id, nominee_name') {
            return {
              not: vi.fn(async () => ({
                data: [
                  { id: 'n1', nominee_member_id: 'm1', nominee_name: 'Alice A' },
                  { id: 'n2', nominee_member_id: 'm1', nominee_name: 'Alice A' },
                ],
                error: null,
              })),
            };
          }

          if (fields === 'id, nominee_name, reason') {
            state.touchedLegacyUnmatchedRead = true;
            return {
              is: vi.fn(() => ({
                order: vi.fn(async () => ({ data: [], error: null })),
              })),
            };
          }

          throw new Error(`unexpected nominations select: ${fields}`);
        }),
      };
    }

    if (table === 'members') {
      return {
        select: vi.fn((fields: string) => {
          if (fields === 'id, full_name') {
            return {
              in: vi.fn(async () => ({ data: [{ id: 'm1', full_name: 'Alice Alpha' }], error: null })),
              eq: vi.fn(() => ({
                ilike: vi.fn(() => ({
                  limit: vi.fn(async () => ({ data: [], error: null })),
                })),
              })),
            };
          }

          state.membersSelectClauses.push(fields);
          return {
            order: vi.fn(() => ({
              range: vi.fn(async () => ({ data: [], error: null })),
            })),
          };
        }),
      };
    }

    if (table === 'nomination_adjudications') {
      return {
        select: vi.fn(() => ({
          eq: vi.fn(() => ({
            not: vi.fn(async () => ({ data: [{ nominee_member_id: 'm1', candidate_id: 'c1' }], error: null })),
          })),
        })),
      };
    }

    throw new Error(`unexpected table ${table}`);
  });

  const rpc = vi.fn(async (fnName: string, args: { p_limit: number; p_cursor_date: string | null; p_cursor_id: string | null }) => {
    if (fnName === 'get_pending_unmatched_nominations') {
      state.pendingRpcCalls.push(args);
      const callIdx = state.pendingRpcCalls.length - 1;
      if (state.pendingRpcErrorAtCall === callIdx) {
        return { data: null, error: { message: `rpc failed at ${callIdx}` } };
      }
      return { data: state.pendingRpcPages[callIdx] || [], error: null };
    }
    throw new Error(`unexpected rpc ${fnName}`);
  });

  return {
    supabaseServer: {
      from,
      rpc,
    },
  };
});

describe('adjudication + export regressions', () => {
  beforeEach(() => {
    state.authFail = null;
    state.membersSelectClauses = [];
    state.pendingRpcCalls = [];
    state.pendingRpcPages = [];
    state.pendingRpcErrorAtCall = -1;
    state.touchedLegacyUnmatchedRead = false;
  });

  it('nominations GET paginates pending unmatched and keeps matched aggregation', async () => {
    state.pendingRpcPages = [
      Array.from({ length: 200 }, (_, i) => ({ id: `u${i + 1}`, nominee_name: `N${i + 1}`, reason: null, submitted_date: '2026-10-05' })),
      [{ id: 'u201', nominee_name: 'N201', reason: 'last', submitted_date: '2026-10-04' }],
    ];

    const { GET } = await import('@/app/api/admin/nominations/route');
    const res = await GET();
    const body = await res.json();
    expect(res.status, JSON.stringify(body)).toBe(200);

    expect(state.touchedLegacyUnmatchedRead).toBe(false);
    expect(state.pendingRpcCalls).toEqual([
      { p_limit: 200, p_cursor_date: null, p_cursor_id: null },
      { p_limit: 200, p_cursor_date: '2026-10-05', p_cursor_id: 'u200' },
    ]);

    expect(body.matched).toEqual([
      {
        nomineeMemberId: 'm1',
        fullName: 'Alice Alpha',
        nominationCount: 2,
        affectedNominationIds: ['n1', 'n2'],
        alreadyPromoted: true,
        promotedCandidateId: 'c1',
      },
    ]);
    expect(body.unmatched).toHaveLength(201);
    expect(body.unmatched[200]).toMatchObject({ id: 'u201', nomineeName: 'N201' });
  });

  it('nominations GET fails closed on paginated pending RPC error', async () => {
    state.pendingRpcPages = [
      Array.from({ length: 200 }, (_, i) => ({ id: `u${i + 1}`, nominee_name: `N${i + 1}`, reason: null, submitted_date: '2026-10-05' })),
    ];
    state.pendingRpcErrorAtCall = 1;

    const { GET } = await import('@/app/api/admin/nominations/route');
    const res = await GET();
    const body = await res.json();

    expect(res.status).toBe(500);
    expect(body.error).toContain('rpc failed at 1');
    expect(state.pendingRpcCalls).toEqual([
      { p_limit: 200, p_cursor_date: null, p_cursor_id: null },
      { p_limit: 200, p_cursor_date: '2026-10-05', p_cursor_id: 'u200' },
    ]);
  });

  it('nominations GET uses keyset cursor so row removal between pages does not skip', async () => {
    state.pendingRpcPages = [
      Array.from({ length: 200 }, (_, i) => ({ id: `u${i + 1}`, nominee_name: `N${i + 1}`, reason: null, submitted_date: '2026-10-05' })),
      [{ id: 'u202', nominee_name: 'N202', reason: null, submitted_date: '2026-10-04' }],
    ];

    const { GET } = await import('@/app/api/admin/nominations/route');
    const res = await GET();
    const body = await res.json();

    expect(res.status, JSON.stringify(body)).toBe(200);
    expect(state.pendingRpcCalls[1]).toEqual({ p_limit: 200, p_cursor_date: '2026-10-05', p_cursor_id: 'u200' });
    expect(body.unmatched[200].id).toBe('u202');
  });

  it('members-manage GET includes eligibility fields in list select', async () => {
    const { GET } = await import('@/app/api/admin/members-manage/route');
    const res = await GET(new Request('http://test/api/admin/members-manage?limit=5&offset=0'));
    expect(res.status).toBe(500);
    expect(
      state.membersSelectClauses.some(
        (s) => s.includes('voting_eligible') && s.includes('eligibility_reason')
      )
    ).toBe(true);
  });
});
