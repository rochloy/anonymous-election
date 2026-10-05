import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';

const EXPECTED_SCOPED_TABLES = [
  'candidates',
  'tokens',
  'anonymous_nominations',
  'ballots',
  'paper_ballots',
  'paper_ballot_batches',
  'vote_audit_log',
  'eligibility_adjudications',
  'phase_change_tokens',
  'wipe_confirmation_tokens',
  'admin_sessions',
  'rate_limit_hits',
  'anonymous_paper_blanks',
  'anonymous_digital_credentials',
  'digital_credential_reservations',
  'nomination_adjudications',
  'participation_audit',
  'ballot_audit_log',
];

function extractTruncateTableList(sql: string): string[] {
  const match = sql.match(/TRUNCATE\s+([\s\S]*?)\s+CASCADE\s*;/i);
  if (!match) {
    throw new Error('TRUNCATE ... CASCADE statement not found');
  }

  return match[1]
    .replace(/\s+/g, ' ')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
}

function expectHasRequiredScope(sql: string): void {
  const truncateTables = extractTruncateTableList(sql);
  const truncateSet = new Set(truncateTables);
  const postAssertSet = new Set(
    [...sql.matchAll(/EXISTS \(SELECT 1 FROM ([a-z_]+)\)/g)].map((m) => m[1])
  );

  for (const table of EXPECTED_SCOPED_TABLES) {
    expect(truncateSet.has(table), `missing ${table} in TRUNCATE scope`).toBe(true);
    expect(postAssertSet.has(table), `missing ${table} in post-wipe emptiness assertion`).toBe(true);
  }

  expect(truncateSet.size).toBe(EXPECTED_SCOPED_TABLES.length);
  expect(postAssertSet.size).toBe(EXPECTED_SCOPED_TABLES.length);
  expect(sql).toContain('EXISTS (SELECT 1 FROM members WHERE id IS NOT NULL)');
  expect(sql).toContain('IF NOT FOUND OR v_phase IS NULL THEN');
  expect(sql).toContain('IF v_token_record.expires_at <= clock_timestamp() THEN');

  const tokenLockIdx = sql.indexOf('FROM wipe_confirmation_tokens');
  const tokenLockForUpdateIdx = sql.indexOf('FOR UPDATE;', tokenLockIdx);
  const expiryIdx = sql.indexOf('IF v_token_record.expires_at <= clock_timestamp() THEN');
  expect(tokenLockIdx).toBeGreaterThan(-1);
  expect(tokenLockForUpdateIdx).toBeGreaterThan(tokenLockIdx);
  expect(expiryIdx).toBeGreaterThan(tokenLockForUpdateIdx);
}

describe('wipe completeness migration regression guard', () => {
  it('item 45 includes required tables in TRUNCATE scope and emptiness assertions', () => {
    const sql = readFileSync('supabase/migration_wipe_completeness.sql', 'utf8');
    expectHasRequiredScope(sql);
  });

  it('known-bad item 43 fails required-scope helper (negative regression proof)', () => {
    const oldSql = readFileSync('supabase/migration_wipe_email_confirmation.sql', 'utf8');
    expect(() => expectHasRequiredScope(oldSql)).toThrow();
  });

  it('mutating one original scoped table out of both guards fails helper (tokens example)', () => {
    const sql = readFileSync('supabase/migration_wipe_completeness.sql', 'utf8');
    const mutated = sql
      .replace(/\btokens,\s*/, '')
      .replace(/\n\s*OR EXISTS \(SELECT 1 FROM tokens\)/, '');
    expect(() => expectHasRequiredScope(mutated)).toThrow();
  });

  it('sabotage now() replacement fails helper (expiry must use wall clock)', () => {
    const sql = readFileSync('supabase/migration_wipe_completeness.sql', 'utf8');
    const mutated = sql.replace('clock_timestamp()', 'now()');
    expect(() => expectHasRequiredScope(mutated)).toThrow();
  });

  it('read-only verifier has fail-loud ACL assertions and clock_timestamp body check', () => {
    const verifierSql = readFileSync('supabase/verify_wipe_completeness.sql', 'utf8');
    expect(verifierSql).toContain('Expected exactly 2 wipe_election_data(uuid, character varying) signatures across public/private');
    expect(verifierSql).toContain('Legacy/extra wipe_election_data overloads found');
    expect(verifierSql).toContain('ACL check failed on wipe_election_data(uuid, character varying)');
    expect(verifierSql).toContain('Missing post-lock wall-clock expiry guard (clock_timestamp)');
  });
});
