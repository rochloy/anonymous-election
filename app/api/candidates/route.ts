import { NextResponse } from 'next/server';
import { logError } from '@/lib/safe-log';
import { supabasePublicRead } from '@/lib/supabase-public-read';

type Candidate = {
  id: string;
  full_name: string;
  statement: string | null;
};

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function projectCandidates(data: unknown): Candidate[] | null {
  if (!Array.isArray(data)) return null;

  const out: Candidate[] = [];
  for (const row of data) {
    if (!isObject(row)) return null;
    if (typeof row.id !== 'string' || typeof row.full_name !== 'string') return null;
    if (row.statement !== null && typeof row.statement !== 'string') return null;

    out.push({
      id: row.id,
      full_name: row.full_name,
      statement: row.statement,
    });
  }

  return out;
}

export async function GET() {
  try {
    const { data, error } = await supabasePublicRead.rpc('f4_candidates');

    if (error) {
      logError('candidates.rpc', error);
      return NextResponse.json({ error: 'Server error' }, { status: 500 });
    }

    const projected = projectCandidates(data);
    if (!projected) {
      logError('candidates.malformed', new Error('invalid f4_candidates shape'));
      return NextResponse.json({ error: 'Server error' }, { status: 500 });
    }

    return NextResponse.json(projected);
  } catch (err) {
    logError('candidates.error', err);
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}
