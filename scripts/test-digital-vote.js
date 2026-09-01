// Test script: cast a digital vote end-to-end via the API.
// Usage: node scripts/test-digital-vote.js
//
// Generates a fresh voting token for a specific member, then:
// 1. Verifies the token via /api/auth/verify-token
// 2. Casts a vote via /api/vote
// 3. Verifies the vote via /api/verify
// 4. Prints the receipt code

import { createClient } from '@supabase/supabase-js';
import crypto from 'crypto';
import dotenv from 'dotenv';

dotenv.config({ path: '.env.local' });

// Always use localhost for testing — APP_BASE_URL in .env.local may point to production
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

  // 1. Pick a member who hasn't voted yet
  const { data: members, error: mErr } = await supabase
    .from('members')
    .select('id, full_name, member_code')
    .eq('is_active', true)
    .limit(5);

  if (mErr || !members?.length) {
    console.error('Could not fetch members:', mErr?.message);
    process.exit(1);
  }

  // Find a member with an unused token
  let testMember = null;
  for (const m of members) {
    const { data: token } = await supabase
      .from('tokens')
      .select('id, is_used')
      .eq('member_id', m.id)
      .eq('type', 'VOTING')
      .eq('is_used', false)
      .maybeSingle();
    if (token) {
      testMember = m;
      break;
    }
  }

  if (!testMember) {
    // Generate a token for the first member
    testMember = members[0];
    console.log(`No unused token found. Generating one for ${testMember.full_name}...`);
  } else {
    console.log(`Test member: ${testMember.full_name} (${testMember.member_code})`);
  }

  // 2. Generate a raw token + hash
  const rawToken = crypto.randomBytes(32).toString('hex');
  const tokenHash = crypto.createHash('sha256').update(rawToken).digest('hex');

  // Delete any existing unused token for this member, then insert the new one
  await supabase.from('tokens').delete().eq('member_id', testMember.id).eq('is_used', false).eq('type', 'VOTING');
  const expiresAt = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString();
  const { error: insertErr } = await supabase.from('tokens').insert({
    member_id: testMember.id,
    token_hash: tokenHash,
    type: 'VOTING',
    is_used: false,
    expires_at: expiresAt,
  });

  if (insertErr) {
    console.error('Failed to insert token:', insertErr.message);
    process.exit(1);
  }

  console.log(`\n1. Token generated (hash: ${tokenHash.slice(0, 16)}...)`);

  // 3. Verify token via API
  console.log('\n2. Verifying token via /api/auth/verify-token...');
  const verifyRes = await fetch(`${BASE}/api/auth/verify-token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ rawToken }),
  });
  const verifyData = await verifyRes.json();
  console.log('   Status:', verifyRes.status);
  console.log('   Valid:', verifyData.valid);
  console.log('   Phase:', verifyData.currentPhase);
  console.log('   Candidates:', verifyData.candidates?.length || 0);

  if (!verifyData.valid) {
    console.error('Token verification failed:', verifyData.message);
    process.exit(1);
  }

  // 4. Pick the first candidate
  const candidate = verifyData.candidates[0];
  console.log(`   Selected candidate: ${candidate.full_name} (${candidate.id})`);

  // 5. Cast the vote
  console.log('\n3. Casting vote via /api/vote...');
  const voteRes = await fetch(`${BASE}/api/vote`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ rawToken, candidateId: candidate.id }),
  });
  const voteData = await voteRes.json();
  console.log('   Status:', voteRes.status);
  console.log('   Success:', voteData.success);
  console.log('   Receipt code:', voteData.receiptCode);

  if (!voteData.success) {
    console.error('Vote failed:', voteData.error);
    process.exit(1);
  }

  // 6. Try to vote again (should fail — single-use token)
  console.log('\n4. Attempting to vote again (should fail)...');
  const vote2Res = await fetch(`${BASE}/api/vote`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ rawToken, candidateId: candidate.id }),
  });
  const vote2Data = await vote2Res.json();
  console.log('   Status:', vote2Res.status);
  console.log('   Success:', vote2Data.success);
  console.log('   Error:', vote2Data.error);

  // 7. Verify the vote via /api/verify
  // We need the ballot_id — query the DB for it using the receipt code
  console.log('\n5. Verifying vote via /api/verify...');
  const { data: ballot } = await supabase
    .from('ballots')
    .select('ballot_id, receipt_code, channel, cast_date')
    .eq('receipt_code', voteData.receiptCode)
    .single();

  if (!ballot) {
    console.error('Could not find ballot with receipt:', voteData.receiptCode);
    process.exit(1);
  }

  console.log('   Ballot ID:', ballot.ballot_id);
  console.log('   Channel:', ballot.channel);
  console.log('   Cast date:', ballot.cast_date);

  const verifyVoteRes = await fetch(`${BASE}/api/verify?ballot_id=${encodeURIComponent(ballot.ballot_id)}&receipt_code=${voteData.receiptCode}`);
  const verifyVoteData = await verifyVoteRes.json();
  console.log('   Found:', verifyVoteData.found);
  console.log('   Candidate:', verifyVoteData.candidate_name);
  console.log('   Receipt match:', verifyVoteData.receipt_match);

  // 8. Check admin stats
  console.log('\n6. Admin stats (turnout should be hidden during VOTING)...');
  const statsRes = await fetch(`${BASE}/api/admin/stats`, {
    headers: { 'x-admin-secret': ADMIN_SECRET },
  });
  const statsData = await statsRes.json();
  console.log('   Total members:', statsData.totalMembers);
  console.log('   Live turnout hidden:', statsData.liveTurnoutHidden);
  console.log('   Votes cast:', statsData.votesCast || '(hidden)');

  console.log('\n✅ Digital vote test complete!');
  console.log(`   Member: ${testMember.full_name}`);
  console.log(`   Candidate: ${candidate.full_name}`);
  console.log(`   Receipt: ${voteData.receiptCode}`);
  console.log(`   Ballot ID: ${ballot.ballot_id}`);
}

main().catch(err => {
  console.error('Test failed:', err);
  process.exit(1);
});
