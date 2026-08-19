import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { requireAdmin, requireAdminWithCsrf, getAdminSession } from '../auth';
import { Resend } from 'resend';
import crypto from 'crypto';
import { validateLength, INPUT_LIMITS } from '@/lib/input-validation';
import { insertAuditLog } from '@/lib/audit-log';

const resend = new Resend(process.env.RESEND_API_KEY);

export async function POST(req: Request) {
  const authFail = await requireAdminWithCsrf(req);
  if (authFail) return authFail;

  const adminSession = await getAdminSession();

  try {
    const { memberIds, type } = await req.json();

    if (!memberIds || !Array.isArray(memberIds) || memberIds.length === 0) {
      return NextResponse.json({ error: 'Member IDs array is required' }, { status: 400 });
    }

    const tokenType = type || 'VOTING';

    // Validate token type length
    const typeValidation = validateLength(tokenType, 'type', INPUT_LIMITS.token.type);
    if (!typeValidation.valid) {
      return NextResponse.json({ error: typeValidation.error }, { status: 400 });
    }

    // Fetch members
    const { data: members, error: membersError } = await supabaseServer
      .from('members')
      .select('id, member_code, full_name, email')
      .in('id', memberIds)
      .eq('is_active', true);

    if (membersError) {
      return NextResponse.json({ error: membersError.message }, { status: 500 });
    }

    if (!members || members.length === 0) {
      return NextResponse.json({ error: 'No valid members found' }, { status: 400 });
    }

    let sentCount = 0;
    let failedCount = 0;
    const errors: string[] = [];

    for (const member of members) {
      if (!member.email) {
        failedCount++;
        errors.push(`${member.full_name} (${member.member_code}): No email address`);
        continue;
      }

      // Check if member already has an unused token of this type
      const { data: existingToken } = await supabaseServer
        .from('tokens')
        .select('id')
        .eq('member_id', member.id)
        .eq('type', tokenType)
        .eq('is_used', false)
        .maybeSingle();

      if (existingToken) {
        failedCount++;
        errors.push(`${member.full_name} (${member.member_code}): Already has an unused ${tokenType} token`);
        continue;
      }

      // Generate token
      const rawToken = crypto.randomBytes(32).toString('hex');
      const tokenHash = crypto.createHash('sha256').update(rawToken).digest('hex');

      // Set token expiry: 7 days for voting, 24 hours for nomination
      const expiresAt = new Date(Date.now() + (tokenType === 'VOTING' ? 7 * 24 * 60 * 60 * 1000 : 24 * 60 * 60 * 1000));

      const { error: tokenError } = await supabaseServer.from('tokens').insert({
        member_id: member.id,
        token_hash: tokenHash,
        type: tokenType,
        is_used: false,
        expires_at: expiresAt.toISOString(),
      });

      if (tokenError) {
        failedCount++;
        errors.push(`${member.full_name} (${member.member_code}): ${tokenError.message}`);
        continue;
      }

      // Send email
      const magicLink = `${process.env.APP_BASE_URL || 'http://localhost:3000'}/vote/${rawToken}`;
      const expiryText = tokenType === 'VOTING' ? '7 days' : '24 hours';

      if (process.env.RESEND_API_KEY && resend) {
        try {
          await resend.emails.send({
            from: process.env.FROM_EMAIL || 'Elections <elections@example.com>',
            to: member.email,
            subject: tokenType === 'VOTING' ? 'Official Ballot: Committee Head Election' : 'Nomination Token',
            html: `
              <p>Hello ${member.full_name},</p>
              <p>${tokenType === 'VOTING' 
                ? 'Click the link below to vote anonymously:' 
                : 'Click the link below to submit your nomination:'}</p>
              <p><a href="${magicLink}">${magicLink}</a></p>
              <p>This link is unique to you and can only be used once.</p>
              <p><strong>This link expires in ${expiryText}.</strong></p>
            `,
            text: `Hello ${member.full_name},

${tokenType === 'VOTING' 
  ? 'Click the link below to vote anonymously:' 
  : 'Click the link below to submit your nomination:'}

${magicLink}

This link is unique to you and can only be used once.
This link expires in ${expiryText}.`,
          });
          sentCount++;
        } catch (emailError) {
          failedCount++;
          errors.push(`${member.full_name} (${member.member_code}): Email send failed - ${emailError instanceof Error ? emailError.message : 'Unknown error'}`);
        }
      } else {
        // Dry run mode
        console.log(`[Dry Run] Token for ${member.full_name} (${member.email}): ${magicLink}`);
        sentCount++;
      }
    }

    // Audit log
    await insertAuditLog({
      action: 'TOKENS_DISPATCHED',
      adminId: adminSession?.id || null,
      details: { 
        type: tokenType, 
        requested: memberIds.length, 
        sent: sentCount, 
        failed: failedCount,
        admin_ip: adminSession?.ip_address
      },
    });

    return NextResponse.json({
      success: true,
      total: memberIds.length,
      sent: sentCount,
      failed: failedCount,
      errors: errors.slice(0, 20),
    });
  } catch (err: unknown) {
    const errorMsg = err instanceof Error ? err.message : 'Server error';
    return NextResponse.json({ error: errorMsg }, { status: 500 });
  }
}