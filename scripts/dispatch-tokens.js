import { createClient } from '@supabase/supabase-js';
import { Resend } from 'resend';
import crypto from 'crypto';
import dotenv from 'dotenv';

dotenv.config({ path: '.env.local' });

function getSupabaseServer() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (!url || !key) {
    console.error('❌ Missing NEXT_PUBLIC_SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY in .env.local');
    process.exit(1);
  }

  return createClient(url, key, { auth: { persistSession: false } });
}

async function dispatchTokens() {
  const supabaseServer = getSupabaseServer();
  const resend = new Resend(process.env.RESEND_API_KEY);

  const { data: members, error } = await supabaseServer
    .from('members')
    .select('*')
    .eq('is_active', true);

  if (error) {
    console.error('❌ Error fetching members:', error.message);
    process.exit(1);
  }

  console.log(`Processing ${members?.length || 0} active members...`);

  if (!members || members.length === 0) {
    console.log('No active members found.');
    return;
  }

  for (const member of members) {
    const rawToken = crypto.randomBytes(32).toString('hex');
    const tokenHash = crypto.createHash('sha256').update(rawToken).digest('hex');

    const { error: tokenErr } = await supabaseServer.from('tokens').insert({
      member_id: member.id,
      token_hash: tokenHash,
      type: 'VOTING',
      is_used: false,
    });

    if (tokenErr) {
      console.error(`❌ Failed to generate token for ${member.full_name}:`, tokenErr.message);
      continue;
    }

    // Token in URL PATH, not query string — avoids access-log/Referer leakage.
    const magicLink = `${process.env.APP_BASE_URL || 'http://localhost:3000'}/vote/${rawToken}`;

    if (process.env.RESEND_API_KEY) {
      await resend.emails.send({
        from: process.env.FROM_EMAIL || 'Elections <elections@example.com>',
        to: member.email,
        subject: 'Official Ballot: Committee Head Election',
        html: `<p>Hello ${member.full_name},</p><p><a href="${magicLink}">Click here to vote anonymously</a></p>`,
      });
      console.log(`✉️ Sent link to ${member.full_name} (${member.email})`);
    } else {
      console.log(`🔑 [Dry Run - No RESEND_API_KEY] Generated link for ${member.full_name}: ${magicLink}`);
    }
  }
}

dispatchTokens().catch(console.error);
