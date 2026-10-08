import { NextResponse } from 'next/server';
import { logError } from '@/lib/safe-log';
import { supabasePublicRead } from '@/lib/supabase-public-read';

const PHASES = ['SETUP', 'NOMINATION', 'NOMINATION_CLOSED', 'VOTING', 'VOTING_CLOSED', 'COMPLETED'] as const;
type ElectionPhase = (typeof PHASES)[number];

type ResultRow = {
  id: string;
  full_name: string;
  statement: string | null;
  votes: number;
  percentage: number;
};

type PublishedResults = {
  published: true;
  phase: ElectionPhase;
  totalVotes: number;
  results: ResultRow[];
  receiptStatus: null | { searchedCode: string; found: boolean };
};

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function isKnownPhase(value: unknown): value is ElectionPhase {
  return typeof value === 'string' && PHASES.includes(value as ElectionPhase);
}

function normalizeReceipt(raw: string | null): string | null | 'invalid' {
  if (!raw) return null;
  const trimmed = raw.trim();
  if (!trimmed) return null;
  if (trimmed.length > 32) return 'invalid';
  return trimmed.toUpperCase();
}

function parseResults(data: unknown, searchedCode: string | null): { published: false; phase: ElectionPhase } | PublishedResults | null {
  if (!isObject(data) || typeof data.published !== 'boolean' || !isKnownPhase(data.phase)) {
    return null;
  }

  if (data.published === false) {
    if (['VOTING_CLOSED', 'COMPLETED'].includes(data.phase)) {
      return null;
    }
    return { published: false, phase: data.phase };
  }

  if (!['VOTING_CLOSED', 'COMPLETED'].includes(data.phase)) {
    return null;
  }

  if (!Number.isInteger(data.totalVotes) || (data.totalVotes as number) < 0 || !Array.isArray(data.results)) {
    return null;
  }

  const projected: ResultRow[] = [];
  for (const row of data.results) {
    if (!isObject(row)) return null;
    if (typeof row.id !== 'string' || typeof row.full_name !== 'string') return null;
    if (row.statement !== null && typeof row.statement !== 'string') return null;
    if (!Number.isInteger(row.votes) || (row.votes as number) < 0) return null;
    if (typeof row.percentage !== 'number' || !Number.isFinite(row.percentage) || row.percentage < 0) return null;

    projected.push({
      id: row.id,
      full_name: row.full_name,
      statement: row.statement,
      votes: row.votes as number,
      percentage: row.percentage as number,
    });
  }

  let receiptStatus: PublishedResults['receiptStatus'] = null;
  if (searchedCode) {
    if (typeof data.receipt_found !== 'boolean') return null;
    receiptStatus = { searchedCode, found: data.receipt_found };
  }

  return {
    published: true,
    phase: data.phase,
    totalVotes: data.totalVotes as number,
    results: projected,
    receiptStatus,
  };
}

export async function GET(req: Request) {
  try {
    const { searchParams } = new URL(req.url);
    const normalizedReceipt = normalizeReceipt(searchParams.get('receipt'));
    if (normalizedReceipt === 'invalid') {
      return NextResponse.json({ error: 'Invalid request' }, { status: 400 });
    }

    const { data, error } = await supabasePublicRead.rpc('f4_results', {
      p_receipt_code: normalizedReceipt ? normalizedReceipt.toLowerCase() : null,
    });
    if (error) {
      logError('results.rpc', error);
      return NextResponse.json({ error: 'Error fetching results' }, { status: 500 });
    }

    const parsed = parseResults(data, normalizedReceipt);
    if (!parsed) {
      logError('results.malformed', new Error('invalid f4_results shape'));
      return NextResponse.json({ error: 'Error fetching results' }, { status: 500 });
    }

    if (parsed.published === false) {
      return NextResponse.json(parsed);
    }

    return NextResponse.json(parsed);
  } catch (err) {
    logError('results.error', err);
    return NextResponse.json({ error: 'Error fetching results' }, { status: 500 });
  }
}
