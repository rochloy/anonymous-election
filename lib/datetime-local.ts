// Conversions between <input type="datetime-local"> values (browser-local wall time, no zone)
// and zoned ISO-8601 timestamps stored in TIMESTAMPTZ columns.

/** Browser-local "YYYY-MM-DDTHH:MM" -> UTC ISO string ("...Z"), or null when empty/invalid. */
export function localInputToIso(value: string): string | null {
  if (!value) return null;
  const d = new Date(value); // no zone suffix => parsed as local time
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

/** Stored timestamp (any zoned ISO string) -> browser-local "YYYY-MM-DDTHH:MM", or '' when empty/invalid. */
export function isoToLocalInput(iso: string | null | undefined): string {
  if (!iso) return '';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  return new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 16);
}

/** True when the string is an ISO timestamp carrying an explicit zone (Z or ±HH:MM). */
export function isZonedIso(value: string): boolean {
  return /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})$/.test(value)
    && !Number.isNaN(new Date(value).getTime());
}
