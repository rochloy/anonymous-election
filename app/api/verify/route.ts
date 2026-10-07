import { NextResponse } from 'next/server';
import { logError } from '@/lib/safe-log';
import { supabasePublicRead } from '@/lib/supabase-public-read';

type VerifyResult = {
  found: true;
  channel: 'DIGITAL' | 'PAPER';
  cast_date: string;
  receipt_match?: boolean;
};

type VerifyFoundShape = {
  found: true;
  channel: 'DIGITAL' | 'PAPER';
  cast_date: string;
  receipt_match?: boolean;
};

const RECEIPT_RE = /^VC-([0-9A-F]{10})$/;

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function isDateOnly(value: unknown): value is string {
  return typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value);
}

function normalizeReceipt(raw: string | null): string | null | 'invalid' {
  if (!raw) return null;
  const trimmed = raw.trim();
  if (trimmed.length > 32) return 'invalid';
  const upper = trimmed.toUpperCase();
  const match = upper.match(RECEIPT_RE);
  if (!match) return 'invalid';
  return `VC-${match[1].toLowerCase()}`;
}

function parseVerifyResponse(data: unknown, paired: boolean): VerifyResult | { found: false } | null {
  if (!isObject(data) || typeof data.found !== 'boolean') return null;
  if (data.found === false) return { found: false };

  if ((data.channel !== 'DIGITAL' && data.channel !== 'PAPER') || !isDateOnly(data.cast_date)) {
    return null;
  }

  const out: VerifyFoundShape = {
    found: true,
    channel: data.channel,
    cast_date: data.cast_date,
  };

  if (paired) {
    if (typeof data.receipt_match !== 'boolean') return null;
    out.receipt_match = data.receipt_match;
  }

  return out;
}

export async function GET(req: Request) {
  try {
    const { searchParams } = new URL(req.url);
    const ballotId = searchParams.get('ballot_id')?.trim();
    const receiptCode = searchParams.get('receipt_code');

    if (!ballotId && !receiptCode) {
      return NextResponse.json({ error: 'ballot_id or receipt_code is required' }, { status: 400 });
    }

    if (ballotId && ballotId.length > 256) {
      return NextResponse.json({ found: false });
    }

    const normalizedReceipt = normalizeReceipt(receiptCode);
    if (normalizedReceipt === 'invalid') {
      return NextResponse.json({ found: false });
    }

    const paired = Boolean(ballotId && normalizedReceipt);

    const { data, error } = await supabasePublicRead.rpc('f4_verify_ballot', {
      p_ballot_id: ballotId ?? null,
      p_receipt_code: normalizedReceipt ?? null,
    });
    if (error) {
      logError('verify.rpc', error);
      return NextResponse.json({ error: 'Server error' }, { status: 500 });
    }

    const parsed = parseVerifyResponse(data, paired);
    if (!parsed) {
      logError('verify.malformed', new Error('invalid f4_verify_ballot shape'));
      return NextResponse.json({ error: 'Server error' }, { status: 500 });
    }

    return NextResponse.json(parsed);
  } catch (err) {
    logError('verify.error', err);
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}
