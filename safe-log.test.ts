import { describe, expect, it, vi, afterEach } from 'vitest';
import { logError, sanitizeErrorForLog } from './lib/safe-log';

describe('safe-log redaction', () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('redacts postgres-like key/email fragments and keeps code', () => {
    const err = {
      code: '23505',
      message: 'duplicate key value violates unique constraint "members_email_key"',
      details: 'Key (email)=(jane@example.com) already exists.',
    };

    const spy = vi.spyOn(console, 'error').mockImplementation(() => {});
    logError('test', err);

    const payload = spy.mock.calls[0]?.[1] as { code?: string; message: string };
    expect(payload.code).toBe('23505');
    expect(payload.message).not.toContain('jane@example.com');
    expect(payload.message).not.toContain('members_email_key');
    expect(payload.message).toContain('"<redacted>"');
  });

  it('redacts postgres key/value fragments that appear in the message itself', () => {
    const out = sanitizeErrorForLog({ code: '23505', message: 'Key (email)=(jane@example.com) already exists.' });
    expect(out.code).toBe('23505');
    expect(out.message).not.toContain('jane@example.com');
    expect(out.message).toContain('(<redacted>)=(<redacted>)');
  });

  it('never logs details, hint or stack', () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {});
    logError('test', { code: 'X', message: 'boom', details: 'secret-detail', hint: 'secret-hint', stack: 'secret-stack' });
    const logged = JSON.stringify(spy.mock.calls);
    expect(logged).not.toContain('secret-detail');
    expect(logged).not.toContain('secret-hint');
    expect(logged).not.toContain('secret-stack');
  });

  it('redacts unquoted identifiers, tokens and phone numbers', () => {
    const out = sanitizeErrorForLog(
      new Error(
        'member 123e4567-e89b-12d3-a456-426614174000 token 9f86d081884c7d659a2feaa0c55ad015 ballot PAPER:abcd1234.ef01 receipt VC-0a1b2c3d4e code M-1a2b3c4d phone +63 917 123 4567'
      )
    );
    for (const leaked of ['123e4567', '9f86d081884c7d65', 'PAPER:abcd', 'VC-0a1b2c3d4e', 'M-1a2b3c4d', '917 123 4567']) {
      expect(out.message).not.toContain(leaked);
    }
  });

  it('drops non-plain error codes', () => {
    expect(sanitizeErrorForLog({ code: 'jane@example.com', message: 'x' }).code).toBeUndefined();
    expect(sanitizeErrorForLog({ code: 'PGRST202', message: 'x' }).code).toBe('PGRST202');
  });

  it('redacts emails in error messages', () => {
    const out = sanitizeErrorForLog(new Error('failed for jane@example.com because token invalid'));
    expect(out.message).toContain('<email>');
    expect(out.message).not.toContain('jane@example.com');
  });

  it('redacts quoted values', () => {
    const out = sanitizeErrorForLog({ message: "cannot use token 'abc123' in phase \"VOTING\"" });
    expect(out.message).toContain("'<redacted>'");
    expect(out.message).toContain('"<redacted>"');
    expect(out.message).not.toContain('abc123');
    expect(out.message).not.toContain('VOTING');
  });
});
