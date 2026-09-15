import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';

type VerifyResult = {
  found: true;
  channel: 'DIGITAL' | 'PAPER';
  cast_date: string;
  receipt_match?: boolean;
};

export async function GET(req: Request) {
  try {
    const { searchParams } = new URL(req.url);
    const ballotId = searchParams.get('ballot_id')?.trim();
    const receiptCode = searchParams.get('receipt_code')?.trim();
    const receiptCodePattern = /^VC-([0-9a-fA-F]{10})$/;

    if (!ballotId && !receiptCode) {
      return NextResponse.json({ error: 'ballot_id or receipt_code is required' }, { status: 400 });
    }

    let canonicalReceiptCode: string | null = null;
    if (receiptCode) {
      const match = receiptCode.match(receiptCodePattern);
      if (!match) {
        return NextResponse.json({ found: false });
      }
      canonicalReceiptCode = `VC-${match[1].toLowerCase()}`;
    }

    let ballot: {
      ballot_id: string;
      receipt_code: string;
      channel: 'DIGITAL' | 'PAPER';
      cast_date: string;
    } | null = null;

    if (ballotId) {
      const { data, error } = await supabaseServer
        .from('ballots')
        .select('ballot_id, receipt_code, channel, cast_date')
        .eq('ballot_id', ballotId)
        .single();

      if (!error && data) {
        ballot = data;
      }
    }

    if (!ballot && canonicalReceiptCode) {
      const { data, error } = await supabaseServer
        .from('ballots')
        .select('ballot_id, receipt_code, channel, cast_date')
        .eq('receipt_code', canonicalReceiptCode)
        .single();

      if (!error && data) {
        ballot = data;
      }
    }

    if (!ballot) {
      return NextResponse.json({ found: false });
    }

    const result: VerifyResult = {
      found: true,
      channel: ballot.channel,
      cast_date: ballot.cast_date,
    };

    if (ballotId && canonicalReceiptCode) {
      result.receipt_match = ballot.receipt_code === canonicalReceiptCode;
    }

    return NextResponse.json(result);
  } catch {
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}
