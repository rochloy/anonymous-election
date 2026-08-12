// Test script: paper ballot workflow end-to-end via the API.
// Usage: node scripts/test-paper-vote.js
//
// 1. Issue a paper ballot for a member who hasn't voted
// 2. Record the paper vote (scan QR → select candidate)
// 3. Verify the vote via /api/verify
// 4. Check audit log
// 5. Attempt to issue a second ballot for the same member (should fail)

import { createClient } from '@supabase/supabase-js';
import dotenv from 'dotenv';

dotenv.config({ path: '.env.local' });

const BASE = 'http://localhost:3000';
const ADMIN_SECRET = process.env.ADMIN_SECRET;

function getSupabaseServer() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) {
    console.error('Missing Supabase env vars');
    process.exit(1);
  }
  return createClient(url, key, { auth: { persistSession: false } });
}

async function main() {
  const supabase = getSupabaseServer();

  // 1. Find a member who hasn't voted and doesn't have a paper ballot issued
  const { data: members } = await supabase
    .from('members')
    .select('id, full_name, member_code')
    .eq('is_active', true)
    .limit(20);

  let testMember = null;
  for (const m of members) {
    // Check if they have an unused token
    const { data: token } = await supabase
      .from('tokens')
      .select('id, is_used')
      .eq('member_id', m.id)
      .eq('type', 'VOTING')
      .eq('is_used', false)
      .maybeSingle();
    // Check if they already have a paper ballot
    const { data: paper } = await supabase
      .from('paper_ballots')
      .select('ballot_id, status')
      .eq('member_id', m.id)
      .maybeSingle();
    if (token && !paper) {
      testMember = m;
      break;
    }
  }

  if (!testMember) {
    console.error('No suitable test member found (need unused token + no paper ballot)');
    process.exit(1);
  }

  console.log(`Test member: ${testMember.full_name} (${testMember.member_code})`);

  // 2. Issue a paper ballot
  console.log('\n1. Issuing paper ballot via /api/admin/paper-ballot...');
  const issueRes = await fetch(`${BASE}/api/admin/paper-ballot`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-admin-secret': ADMIN_SECRET },
    body: JSON.stringify({ memberId: testMember.id }),
  });
  const issueData = await issueRes.json();
  console.log('   Status:', issueRes.status);
  console.log('   Success:', issueData.success);
  console.log('   Ballot ID:', issueData.ballotId);
  console.log('   Short code:', issueData.shortCode);
  console.log('   QR data URL present:', !!issueData.qrDataUrl);
  console.log('   QR SVG present:', !!issueData.qrSvg);

  if (!issueData.success) {
    console.error('Issue failed:', issueData.error);
    process.exit(1);
  }

  // 3. Record the paper vote
  console.log('\n2. Recording paper vote via /api/admin/paper-vote...');
  const candidateId = '22222222-2222-2222-2222-222222222222'; // Marcus Thorne
  const recordRes = await fetch(`${BASE}/api/admin/paper-vote`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-admin-secret': ADMIN_SECRET },
    body: JSON.stringify({ ballotId: issueData.ballotId, candidateId }),
  });
  const recordData = await recordRes.json();
  console.log('   Status:', recordRes.status);
  console.log('   Success:', recordData.success);
  console.log('   Message:', recordData.message);
  console.log('   Receipt code:', recordData.receiptCode);

  if (!recordData.success) {
    console.error('Record vote failed:', recordData.error);
    process.exit(1);
  }

  // 4. Verify the vote via /api/verify
  console.log('\n3. Verifying vote via /api/verify...');
  const verifyRes = await fetch(`${BASE}/api/verify?ballot_id=${encodeURIComponent(issueData.ballotId)}`);
  const verifyData = await verifyRes.json();
  console.log('   Found:', verifyData.found);
  console.log('   Channel:', verifyData.channel);
  console.log('   Candidate:', verifyData.candidate_name);
  console.log('   Cast date:', verifyData.cast_date);

  // 5. Check the DB state — paper_ballots should be VOTED, token should be used
  console.log('\n4. Checking DB state...');
  const { data: paper } = await supabase
    .from('paper_ballots')
    .select('ballot_id, status, voted_at, candidate_id')
    .eq('ballot_id', issueData.ballotId)
    .single();
  console.log('   Paper ballot status:', paper?.status);
  console.log('   Voted at:', paper?.voted_at);

  const { data: token } = await supabase
    .from('tokens')
    .select('is_used, used_at, channel_sent')
    .eq('member_id', testMember.id)
    .eq('type', 'VOTING')
    .single();
  console.log('   Token used:', token?.is_used);
  console.log('   Token channel_sent:', token?.channel_sent);

  // 6. Check audit log
  const { data: audit } = await supabase
    .from('vote_audit_log')
    .select('action, ballot_id, created_at')
    .eq('ballot_id', issueData.ballotId)
    .order('created_at', { ascending: false })
    .limit(5);
  console.log('   Audit log entries:', audit?.length || 0);
  if (audit) {
    audit.forEach((a, i) => console.log(`     [${i}] ${a.action} at ${a.created_at}`));
  }

  // 7. Attempt to issue a second ballot for the same member (should fail)
  console.log('\n5. Attempting to issue second ballot (should fail)...');
  const issue2Res = await fetch(`${BASE}/api/admin/paper-ballot`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-admin-secret': ADMIN_SECRET },
    body: JSON.stringify({ memberId: testMember.id }),
  });
  const issue2Data = await issue2Res.json();
  console.log('   Status:', issue2Res.status);
  console.log('   Success:', issue2Data.success);
  console.log('   Error:', issue2Data.error || issue2Data.message);

  // 8. Attempt to record the same ballot again (should fail — already voted)
  console.log('\n6. Attempting to record same ballot again (should fail)...');
  const record2Res = await fetch(`${BASE}/api/admin/paper-vote`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-admin-secret': ADMIN_SECRET },
    body: JSON.stringify({ ballotId: issueData.ballotId, candidateId }),
  });
  const record2Data = await record2Res.json();
  console.log('   Status:', record2Res.status);
  console.log('   Success:', record2Data.success);
  console.log('   Error:', record2Data.error || record2Data.message);

  console.log('\n✅ Paper vote test complete!');
  console.log(`   Member: ${testMember.full_name}`);
  console.log(`   Ballot ID: ${issueData.ballotId}`);
  console.log(`   Short code: ${issueData.shortCode}`);
  console.log(`   Candidate: Marcus Thorne`);
  console.log(`   Receipt: ${recordData.receiptCode}`);
}

main().catch(err => {
  console.error('Test failed:', err);
  process.exit(1);
});
