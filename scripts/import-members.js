import { createClient } from '@supabase/supabase-js';
import fs from 'fs';
import path from 'path';
import crypto from 'crypto';
import dotenv from 'dotenv';

dotenv.config({ path: '.env.local' });

// Sanitize cell values to prevent formula injection (CSV injection)
// Prefix values starting with =, +, -, @, \t, \r with a single quote
// But skip phone field - it legitimately starts with + (country code)
function sanitizeCell(val, header) {
  if (header === 'phone') return val;
  if (/^[=+\-@\t\r]/.test(val)) {
    return "'" + val;
  }
  return val;
}

function getSupabaseServer() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (!url || !key) {
    console.error('❌ Missing NEXT_PUBLIC_SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY in .env.local');
    process.exit(1);
  }

  return createClient(url, key, { auth: { persistSession: false } });
}

// Proper CSV parser handling quotes, empty fields, and basic commas
function parseCSV(text) {
  const lines = text.split(/\r?\n/).filter(line => line.trim().length > 0);
  if (lines.length < 2) return [];

  const headers = lines[0].split(',').map(h => h.trim().toLowerCase().replace(/^"|"$/g, ''));
  const records = [];

  // Proper CSV parsing that handles empty fields
  function parseCSVLine(line) {
    const result = [];
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

    const record = {};
    headers.forEach((header, index) => {
      let val = values[index] ? values[index].trim() : '';
      if (val.startsWith('"') && val.endsWith('"')) {
        val = val.slice(1, -1).replace(/""/g, '"');
      }
      // Don't sanitize phone field - it legitimately starts with + (country code)
      record[header] = header === 'phone' ? val : sanitizeCell(val);
    });

    if (record.full_name || record.email) {
      records.push(record);
    }
  }
  return records;
}

async function importMembers() {
  const filePath = process.argv[2] || path.join(process.cwd(), 'data', 'members.csv');

  if (!fs.existsSync(filePath)) {
    console.error(`❌ CSV file not found at: ${filePath}`);
    console.error(`👉 Usage: node scripts/import-members.js [path/to/file.csv]`);
    process.exit(1);
  }

  console.log(`📂 Reading CSV from: ${filePath}`);
  const csvContent = fs.readFileSync(filePath, 'utf8');
  const records = parseCSV(csvContent);

  if (records.length === 0) {
    console.log(`⚠️ No valid records found in CSV.`);
    return;
  }

  console.log(`🔍 Found ${records.length} member records. Preparing import...`);

  const supabase = getSupabaseServer();
  let successCount = 0;
  let errorCount = 0;

  for (const record of records) {
    const fullName = record.full_name || record.name;
    const email = record.email?.toLowerCase().trim() || null;
    const phone = record.phone?.trim() || null;

    if (!fullName) {
      console.warn(`⚠️ Skipping row with missing name:`, record);
      errorCount++;
      continue;
    }

    // Generate random 8-char member code if not provided
    const memberCode = record.member_code || `M-${crypto.randomBytes(4).toString('hex')}`;

    const { error } = await supabase.from('members').upsert(
      {
        member_code: memberCode,
        full_name: fullName,
        email: email,
        phone: phone,
        is_active: true,
      },
      { onConflict: 'email' }
    );

    if (error) {
      console.error(`❌ Error importing ${fullName} (${email}):`, error.message);
      errorCount++;
    } else {
      successCount++;
    }
  }

  console.log(`\n🎉 Import complete!`);
  console.log(`✅ Successfully imported/updated: ${successCount}`);
  if (errorCount > 0) {
    console.log(`❌ Failed / Skipped: ${errorCount}`);
  }
}

importMembers().catch(err => {
  console.error('Fatal import error:', err);
  process.exit(1);
});
