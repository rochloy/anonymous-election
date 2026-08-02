import { supabaseServer } from '../lib/supabase-server';
import { Resend } from 'resend';
import crypto from 'crypto';
import dotenv from 'dotenv';

dotenv.config({ path: '.env.local' });

const resend = new Resend(process.env.RESEND_API_KEY);

async function dispatchTokens() {
  const { data: members } = await supabaseServer
    .from('members').select('*').eq('is_active', true);
  console.log(`Processing ${members?.length || 0} members...`);

  if (!members) return;

  for (const member of members) {
    const rawToken = crypto.randomBytes(32).toString('hex');
    const tokenHash = crypto.createHash('sha256').update(rawToken).digest('hex');

    await supabaseServer.from('tokens').insert({
      member_id: member.id,
      token_hash: tokenHash,
      type: 'VOTING',
      is_used: false,
    });

    // Token in URL PATH, not query string — avoids access-log/Referer leakage.
    const magicLink = `${process.env.APP_BASE_URL}/vote/${rawToken}`;

    await resend.emails.send({
      from: process.env.FROM_EMAIL,
      to: member.email,
      subject: 'Official Ballot: Committee Head Election',
      html: `<p>Hello ${member.full_name},</p><p><a href="${magicLink}">Click here to vote anonymously</a></p>`,
    });

    console.log(`Sent link to ${member.full_name}`);
  }
}

dispatchTokens().catch(console.error);
