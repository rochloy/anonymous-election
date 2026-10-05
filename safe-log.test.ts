import { describe, expect, it, vi, afterEach } from 'vitest';
import { classifyError, logError } from './lib/safe-log';

function captureLog(err: unknown): string {
  const spy = vi.spyOn(console, 'error').mockImplementation(() => {});
  logError('test-context', err);
  const logged = JSON.stringify(spy.mock.calls);
  spy.mockRestore();
  return logged;
}

describe('safe-log: fixed categories only, never message text', () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('logs code + category for a Postgres duplicate-key error, and no text from it', () => {
    const logged = captureLog({
      code: '23505',
      message: 'duplicate key value violates unique constraint "members_email_key"',
      details: 'Key (email)=(jane@example.com) already exists.',
      hint: 'some hint',
    });
    expect(logged).toContain('23505');
    expect(logged).toContain('integrity');
    for (const leaked of ['jane@example.com', 'members_email_key', 'duplicate', 'Key (email)', 'some hint']) {
      expect(logged).not.toContain(leaked);
    }
  });

  it('never logs free-text names from an Error message', () => {
    const logged = captureLog(new Error('member Jane Smith not found'));
    expect(logged).not.toContain('Jane Smith');
    expect(logged).not.toContain('member');
    expect(logged).toContain('runtime');
  });

  it('never logs stack, cause or token-like values', () => {
    const err = new Error('token 9f86d081884c7d659a2feaa0c55ad015 rejected', {
      cause: new Error('cause-secret'),
    });
    const logged = captureLog(err);
    for (const leaked of ['9f86d081884c7d65', 'cause-secret', 'at ']) {
      expect(logged).not.toContain(leaked);
    }
  });

  it('maps known codes to categories', () => {
    expect(classifyError({ code: 'PGRST202', message: 'x' }).category).toBe('api_schema');
    expect(classifyError({ code: 'PGRST116', message: 'x' }).category).toBe('api');
    expect(classifyError({ code: '42501', message: 'x' }).category).toBe('permission');
    expect(classifyError({ code: '42883', message: 'x' }).category).toBe('undefined_object');
    expect(classifyError({ code: '21000', message: 'x' }).category).toBe('cardinality');
    expect(classifyError({ code: 'P0001', message: 'x' }).category).toBe('db_raised');
    expect(classifyError({ code: '08006', message: 'x' }).category).toBe('connection');
  });

  it('drops non-plain codes and unknown error names', () => {
    const out = classifyError({ code: 'jane@example.com', name: 'Jane Smith', message: 'x' });
    expect(out.code).toBeUndefined();
    expect(out.kind).toBe('object');
    expect(out.category).toBe('unknown');
  });

  it('classifies fetch failures as network without logging the message', () => {
    const out = classifyError(new TypeError('fetch failed'));
    expect(out).toEqual({ code: undefined, category: 'network', kind: 'TypeError' });
  });
});
