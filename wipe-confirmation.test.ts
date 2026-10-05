import { beforeEach, describe, expect, it, vi } from 'vitest';

const state = vi.hoisted(() => ({
  requireAdminWithCsrfResult: null as Response | null,
  adminSessionId: 'session-1',
  electionPhase: 'SETUP',
  tokenRow: null as null | { token_hash: string; confirmed_at: string | null; expires_at: string },
  upsertError: null as unknown,
  requestTokenDeleted: false,
  cancelDeletedForSession: '',
  cancelDeletedForHash: '',
  updatedConfirmHash: '',
  updateUsedExpiryGt: false,
  rpcCalled: false,
  rpcArgs: null as null | Record<string, unknown>,
  rpcError: null as unknown,
  rpcData: [{ success: true, message: 'ok' }] as Array<{ success: boolean; message: string }>,
  resendError: null as unknown,
  resendThrows: false,
}));

vi.mock('resend', () => {
  class Resend {
    emails = {
      send: vi.fn(async () => {
        if (state.resendThrows) throw new Error('send failed');
        return { error: state.resendError };
      }),
    };
  }
  return { Resend };
});

vi.mock('@/app/api/admin/auth', () => ({
  requireAdminWithCsrf: vi.fn(async () => state.requireAdminWithCsrfResult),
  getAdminSession: vi.fn(async () => ({ id: state.adminSessionId, ip_address: null, user_agent: null, expires_at: null, scope: 'desktop' as const })),
}));

vi.mock('@/lib/supabase-server', () => {
  const from = vi.fn((table: string) => {
    if (table === 'election_settings') {
      return {
        select: vi.fn(() => ({
          eq: vi.fn(() => ({
            single: vi.fn(async () => ({ data: { current_phase: state.electionPhase }, error: null })),
          })),
        })),
      };
    }

    if (table === 'wipe_confirmation_tokens') {
      return {
        select: vi.fn(() => ({
          eq: vi.fn((field: string, val: string) => ({
            eq: vi.fn(() => ({
              maybeSingle: vi.fn(async () => ({ data: state.tokenRow, error: null })),
            })),
            maybeSingle: vi.fn(async () => ({ data: state.tokenRow, error: null })),
            is: vi.fn(() => ({
              select: vi.fn(async () => ({ data: state.tokenRow ? [state.tokenRow] : [], error: null })),
            })),
            delete: vi.fn(async () => {
              if (field === 'admin_session_id') state.requestTokenDeleted = true;
              if (field === 'token_hash') state.requestTokenDeleted = true;
              state.cancelDeletedForSession = val;
              return { error: null };
            }),
            update: vi.fn(() => ({
              eq: vi.fn((f2: string, v2: string) => ({
                is: vi.fn(() => ({
                  gt: vi.fn(() => ({
                    select: vi.fn(async () => {
                      state.updatedConfirmHash = f2 === 'token_hash' ? v2 : '';
                      state.updateUsedExpiryGt = true;
                      return { data: state.tokenRow ? [state.tokenRow] : [], error: null };
                    }),
                  })),
                })),
              })),
            })),
          })),
        })),
        upsert: vi.fn(async () => ({ error: state.upsertError })),
        delete: vi.fn(() => ({
          eq: vi.fn((field: string, val: string) => {
            if (field === 'admin_session_id') {
              state.requestTokenDeleted = true;
              state.cancelDeletedForSession = val;
              return {
                eq: vi.fn((field2: string, val2: string) => {
                  if (field2 === 'token_hash') {
                    state.cancelDeletedForHash = val2;
                  }
                  return Promise.resolve({ error: null });
                }),
              };
            }
            return Promise.resolve({ error: null });
          }),
        })),
        update: vi.fn(() => ({
          eq: vi.fn(() => ({
            is: vi.fn(() => ({
              gt: vi.fn(() => ({
                select: vi.fn(async () => {
                  state.updateUsedExpiryGt = true;
                  return { data: state.tokenRow ? [state.tokenRow] : [], error: null };
                }),
              })),
              select: vi.fn(async () => ({ data: state.tokenRow ? [state.tokenRow] : [], error: null })),
            })),
          })),
        })),
      };
    }

    throw new Error(`unexpected table: ${table}`);
  });

  return {
    supabaseServer: {
      from,
      rpc: vi.fn(async (_fn: string, args: Record<string, unknown>) => {
        state.rpcCalled = true;
        state.rpcArgs = args;
        if (state.rpcError) return { data: null, error: state.rpcError };
        return { data: state.rpcData, error: null };
      }),
    },
  };
});

describe('wipe email confirmation route', () => {
  beforeEach(() => {
    state.requireAdminWithCsrfResult = null;
    state.adminSessionId = 'session-1';
    state.electionPhase = 'SETUP';
    state.tokenRow = null;
    state.upsertError = null;
    state.requestTokenDeleted = false;
    state.cancelDeletedForSession = '';
    state.cancelDeletedForHash = '';
    state.updatedConfirmHash = '';
    state.updateUsedExpiryGt = false;
    state.rpcCalled = false;
    state.rpcArgs = null;
    state.rpcError = null;
    state.rpcData = [{ success: true, message: 'wiped' }];
    state.resendError = null;
    state.resendThrows = false;
    process.env.ADMIN_EMAIL = 'admin@example.com';
  });

  it('request without ADMIN_EMAIL returns error', async () => {
    delete process.env.ADMIN_EMAIL;
    const { POST } = await import('@/app/api/admin/wipe-database/route');
    const res = await POST(new Request('http://test/api/admin/wipe-database', { method: 'POST', body: JSON.stringify({ action: 'request' }) }));
    expect(res.status).toBe(500);
  });

  it('request resend error deletes row and returns 502', async () => {
    state.resendError = { code: 'send_failed' };
    const { POST } = await import('@/app/api/admin/wipe-database/route');
    const res = await POST(new Request('http://test/api/admin/wipe-database', { method: 'POST', body: JSON.stringify({ action: 'request' }) }));
    expect(res.status).toBe(502);
    expect(state.requestTokenDeleted).toBe(true);
    expect(state.cancelDeletedForSession).toBe('session-1');
    expect(state.cancelDeletedForHash).toBeTruthy();
  });

  it('confirm_link rejects missing/expired/used tokens', async () => {
    const { POST } = await import('@/app/api/admin/wipe-database/route');
    const bad = await POST(new Request('http://test/api/admin/wipe-database', { method: 'POST', body: JSON.stringify({ action: 'confirm_link', token: 'x' }) }));
    expect(bad.status).toBe(400);

    state.tokenRow = { token_hash: 'h', confirmed_at: null, expires_at: new Date(Date.now() - 1000).toISOString() };
    const expired = await POST(new Request('http://test/api/admin/wipe-database', { method: 'POST', body: JSON.stringify({ action: 'confirm_link', token: 'x' }) }));
    expect(expired.status).toBe(400);

    state.tokenRow = { token_hash: 'h', confirmed_at: new Date().toISOString(), expires_at: new Date(Date.now() + 60_000).toISOString() };
    const used = await POST(new Request('http://test/api/admin/wipe-database', { method: 'POST', body: JSON.stringify({ action: 'confirm_link', token: 'x' }) }));
    expect(used.status).toBe(400);
  });

  it('confirm_link success path uses expiry update predicate', async () => {
    state.tokenRow = { token_hash: 'h', confirmed_at: null, expires_at: new Date(Date.now() + 60_000).toISOString() };
    const { POST } = await import('@/app/api/admin/wipe-database/route');
    const ok = await POST(new Request('http://test/api/admin/wipe-database', { method: 'POST', body: JSON.stringify({ action: 'confirm_link', token: 'x' }) }));
    expect(ok.status).toBe(200);
    expect(state.updateUsedExpiryGt).toBe(true);
  });

  it('execute wrong phrases returns 400 and does not call RPC', async () => {
    const { POST } = await import('@/app/api/admin/wipe-database/route');
    const res = await POST(new Request('http://test/api/admin/wipe-database', { method: 'POST', body: JSON.stringify({ action: 'execute', confirm1: 'NOPE', confirm2: 'NOPE' }) }));
    expect(res.status).toBe(400);
    expect(state.rpcCalled).toBe(false);
  });

  it('execute blocks missing/unconfirmed/expired rows', async () => {
    const { POST } = await import('@/app/api/admin/wipe-database/route');
    const missing = await POST(new Request('http://test/api/admin/wipe-database', { method: 'POST', body: JSON.stringify({ action: 'execute', confirm1: 'WIPE', confirm2: 'DELETE ALL DATA' }) }));
    expect(missing.status).toBe(400);
    expect(state.rpcCalled).toBe(false);

    state.tokenRow = { token_hash: 'abc', confirmed_at: null, expires_at: new Date(Date.now() + 60_000).toISOString() };
    const unconfirmed = await POST(new Request('http://test/api/admin/wipe-database', { method: 'POST', body: JSON.stringify({ action: 'execute', confirm1: 'WIPE', confirm2: 'DELETE ALL DATA' }) }));
    expect(unconfirmed.status).toBe(400);
    expect(state.rpcCalled).toBe(false);

    state.tokenRow = { token_hash: 'abc', confirmed_at: new Date().toISOString(), expires_at: new Date(Date.now() - 60_000).toISOString() };
    const expired = await POST(new Request('http://test/api/admin/wipe-database', { method: 'POST', body: JSON.stringify({ action: 'execute', confirm1: 'WIPE', confirm2: 'DELETE ALL DATA' }) }));
    expect(expired.status).toBe(400);
    expect(state.rpcCalled).toBe(false);
  });

  it('execute happy path calls rpc with session id + hash', async () => {
    state.tokenRow = { token_hash: 'stored_hash', confirmed_at: new Date().toISOString(), expires_at: new Date(Date.now() + 60_000).toISOString() };
    const { POST } = await import('@/app/api/admin/wipe-database/route');
    const res = await POST(new Request('http://test/api/admin/wipe-database', { method: 'POST', body: JSON.stringify({ action: 'execute', confirm1: 'WIPE', confirm2: 'DELETE ALL DATA' }) }));
    expect(res.status).toBe(200);
    expect(state.rpcCalled).toBe(true);
    expect(state.rpcArgs).toEqual({ p_admin_id: 'session-1', p_token_hash: 'stored_hash' });
  });

  it('status never returns token/hash and cancel deletes current session row', async () => {
    state.tokenRow = { token_hash: 'hidden_hash', confirmed_at: null, expires_at: new Date(Date.now() + 60_000).toISOString() };
    const { POST } = await import('@/app/api/admin/wipe-database/route');
    const statusRes = await POST(new Request('http://test/api/admin/wipe-database', { method: 'POST', body: JSON.stringify({ action: 'status' }) }));
    expect(statusRes.status).toBe(200);
    const body = await statusRes.json();
    expect(body.token_hash).toBeUndefined();
    expect(body.token).toBeUndefined();

    const cancelRes = await POST(new Request('http://test/api/admin/wipe-database', { method: 'POST', body: JSON.stringify({ action: 'cancel' }) }));
    expect(cancelRes.status).toBe(200);
    expect(state.cancelDeletedForSession).toBe('session-1');
  });
});
