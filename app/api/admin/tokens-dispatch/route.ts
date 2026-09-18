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
      .select('id, member_code, full_name, email, voting_eligible, eligibility_reason, eligibility_source')
      .in('id', memberIds)
      .eq('is_active', true);

    if (membersError) {
      return NextResponse.json({ error: membersError.message }, { status: 500 });
    }

    if (!members || members.length === 0) {
      return NextResponse.json({ error: 'No valid members found' }, { status: 400 });
    }

    const { data: settings, error: settingsError } = await supabaseServer
      .from('election_settings')
      .select('voting_token_ttl_hours')
      .eq('id', 1)
      .maybeSingle();

    if (settingsError) {
      return NextResponse.json({ error: settingsError.message }, { status: 500 });
    }

    const configuredTtlHours = settings?.voting_token_ttl_hours ?? 168;

    let sentCount = 0;
    let failedCount = 0;
    let eligibilityFailedCount = 0;
    const errors: string[] = [];
    const failures: Array<Record<string, unknown>> = [];

    for (const member of members) {
      // Wave 5: gate VOTING dispatch on voting_eligible (NOMINATION is not gated).
      if (tokenType === 'VOTING' && member.voting_eligible !== true) {
        failedCount++;
        eligibilityFailedCount++;
        errors.push(`${member.full_name} (${member.member_code}): Ineligible — ${member.eligibility_reason}`);
        failures.push({
          memberId: member.id, memberCode: member.member_code,
          code: 'VOTER_INELIGIBLE',
          eligibilityReason: member.eligibility_reason,
          eligibilitySource: member.eligibility_source,
        });
        continue;
      }

      if (!member.email) {
        failedCount++;
        errors.push(`${member.full_name} (${member.member_code}): No email address`);
        continue;
      }

      // Check if member already has an unused token of this type
      // (NOMINATION flow unchanged; VOTING is guarded by ensure_voting_entitlement).
      if (tokenType !== 'VOTING') {
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
      }

      // Generate token
      const rawToken = crypto.randomBytes(32).toString('hex');
      const tokenHash = crypto.createHash('sha256').update(rawToken).digest('hex');
      let createdVotingTokenId: string | null = null;

      if (tokenType === 'VOTING') {
        const { data: entitlementData, error: entitlementError } = await supabaseServer.rpc(
          'ensure_voting_entitlement',
          {
            p_member_id: member.id,
            p_admin_id: adminSession?.id ?? null,
            p_token_hash: tokenHash,
            p_channel_sent: 'EMAIL',
          }
        );

        const entitlement = entitlementData?.[0];
        if (entitlementError || !entitlement) {
          failedCount++;
          errors.push(
            `${member.full_name} (${member.member_code}): ${
              entitlementError?.message || 'Failed to ensure voting entitlement'
            }`
          );
          continue;
        }

        if (entitlement.success !== true) {
          failedCount++;
          if (entitlement.code === 'VOTER_INELIGIBLE') {
            eligibilityFailedCount++;
            errors.push(
              `${member.full_name} (${member.member_code}): Ineligible — ${member.eligibility_reason}`
            );
            failures.push({
              memberId: member.id,
              memberCode: member.member_code,
              code: 'VOTER_INELIGIBLE',
              eligibilityReason: member.eligibility_reason,
              eligibilitySource: member.eligibility_source,
            });
          } else if (entitlement.code === 'ENTITLEMENT_CONSUMED') {
            errors.push(
              `${member.full_name} (${member.member_code}): Voting entitlement already consumed`
            );
          } else if (entitlement.code === 'INTEGRITY_ERROR') {
            errors.push(
              `${member.full_name} (${member.member_code}): Integrity error: multiple active voting tokens found for member`
            );
          } else {
            errors.push(
              `${member.full_name} (${member.member_code}): ${
                entitlement.message || 'Failed to ensure voting entitlement'
              }`
            );
          }
          continue;
        }

        if (entitlement.created !== true) {
          failedCount++;
          errors.push(
            `${member.full_name} (${member.member_code}): Already has an unused ${tokenType} token`
          );
          continue;
        }

        createdVotingTokenId = entitlement.token_id || null;
      } else {
        const expiresAt = new Date(Date.now() + 24 * 60 * 60 * 1000);
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
      }

      // Send email
      const linkPath = tokenType === 'NOMINATION' ? 'nominate' : 'vote';
      const magicLink = `${process.env.APP_BASE_URL || 'http://localhost:3000'}/${linkPath}/${rawToken}`;
      const expiryText =
        tokenType === 'VOTING'
          ? configuredTtlHours % 24 === 0
            ? `${configuredTtlHours / 24} days`
            : `${configuredTtlHours} hours`
          : '24 hours';

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
          if (tokenType === 'VOTING' && createdVotingTokenId) {
            await supabaseServer
              .from('tokens')
              .update({
                voided_at: new Date().toISOString(),
                void_reason: 'Dispatch email failed',
              })
              .eq('id', createdVotingTokenId)
              .is('voided_at', null);
          }
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
        eligibility_failed: eligibilityFailedCount,
        voting_token_ttl_hours: tokenType === 'VOTING' ? configuredTtlHours : null,
        admin_ip: adminSession?.ip_address
      },
    });

    return NextResponse.json({
      success: true,
      total: memberIds.length,
      sent: sentCount,
      failed: failedCount,
      eligibilityFailed: eligibilityFailedCount,
      errors: errors.slice(0, 20),
      failures: failures.slice(0, 20),
    });
  } catch (err: unknown) {
    const errorMsg = err instanceof Error ? err.message : 'Server error';
    return NextResponse.json({ error: errorMsg }, { status: 500 });
  }
}
