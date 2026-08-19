import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { requireAdmin, getAdminSession } from '../auth';
import crypto from 'crypto';

interface CSVRow {
  full_name?: string;
  name?: string;
  email?: string;
  phone?: string;
  member_code?: string;
}

function parseCSV(text: string): CSVRow[] {
  const lines = text.split(/\r?\n/).filter(line => line.trim().length > 0);
  if (lines.length < 2) return [];

  const headers = lines[0].split(',').map(h => h.trim().toLowerCase().replace(/^"|"$/g, ''));
  const records: CSVRow[] = [];

  // Sanitize cell values to prevent formula injection (CSV injection)
  // Prefix values starting with =, +, -, @, \t, \r with a single quote
  function sanitizeCell(val: string): string {
    if (/^[=+\-@\t\r]/.test(val)) {
      return "'" + val;
    }
    return val;
  }

  for (let i = 1; i < lines.length; i++) {
    const rawLine = lines[i];
    const values = rawLine.match(/(".*?"|[^",\s]+)(?=\s*,|\s*$)/g) || rawLine.split(',');

    const record: Record<string, string> = {};
    headers.forEach((header, index) => {
      let val = values[index] ? values[index].trim() : '';
      if (val.startsWith('"') && val.endsWith('"')) {
        val = val.slice(1, -1).replace(/""/g, '"');
      }
      record[header] = sanitizeCell(val);
    });

    if (record.full_name || record.name) {
      records.push(record as CSVRow);
    }
  }
  return records;
}

export async function POST(req: Request) {
  const authFail = await requireAdmin();
  if (authFail) return authFail;

  const adminSession = await getAdminSession();

  try {
    const { csv } = await req.json();

    if (!csv || typeof csv !== 'string') {
      return NextResponse.json({ error: 'CSV content is required' }, { status: 400 });
    }

    const records = parseCSV(csv);

    if (records.length === 0) {
      return NextResponse.json({ error: 'No valid records found in CSV' }, { status: 400 });
    }

    let successCount = 0;
    let errorCount = 0;
    const errors: string[] = [];

    for (const record of records) {
      const fullName = record.full_name || record.name;
      const email = record.email?.toLowerCase().trim() || null;
      const phone = record.phone?.trim() || null;

      if (!fullName) {
        errorCount++;
        errors.push(`Row missing name: ${JSON.stringify(record)}`);
        continue;
      }

      const memberCode = record.member_code || `M-${crypto.randomBytes(4).toString('hex')}`;

      const { error } = await supabaseServer
        .from('members')
        .upsert(
          {
            member_code: memberCode,
            full_name: fullName,
            email: email,
            phone: phone,
            is_active: true,
          },
          { onConflict: 'member_code' }
        );

      if (error) {
        errorCount++;
        errors.push(`Failed to import ${fullName} (${memberCode}): ${error.message}`);
      } else {
        successCount++;
      }
    }

    // Audit log
    await supabaseServer
      .from('vote_audit_log')
      .insert({
        action: 'MEMBERS_BULK_IMPORT',
        admin_id: adminSession?.id || null,
        details: { total: records.length, success: successCount, errors: errorCount, admin_ip: adminSession?.ip_address },
      });

    return NextResponse.json({
      success: true,
      total: records.length,
      imported: successCount,
      failed: errorCount,
      errors: errors.slice(0, 10), // Return first 10 errors
    });
  } catch (err: unknown) {
    const errorMsg = err instanceof Error ? err.message : 'Server error';
    return NextResponse.json({ error: errorMsg }, { status: 500 });
  }
}