import { beforeEach, describe, expect, it, vi } from 'vitest';

const state = vi.hoisted(() => ({
  phase: 'VOTING',
  paperCount: 0,
  digitalCount: 0,
  ballots: [] as Array<{ candidate_id: string }>,
  candidates: [] as Array<{ id: string; full_name: string }>,
  blockAnonymousPaperBlanks: true,
}));

vi.mock('@/app/api/admin/auth', () => ({
  requireAdmin: vi.fn(async () => null),
}));

vi.mock('@/lib/supabase-server', () => ({
  supabaseServer: {
    from: vi.fn((table: string) => {
      if (table === 'election_settings') {
        return {
          select: vi.fn(() => ({
            eq: vi.fn(() => ({
              single: vi.fn(async () => ({ data: { current_phase: state.phase }, error: null })),
            })),
          })),
        };
      }

      if (table === 'participation_audit') {
        return {
          select: vi.fn(() => ({
            eq: vi.fn(async () => ({ count: 0, error: null })),
          })),
        };
      }

      if (table === 'ballots') {
        return {
          select: vi.fn((fields: string) => {
            if (fields === 'ballot_id') {
              return {
                eq: vi.fn(async (_col: string, value: string) => ({
                  count: value === 'PAPER' ? state.paperCount : state.digitalCount,
                  error: null,
                })),
              };
            }

            if (fields === 'candidate_id') {
              return Promise.resolve({ data: state.ballots, error: null });
            }

            throw new Error(`unexpected ballots select fields: ${fields}`);
          }),
        };
      }

      if (table === 'anonymous_paper_blanks') {
        if (state.blockAnonymousPaperBlanks) {
          throw new Error('legacy source touched: anonymous_paper_blanks');
        }
      }

      if (table === 'candidates') {
        return {
          select: vi.fn(() => ({
            eq: vi.fn(async () => ({ data: state.candidates, error: null })),
          })),
        };
      }

      throw new Error(`unexpected table ${table}`);
    }),
  },
}));

describe('reporting route paperRecordedCount source', () => {
  beforeEach(() => {
    state.phase = 'VOTING';
    state.paperCount = 0;
    state.digitalCount = 0;
    state.ballots = [];
    state.candidates = [];
    state.blockAnonymousPaperBlanks = true;
  });

  it('returns 0 paperRecordedCount when no PAPER ballots exist', async () => {
    state.paperCount = 0;
    state.digitalCount = 2;
    state.ballots = [{ candidate_id: 'c1' }, { candidate_id: 'c1' }];
    state.candidates = [{ id: 'c1', full_name: 'Candidate 1' }];

    const { GET } = await import('@/app/api/admin/reporting/route');
    const res = await GET();
    const body = await res.json();

    expect(res.status).toBe(200);
    expect(body.paperRecordedCount).toBe(0);
    expect(body.totalVoteCount).toBe(2);
  });

  it('returns paperRecordedCount=1 when one PAPER ballot exists', async () => {
    state.paperCount = 1;
    state.digitalCount = 1;
    state.ballots = [{ candidate_id: 'c1' }, { candidate_id: 'c1' }];
    state.candidates = [{ id: 'c1', full_name: 'Candidate 1' }];

    const { GET } = await import('@/app/api/admin/reporting/route');
    const res = await GET();
    const body = await res.json();

    expect(res.status).toBe(200);
    expect(body.paperRecordedCount).toBe(1);
    expect(body.totalVoteCount).toBe(2);
  });

  it('does not touch legacy anonymous_paper_blanks source (known-bad sabotage guard)', async () => {
    state.paperCount = 0;
    state.digitalCount = 0;
    state.ballots = [];
    state.candidates = [];

    const { GET } = await import('@/app/api/admin/reporting/route');
    const res = await GET();
    expect(res.status).toBe(200);
  });
});
