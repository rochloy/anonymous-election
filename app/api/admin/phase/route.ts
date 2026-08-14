import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { requireAdmin } from '../auth';
import { Resend } from 'resend';

const resend = new Resend(process.env.RESEND_API_KEY);

// Valid phase transitions
const VALID_TRANSITIONS: Record<string, string[]> = {
  SETUP: ['NOMINATION'],
  NOMINATION: ['NOMINATION_CLOSED'],
  NOMINATION_CLOSED: ['VOTING'],
  VOTING: ['VOTING_CLOSED'],
  VOTING_CLOSED: ['COMPLETED'],
  COMPLETED: [], // Terminal state
};

export async function GET(req: Request) {
  const authFail = requireAdmin(req);
  if (authFail) return authFail;

  try {
    const { data, error } = await supabaseServer
      .from('election_settings')
      .select('*')
      .eq('id', 1)
      .single();

    if (error || !data) {
      return NextResponse.json({ error: 'Election settings not found' }, { status: 404 });
    }

    const currentPhase = data.current_phase;
    const allowedNextPhases = VALID_TRANSITIONS[currentPhase] || [];

    return NextResponse.json({
      ...data,
      allowedNextPhases,
      isTerminal: allowedNextPhases.length === 0,
    });
  } catch {
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}

export async function POST(req: Request) {
  const authFail = requireAdmin(req);
  if (authFail) return authFail;

  try {
    const body = await req.json();
    const { action, phase, confirmText, token } = body;

    // Get current phase
    const { data: settings, error: settingsError } = await supabaseServer
      .from('election_settings')
      .select('current_phase')
      .eq('id', 1)
      .single();

    if (settingsError || !settings) {
      return NextResponse.json({ error: 'Election settings not found' }, { status: 404 });
    }

    const currentPhase = settings.current_phase;

    // Action: request phase change (sends email with confirmation link)
    if (action === 'request') {
      if (!phase) {
        return NextResponse.json({ error: 'Target phase required' }, { status: 400 });
      }

      // Validate transition
      const allowed = VALID_TRANSITIONS[currentPhase] || [];
      if (!allowed.includes(phase)) {
        return NextResponse.json(
          { error: `Invalid transition from ${currentPhase} to ${phase}. Allowed: ${allowed.join(', ') || 'none (terminal)'}` },
          { status: 400 }
        );
      }

      // Generate secure token for email confirmation
      const crypto = await import('crypto');
      const confirmationToken = crypto.randomBytes(32).toString('hex');
      const tokenHash = crypto.createHash('sha256').update(confirmationToken).digest('hex');

      // Store token with expiry (1 hour)
      const expiresAt = new Date(Date.now() + 60 * 60 * 1000);

      const { error: tokenError } = await supabaseServer
        .from('phase_change_tokens')
        .insert({
          token_hash: tokenHash,
          from_phase: currentPhase,
          to_phase: phase,
          expires_at: expiresAt.toISOString(),
        });

      if (tokenError) {
        return NextResponse.json({ error: 'Failed to create confirmation token' }, { status: 500 });
      }

      // Send email to admin(s)
      const adminEmail = process.env.ADMIN_EMAIL || process.env.FROM_EMAIL;
      if (adminEmail && resend) {
        const confirmUrl = `${process.env.APP_BASE_URL || 'http://localhost:3000'}/admin/phase/confirm?token=${confirmationToken}&phase=${phase}`;
        
        await resend.emails.send({
          from: process.env.FROM_EMAIL || 'Elections <elections@example.com>',
          to: adminEmail,
          subject: `Confirm Election Phase Change: ${currentPhase} → ${phase}`,
          html: `
            <p>An election phase change has been requested.</p>
            <p><strong>Current phase:</strong> ${currentPhase}</p>
            <p><strong>Requested phase:</strong> ${phase}</p>
            <p>Click the link below to confirm this change (valid for 1 hour):</p>
            <p><a href="${confirmUrl}">${confirmUrl}</a></p>
            <p>If you did not request this, please ignore this email.</p>
          `,
        });
      }

      return NextResponse.json({ 
        success: true, 
        message: 'Confirmation email sent. Check your inbox to proceed.' 
      });
    }

    // Action: confirm phase change via email token
    if (action === 'confirm') {
      if (!token || !phase) {
        return NextResponse.json({ error: 'Token and phase required' }, { status: 400 });
      }

      const crypto = await import('crypto');
      const tokenHash = crypto.createHash('sha256').update(token).digest('hex');

      // Verify token
      const { data: tokenData, error: tokenError } = await supabaseServer
        .from('phase_change_tokens')
        .select('*')
        .eq('token_hash', tokenHash)
        .eq('to_phase', phase)
        .single();

      if (tokenError || !tokenData) {
        return NextResponse.json({ error: 'Invalid or expired confirmation link' }, { status: 400 });
      }

      if (new Date(tokenData.expires_at) < new Date()) {
        return NextResponse.json({ error: 'Confirmation link has expired' }, { status: 400 });
      }

      if (tokenData.used) {
        return NextResponse.json({ error: 'Confirmation link already used' }, { status: 400 });
      }

      // Mark token as used
      await supabaseServer
        .from('phase_change_tokens')
        .update({ used: true, used_at: new Date().toISOString() })
        .eq('token_hash', tokenHash);

      // Perform phase change
      const { error: updateError } = await supabaseServer
        .from('election_settings')
        .update({ current_phase: phase, updated_at: new Date().toISOString() })
        .eq('id', 1);

      if (updateError) {
        return NextResponse.json({ error: 'Failed to update phase' }, { status: 500 });
      }

      // Audit log
      await supabaseServer
        .from('vote_audit_log')
        .insert({
          action: 'PHASE_CHANGE',
          admin_id: null, // Could be enhanced to track which admin
          details: { from_phase: currentPhase, to_phase: phase, method: 'email_confirmation' },
        });

      return NextResponse.json({ 
        success: true, 
        message: `Phase changed from ${currentPhase} to ${phase}`,
        newPhase: phase,
      });
    }

    // Action: execute phase change with typed confirmation (for UI dialog)
    if (action === 'execute') {
      if (!phase || confirmText !== 'CONFIRM') {
        return NextResponse.json({ error: 'Must type CONFIRM to proceed' }, { status: 400 });
      }

      // Validate transition
      const allowed = VALID_TRANSITIONS[currentPhase] || [];
      if (!allowed.includes(phase)) {
        return NextResponse.json(
          { error: `Invalid transition from ${currentPhase} to ${phase}. Allowed: ${allowed.join(', ') || 'none (terminal)'}` },
          { status: 400 }
        );
      }

      // Perform phase change
      const { error: updateError } = await supabaseServer
        .from('election_settings')
        .update({ current_phase: phase, updated_at: new Date().toISOString() })
        .eq('id', 1);

      if (updateError) {
        return NextResponse.json({ error: 'Failed to update phase' }, { status: 500 });
      }

      // Audit log
      await supabaseServer
        .from('vote_audit_log')
        .insert({
          action: 'PHASE_CHANGE',
          admin_id: null,
          details: { from_phase: currentPhase, to_phase: phase, method: 'ui_confirmation' },
        });

      return NextResponse.json({ 
        success: true, 
        message: `Phase changed from ${currentPhase} to ${phase}`,
        newPhase: phase,
      });
    }

    return NextResponse.json({ error: 'Invalid action' }, { status: 400 });
  } catch (err: unknown) {
    const errorMsg = err instanceof Error ? err.message : 'Server error';
    return NextResponse.json({ error: errorMsg }, { status: 500 });
  }
}