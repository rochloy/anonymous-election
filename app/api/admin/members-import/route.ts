import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { requireAdmin, requireAdminWithCsrf, getAdminSession } from '../auth';
import crypto from 'crypto';
import { validateEmail, validatePhone, validateLength, INPUT_LIMITS } from '@/lib/input-validation';
import { insertAuditLog } from '@/lib/audit-log';

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

  // Proper CSV parsing that handles empty fields
  function parseCSVLine(line: string): string[] {
    const result: string[] = [];
    let current = '';
    let inQuotes = false;
    
    for (let i = 0; i < line.length; i++) {
      const char = line[i];
      const nextChar = line[i + 1];
      
      if (char === '"') {
        if (inQuotes && nextChar === '"') {
          // Escaped quote
          current += '"';
          i++; // Skip next quote
        } else {
          // Toggle quote state
          inQuotes = !inQuotes;
        }
      } else if (char === ',' && !inQuotes) {
        // Field separator
        result.push(current);
        current = '';
      } else {
        current += char;
      }
    }
    // Push the last field
    result.push(current);
    return result;
  }

  for (let i = 1; i < lines.length; i++) {
    const rawLine = lines[i];
    const values = parseCSVLine(rawLine);

    const record: Record<string, string> = {};
    headers.forEach((header, index) => {
      let val = values[index] ? values[index].trim() : '';
      if (val.startsWith('"') && val.endsWith('"')) {
        val = val.slice(1, -1).replace(/""/g, '"');
      }
      // Don't sanitize phone field - it legitimately starts with + (country code)
      record[header] = header === 'phone' ? val : sanitizeCell(val);
    });

    if (record.full_name || record.name) {
      records.push(record as CSVRow);
    }
  }
  return records;
}

export async function POST(req: Request) {
  const authFail = await requireAdminWithCsrf(req);
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

      // Validate input lengths
      const nameValidation = validateLength(fullName, 'full_name', INPUT_LIMITS.csv.full_name);
      if (!nameValidation.valid) {
        errorCount++;
        errors.push(`Row ${fullName}: ${nameValidation.error}`);
        continue;
      }

      const emailValidation = validateEmail(email);
      if (!emailValidation.valid) {
        errorCount++;
        errors.push(`Row ${fullName}: ${emailValidation.error}`);
        continue;
      }

      const phoneValidation = validatePhone(phone);
      if (!phoneValidation.valid) {
        errorCount++;
        errors.push(`Row ${fullName}: ${phoneValidation.error}`);
        continue;
      }

      const memberCode = record.member_code || `M-${crypto.randomBytes(4).toString('hex')}`;
      const codeValidation = validateLength(memberCode, 'member_code', INPUT_LIMITS.csv.member_code);
      if (!codeValidation.valid) {
        errorCount++;
        errors.push(`Row ${fullName}: ${codeValidation.error}`);
        continue;
      }

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
    await insertAuditLog({
      action: 'MEMBERS_BULK_IMPORT',
      adminId: adminSession?.id || null,
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