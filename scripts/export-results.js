import { createClient } from '@supabase/supabase-js';
import fs from 'fs';
import path from 'path';

/**
 * AGGREGATE-ONLY EXPORT CONTRACT (NO PII / NO LINKAGE DATA)
 *
 * This script exports only anonymous aggregate election results for pre-wipe archiving.
 * It MUST NOT query or export personal/linkage tables (members, tokens, vote_audit_log,
 * paper_ballots) and MUST NOT export raw per-ballot rows that could reconstruct participation.
 *
 * Retention/export of governed raw linkage data is deliberately deferred to a future
 * Wave 5 governed-retention design.
 */

function getSupabaseServer() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (!url || !key) {
    console.error('❌ Missing NEXT_PUBLIC_SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY in environment');
    console.error('👉 Source your env first (do not rely on this script to load .env files).');
    process.exit(1);
  }

  return createClient(url, key, { auth: { persistSession: false } });
}

function toCsv(rows) {
  const header = 'candidate_id,full_name,votes';
  const body = rows
    .map((row) => {
      const escapedName = `"${String(row.full_name).replace(/"/g, '""')}"`;
      return `${row.candidate_id},${escapedName},${row.votes}`;
    })
    .join('\n');
  return `${header}\n${body}\n`;
}

async function exportResults() {
  const supabase = getSupabaseServer();

  const { data: settings, error: settingsError } = await supabase
    .from('election_settings')
    .select('current_phase')
    .single();

  if (settingsError) {
    console.error('❌ Failed to fetch election phase:', settingsError.message);
    process.exit(1);
  }

  const phase = settings?.current_phase || 'SETUP';
  const isPublished = ['VOTING_CLOSED', 'COMPLETED'].includes(phase);

  if (!isPublished) {
    console.error(`❌ Results are not published yet (phase: ${phase}).`);
    process.exit(1);
  }

  const { data: candidates, error: candidatesError } = await supabase
    .from('candidates')
    .select('id, full_name, is_active')
    .eq('is_active', true);

  if (candidatesError) {
    console.error('❌ Failed to fetch candidates:', candidatesError.message);
    process.exit(1);
  }

  const { data: ballots, error: ballotsError } = await supabase
    .from('ballots')
    .select('candidate_id');

  if (ballotsError) {
    console.error('❌ Failed to fetch ballots:', ballotsError.message);
    process.exit(1);
  }

  const totalVotes = ballots?.length || 0;
  const counts = {};
  ballots?.forEach((b) => {
    counts[b.candidate_id] = (counts[b.candidate_id] || 0) + 1;
  });

  const results = (candidates || [])
    .map((c) => ({
      candidate_id: c.id,
      full_name: c.full_name,
      votes: counts[c.id] || 0,
    }))
    .sort((a, b) => b.votes - a.votes);

  const exportedAt = new Date().toISOString();
  const payload = {
    exportedAt,
    phase,
    totalVotes,
    results,
  };

  const archivesDir = path.join(process.cwd(), 'archives');
  if (!fs.existsSync(archivesDir)) {
    fs.mkdirSync(archivesDir, { recursive: true });
  }

  const fileStamp = exportedAt.replace(/:/g, '-');
  const jsonPath = path.join(archivesDir, `results-${fileStamp}.json`);
  const csvPath = path.join(archivesDir, `results-${fileStamp}.csv`);

  fs.writeFileSync(jsonPath, JSON.stringify(payload, null, 2));
  fs.writeFileSync(csvPath, toCsv(results));

  console.log('📦 Anonymous aggregate results exported');
  console.log(`🗂️  JSON: ${jsonPath}`);
  console.log(`🗂️  CSV:  ${csvPath}`);
  console.log(`🗳️  Phase: ${phase}`);
  console.log(`🧮 Total votes: ${totalVotes}`);
  for (const row of results) {
    console.log(`- ${row.full_name}: ${row.votes}`);
  }
}

exportResults().catch((err) => {
  console.error('Fatal export error:', err);
  process.exit(1);
});
