import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { requireAdminWithCsrf, getAdminSession } from '../auth';
import { Resend } from 'resend';
import crypto from 'crypto';
import { logError } from '@/lib/safe-log';

const resend = new Resend(process.env.RESEND_API_KEY);

export const dynamic = 'force-dynamic';
export const revalidate = 0;

type WipeAction = 'request' | 'confirm_link' | 'status' | 'cancel' | 'execute';

function serverError() {
  return NextResponse.json({ error: 'Server error' }, { status: 500 });
}

function mapWipeFailure(input: unknown): string {
  const msg =
    typeof input === 'string'
      ? input
      : typeof input === 'object' && input !== null && 'message' in input && typeof (input as { message?: unknown }).message === 'string'
        ? (input as { message: string }).message
        : '';

  if (msg.includes('SETUP')) return 'Database wipe is only allowed during SETUP phase.';
  if (msg.includes('wipe not confirmed')) return 'Email confirmation required. Please click the confirmation link first.';
  if (msg.includes('wipe confirmation expired')) return 'Confirmation expired. Please request a new wipe confirmation email.';
  return 'Wipe failed';
}

// In-app "Danger zone" database wipe (new-election setup). SETUP-only
// (enforced server-side by the RPC), atomic (one RPC = one transaction),
// data-only (the seed.sql truncate list; schema untouched),
// governance-logged (WIPE_STARTED/WIPE_COMPLETED to the wipe-surviving
// ledger, inside the transaction). NOTE: admin_sessions is wiped — the
// calling admin is logged out immediately after a successful wipe.

export async function POST(req: Request) {
  let body: {
    action?: WipeAction;
    token?: string;
    confirm1?: string;
    confirm2?: string;
  };

  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ error: 'Invalid request body' }, { status: 400 });
  }

  const action = body.action;

  if (action === 'confirm_link') {
    try {
      if (!body.token || typeof body.token !== 'string') {
        return NextResponse.json({ error: 'Invalid or expired link' }, { status: 400 });
      }

      const tokenHash = crypto.createHash('sha256').update(body.token).digest('hex');
      const { data: row, error: rowError } = await supabaseServer
        .from('wipe_confirmation_tokens')
        .select('token_hash, confirmed_at, expires_at')
        .eq('token_hash', tokenHash)
        .maybeSingle();

      if (rowError || !row || row.confirmed_at || new Date(row.expires_at) <= new Date()) {
        return NextResponse.json({ error: 'Invalid or expired link' }, { status: 400 });
      }

      const nowIso = new Date().toISOString();
      const { data: updatedRows, error: updateError } = await supabaseServer
        .from('wipe_confirmation_tokens')
        .update({ confirmed_at: new Date().toISOString() })
        .eq('token_hash', tokenHash)
        .is('confirmed_at', null)
        .gt('expires_at', nowIso)
        .select('token_hash');

      if (updateError || !updatedRows || updatedRows.length === 0) {
        return NextResponse.json({ error: 'Invalid or expired link' }, { status: 400 });
      }

      return NextResponse.json({ confirmed: true });
    } catch (err) {
      logError('admin/wipe-database confirm_link error', err);
      return serverError();
    }
  }

  const authFail = await requireAdminWithCsrf(req);
  if (authFail) return authFail;

  try {
    const adminSession = await getAdminSession();
    if (!adminSession?.id) {
      return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
    }

    if (action === 'status') {
      const { data: row } = await supabaseServer
        .from('wipe_confirmation_tokens')
        .select('confirmed_at, expires_at')
        .eq('admin_session_id', adminSession.id)
        .maybeSingle();

      const now = new Date();
      const expiresAt = row?.expires_at ?? null;
      const notExpired = expiresAt ? new Date(expiresAt) > now : false;

      return NextResponse.json(
        {
          pending: !!row && !row.confirmed_at && notExpired,
          confirmed: !!row && !!row.confirmed_at && notExpired,
          expiresAt,
        },
        {
          headers: {
            'Cache-Control': 'no-store, no-cache, must-revalidate, proxy-revalidate',
            Pragma: 'no-cache',
            Expires: '0',
          },
        }
      );
    }

    if (action === 'cancel') {
      await supabaseServer
        .from('wipe_confirmation_tokens')
        .delete()
        .eq('admin_session_id', adminSession.id);

      return NextResponse.json({ success: true });
    }

    if (action === 'request') {
      const { data: settings } = await supabaseServer
        .from('election_settings')
        .select('current_phase')
        .eq('id', 1)
        .single();
      if (settings?.current_phase !== 'SETUP') {
        return NextResponse.json(
          { error: 'Database wipe is only allowed during SETUP phase.' },
          { status: 400 }
        );
      }

      const adminEmail = process.env.ADMIN_EMAIL;
      if (!adminEmail) {
        return NextResponse.json({ error: 'ADMIN_EMAIL not configured' }, { status: 500 });
      }

      const rawToken = crypto.randomBytes(32).toString('hex');
      const tokenHash = crypto.createHash('sha256').update(rawToken).digest('hex');
      const expiresAt = new Date(Date.now() + 60 * 60 * 1000).toISOString();

      const { error: upsertError } = await supabaseServer
        .from('wipe_confirmation_tokens')
        .upsert(
          {
            admin_session_id: adminSession.id,
            token_hash: tokenHash,
            expires_at: expiresAt,
            confirmed_at: null,
          },
          { onConflict: 'admin_session_id' }
        );

      if (upsertError) {
        logError('admin/wipe-database request upsert failed', upsertError);
        return serverError();
      }

      const confirmUrl = `${process.env.APP_BASE_URL || 'http://localhost:3000'}/admin/phase/confirm?mode=wipe&token=${rawToken}`;

      try {
        const { error: emailError } = await resend.emails.send({
          from: process.env.FROM_EMAIL || 'Elections <elections@example.com>',
          to: adminEmail,
          subject: 'Confirm Election Data Wipe',
          html: `
            <p>A database wipe has been requested from the admin dashboard.</p>
            <p>This action permanently deletes election data and is only valid for 1 hour.</p>
            <p>Click to confirm email possession (this does not execute the wipe):</p>
            <p><a href="${confirmUrl}">${confirmUrl}</a></p>
            <p>If you did not request this, ignore this email.</p>
          `,
          text: `A database wipe has been requested from the admin dashboard.

This action permanently deletes election data and is only valid for 1 hour.

Click to confirm email possession (this does not execute the wipe):
${confirmUrl}

If you did not request this, ignore this email.`,
        });

        if (emailError) {
          throw emailError;
        }
      } catch (emailErr) {
        logError('admin/wipe-database request email failed', emailErr);
        const { error: cleanupError } = await supabaseServer
          .from('wipe_confirmation_tokens')
          .delete()
          .eq('admin_session_id', adminSession.id)
          .eq('token_hash', tokenHash);
        if (cleanupError) {
          logError('admin/wipe-database request cleanup delete failed', cleanupError);
        }
        return NextResponse.json(
          { error: 'Confirmation email could not be sent' },
          { status: 502 }
        );
      }

      return NextResponse.json({ sent: true, expiresAt });
    }

    if (action === 'execute') {
      if (body.confirm1 !== 'WIPE' || body.confirm2 !== 'DELETE ALL DATA') {
        return NextResponse.json(
          { error: 'Type WIPE and DELETE ALL DATA exactly to proceed.' },
          { status: 400 }
        );
      }

      const { data: tokenRow } = await supabaseServer
        .from('wipe_confirmation_tokens')
        .select('token_hash, confirmed_at, expires_at')
        .eq('admin_session_id', adminSession.id)
        .maybeSingle();

      if (!tokenRow) {
        return NextResponse.json({ error: 'Email confirmation required. Please request a confirmation email first.' }, { status: 400 });
      }
      if (!tokenRow.confirmed_at) {
        return NextResponse.json({ error: 'Email confirmation required. Please click the confirmation link first.' }, { status: 400 });
      }
      if (new Date(tokenRow.expires_at) <= new Date()) {
        return NextResponse.json({ error: 'Confirmation expired. Please request a new confirmation email.' }, { status: 400 });
      }

      let data: Array<{ success: boolean; message: string }> | null = null;
      let error: unknown = null;
      try {
        const result = await supabaseServer.rpc('wipe_election_data', {
          p_admin_id: adminSession.id,
          p_token_hash: tokenRow.token_hash,
        });
        data = result.data;
        error = result.error;
      } catch (rpcErr) {
        error = rpcErr;
      }

      if (error) {
        logError('admin/wipe-database execute RPC failed', error);
        return NextResponse.json({ error: mapWipeFailure(error) }, { status: 400 });
      }
      if (!data || !data[0]?.success) {
        return NextResponse.json({ error: mapWipeFailure(data?.[0]?.message) }, { status: 400 });
      }

      return NextResponse.json({ success: true, message: data[0].message });
    }

    return NextResponse.json({ error: 'Invalid action' }, { status: 400 });
  } catch (err: unknown) {
    logError('admin/wipe-database route error', err);
    return serverError();
  }
}
