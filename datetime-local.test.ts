// Run in a non-UTC zone so a missing conversion cannot pass by accident.
process.env.TZ = 'Europe/Berlin';

import { describe, it, expect } from 'vitest';
import { localInputToIso, isoToLocalInput, isZonedIso } from '@/lib/datetime-local';

describe('datetime-local conversions (TZ=Europe/Berlin)', () => {
  it('test zone is really non-UTC', () => {
    expect(new Date('2026-10-05T12:00:00Z').getTimezoneOffset()).toBe(-120); // CEST
  });

  it('local input -> UTC ISO applies the zone offset', () => {
    expect(localInputToIso('2026-10-05T16:17')).toBe('2026-10-05T14:17:00.000Z');
    expect(localInputToIso('2026-01-15T09:00')).toBe('2026-01-15T08:00:00.000Z'); // CET
  });

  it('UTC ISO -> local input applies the zone offset', () => {
    expect(isoToLocalInput('2026-10-05T14:17:00+00:00')).toBe('2026-10-05T16:17');
    expect(isoToLocalInput('2026-01-15T08:00:00.000Z')).toBe('2026-01-15T09:00');
  });

  it('round-trips without drift', () => {
    for (const v of ['2026-10-05T16:17', '2026-03-29T12:30', '2026-12-31T23:59']) {
      expect(isoToLocalInput(localInputToIso(v))).toBe(v);
    }
  });

  it('empty/invalid values', () => {
    expect(localInputToIso('')).toBeNull();
    expect(localInputToIso('garbage')).toBeNull();
    expect(isoToLocalInput(null)).toBe('');
    expect(isoToLocalInput('garbage')).toBe('');
  });

  it('isZonedIso rejects zone-less strings (the original bug input)', () => {
    expect(isZonedIso('2026-10-05T16:17')).toBe(false);
    expect(isZonedIso('2026-10-05T16:17:00')).toBe(false);
    expect(isZonedIso('2026-10-05T14:17:00.000Z')).toBe(true);
    expect(isZonedIso('2026-10-05T16:17:00+02:00')).toBe(true);
    expect(isZonedIso('not a date')).toBe(false);
  });
});
