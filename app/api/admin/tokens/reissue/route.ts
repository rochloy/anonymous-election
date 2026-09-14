import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { requireAdminWithCsrf, getAdminSession } from '../../auth';
import { insertAuditLog } from '@/lib/audit-log';
import { Resend } from 'resend';
import crypto from 'crypto';
import { UUID_REGEX } from '@/lib/input-validation';

const resend = new Resend(process.env.RESEND_API_KEY);

export async function POST(req: Request) {
  const authFail = await requireAdminWithCsrf(req);
  if (authFail) return authFail;

  const adminSession = await getAdminSession();
  const adminId = adminSession?.id && UUID_REGEX.test(adminSession.id) ? adminSession.id : null;

  try {
    const { tokenId, reason } = await req.json();

    if (!tokenId || typeof tokenId !== 'string') {
      return NextResponse.json({ error: 'tokenId is required' }, { status: 400 });
    }

    if (!reason || typeof reason !== 'string' || !reason.trim()) {
      return NextResponse.json({ error: 'reason is required' }, { status: 400 });
    }

    const { data: token, error: tokenError } = await supabaseServer
      .from('tokens')
      .select('id, member_id, type, is_used, voided_at')
      .eq('id', tokenId)
      .maybeSingle();

    if (tokenError) {
      return NextResponse.json({ error: tokenError.message }, { status: 500 });
    }

    if (!token) {
      return NextResponse.json({ error: 'Token not found' }, { status: 404 });
    }

    if (token.is_used) {
      return NextResponse.json({ error: 'Token has already been used and cannot be reissued.' }, { status: 409 });
    }

    if (token.voided_at) {
      return NextResponse.json({ error: 'Token has already been voided and cannot be reissued.' }, { status: 409 });
    }

    const { data: settings, error: settingsError } = await supabaseServer
      .from('election_settings')
      .select('current_phase')
      .eq('id', 1)
      .maybeSingle();

    if (settingsError) {
      return NextResponse.json({ error: settingsError.message }, { status: 500 });
    }

    const requiredPhase = token.type === 'NOMINATION' ? 'NOMINATION' : 'VOTING';
    if (settings?.current_phase !== requiredPhase) {
      const typeLabel = token.type === 'NOMINATION' ? 'Nomination' : 'Voting';
      return NextResponse.json(
        { error: `${typeLabel} tokens can only be reissued during the ${requiredPhase} phase.` },
        { status: 409 }
      );
    }

    const rawToken = crypto.randomBytes(32).toString('hex');
    const tokenHash = crypto.createHash('sha256').update(rawToken).digest('hex');
    const trimmedReason = reason.trim();

    const { data: rpcData, error: rpcError } = await supabaseServer.rpc('reissue_token', {
      p_old_token_id: tokenId,
      p_admin_id: adminId,
      p_reason: trimmedReason,
      p_new_token_hash: tokenHash,
    });

    if (rpcError) {
      return NextResponse.json({ error: rpcError.message }, { status: 500 });
    }

    const rpcRow = rpcData?.[0];
    if (!rpcRow?.success) {
      return NextResponse.json({ error: rpcRow?.message || 'Token reissue failed' }, { status: 409 });
    }

    let warning: string | undefined;
    const { data: member, error: memberError } = await supabaseServer
      .from('members')
      .select('email, full_name')
      .eq('id', token.member_id)
      .maybeSingle();

    if (memberError) {
      warning = 'Token was reissued, but member lookup failed for email notification.';
    } else if (!member?.email) {
      warning = 'Token was reissued, but no member email is available for notification.';
    } else {
      const linkPath = token.type === 'NOMINATION' ? 'nominate' : 'vote';
      const magicLink = `${process.env.APP_BASE_URL || 'http://localhost:3000'}/${linkPath}/${rawToken}`;

      if (process.env.RESEND_API_KEY && resend) {
        try {
          await resend.emails.send({
            from: process.env.FROM_EMAIL || 'Elections <elections@example.com>',
            to: member.email,
            subject: token.type === 'VOTING' ? 'Updated voting link' : 'Updated nomination link',
            html: `
              <p>Hello ${member.full_name},</p>
              <p>Your previous ${token.type.toLowerCase()} link has been voided.</p>
              <p>Use this new link:</p>
              <p><a href="${magicLink}">${magicLink}</a></p>
            `,
            text: `Hello ${member.full_name},

Your previous ${token.type.toLowerCase()} link has been voided.
Use this new link:

${magicLink}`,
          });
        } catch (emailError) {
          warning = `Token was reissued, but email delivery failed: ${emailError instanceof Error ? emailError.message : 'Unknown error'}`;
        }
      } else {
        warning = 'Token was reissued, but email delivery is not configured.';
      }
    }

    await insertAuditLog({
      action: 'ADMIN_ACTION',
      adminId,
      memberId: token.member_id,
      details: {
        old_token_id: tokenId,
        type: token.type,
        reason: trimmedReason,
      },
    });

    return NextResponse.json(
      warning
        ? { success: true, message: 'Token reissued.', warning }
        : { success: true, message: 'Token reissued.' }
    );
  } catch (err: unknown) {
    const errorMsg = err instanceof Error ? err.message : 'Server error';
    return NextResponse.json({ error: errorMsg }, { status: 500 });
  }
}
