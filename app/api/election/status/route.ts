import { NextResponse } from 'next/server';
import { logError } from '@/lib/safe-log';
import { supabasePublicRead } from '@/lib/supabase-public-read';

const PHASES = ['SETUP', 'NOMINATION', 'NOMINATION_CLOSED', 'VOTING', 'VOTING_CLOSED', 'COMPLETED'] as const;
type ElectionPhase = (typeof PHASES)[number];

type RpcElectionStatus = {
  phase: unknown;
  current_phase: unknown;
  nomination_start: unknown;
  nomination_end: unknown;
  voting_start: unknown;
  voting_end: unknown;
  allow_write_ins: unknown;
  max_nominees_per_member: unknown;
};

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function isKnownPhase(value: unknown): value is ElectionPhase {
  return typeof value === 'string' && PHASES.includes(value as ElectionPhase);
}

function isNullableIsoDateTime(value: unknown): boolean {
  return value === null || (typeof value === 'string' && Number.isFinite(Date.parse(value)));
}

function isNonNegativeInteger(value: unknown): value is number {
  return typeof value === 'number' && Number.isInteger(value) && value >= 0;
}

function parseStatus(data: unknown): {
  phase: ElectionPhase;
  current_phase: ElectionPhase;
  nomination_start: string | null;
  nomination_end: string | null;
  voting_start: string | null;
  voting_end: string | null;
  allow_write_ins: boolean;
  max_nominees_per_member: number;
} | null {
  if (!isObject(data)) return null;
  const src = data as RpcElectionStatus;

  if (!isKnownPhase(src.phase) || !isKnownPhase(src.current_phase) || src.phase !== src.current_phase) {
    return null;
  }
  if (
    !isNullableIsoDateTime(src.nomination_start) ||
    !isNullableIsoDateTime(src.nomination_end) ||
    !isNullableIsoDateTime(src.voting_start) ||
    !isNullableIsoDateTime(src.voting_end)
  ) {
    return null;
  }
  if (typeof src.allow_write_ins !== 'boolean' || !isNonNegativeInteger(src.max_nominees_per_member)) {
    return null;
  }

  return {
    phase: src.phase,
    current_phase: src.current_phase,
    nomination_start: src.nomination_start as string | null,
    nomination_end: src.nomination_end as string | null,
    voting_start: src.voting_start as string | null,
    voting_end: src.voting_end as string | null,
    allow_write_ins: src.allow_write_ins,
    max_nominees_per_member: src.max_nominees_per_member,
  };
}

export async function GET() {
  try {
    const { data, error } = await supabasePublicRead.rpc('f4_election_status');
    if (error) {
      logError('election/status.rpc', error);
      return NextResponse.json({ error: 'Server error' }, { status: 500 });
    }

    const parsed = parseStatus(data);
    if (!parsed) {
      logError('election/status.malformed', new Error('invalid f4_election_status shape'));
      return NextResponse.json({ error: 'Server error' }, { status: 500 });
    }

    return NextResponse.json(parsed);
  } catch (err) {
    logError('election/status.error', err);
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}
