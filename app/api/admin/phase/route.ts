import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { requireAdmin, requireAdminWithCsrf, getAdminSession } from '../auth';
import { Resend } from 'resend';
import { apiError, validationError, notFoundError } from '@/lib/api-errors';
import { validateLength, INPUT_LIMITS } from '@/lib/input-validation';
import { insertAuditLog } from '@/lib/audit-log';

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

export async function GET() {
  const authFail = await requireAdmin();
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

    // Check for used tokens for each allowed next phase (for three-fold confirmation flow)
    // This tells the UI if the user has clicked the email confirmation link
    // Only show if token was used within the last hour (token expiry window)
    const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000).toISOString();
    let pendingConfirmation: { phase: string; confirmedAt: string; used: boolean } | null = null;
    if (allowedNextPhases.length > 0) {
      // First check for used tokens (email link clicked)
      const { data: usedTokens } = await supabaseServer
        .from('phase_change_tokens')
        .select('to_phase, used_at, used')
        .eq('from_phase', currentPhase)
        .eq('used', true)
        .in('to_phase', allowedNextPhases)
        .gte('used_at', oneHourAgo)
        .order('used_at', { ascending: false })
        .limit(1);

      if (usedTokens && usedTokens.length > 0) {
        pendingConfirmation = {
          phase: usedTokens[0].to_phase,
          confirmedAt: usedTokens[0].used_at,
          used: true,
        };
      } else {
        // Check for unused tokens (email sent but link not clicked yet)
        const { data: unusedTokens } = await supabaseServer
          .from('phase_change_tokens')
          .select('to_phase, created_at, used')
          .eq('from_phase', currentPhase)
          .eq('used', false)
          .in('to_phase', allowedNextPhases)
          .gte('expires_at', new Date().toISOString())
          .order('created_at', { ascending: false })
          .limit(1);

        if (unusedTokens && unusedTokens.length > 0) {
          pendingConfirmation = {
            phase: unusedTokens[0].to_phase,
            confirmedAt: unusedTokens[0].created_at,
            used: false,
          };
        }
      }
    }

    // Check for reset election pending confirmation (to SETUP from any phase)
    let pendingResetConfirmation: { confirmedAt: string; used: boolean } | null = null;
    const { data: usedResetTokens } = await supabaseServer
      .from('phase_change_tokens')
      .select('used_at, used')
      .eq('from_phase', currentPhase)
      .eq('to_phase', 'SETUP')
      .eq('used', true)
      .gte('used_at', oneHourAgo)
      .order('used_at', { ascending: false })
      .limit(1);

    if (usedResetTokens && usedResetTokens.length > 0) {
      pendingResetConfirmation = {
        confirmedAt: usedResetTokens[0].used_at,
        used: true,
      };
    } else {
      // Check for unused reset tokens
      const { data: unusedResetTokens } = await supabaseServer
        .from('phase_change_tokens')
        .select('created_at, used')
        .eq('from_phase', currentPhase)
        .eq('to_phase', 'SETUP')
        .eq('used', false)
        .gte('expires_at', new Date().toISOString())
        .order('created_at', { ascending: false })
        .limit(1);

      if (unusedResetTokens && unusedResetTokens.length > 0) {
        pendingResetConfirmation = {
          confirmedAt: unusedResetTokens[0].created_at,
          used: false,
        };
      }
    }

    return NextResponse.json({
      ...data,
      allowedNextPhases,
      isTerminal: allowedNextPhases.length === 0,
      pendingConfirmation,
      pendingResetConfirmation,
    }, {
      headers: {
        'Cache-Control': 'no-store, no-cache, must-revalidate, proxy-revalidate',
        'Pragma': 'no-cache',
        'Expires': '0',
      },
    });
  } catch {
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}

export async function POST(req: Request) {
  // Parse body first to check action
  let body: {
    action?: string;
    phase?: string;
    confirmText?: string;
    token?: string;
    nomination_start?: string | null;
    nomination_end?: string | null;
    voting_start?: string | null;
    voting_end?: string | null;
  };
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ error: 'Invalid request body' }, { status: 400 });
  }

  const { action, phase, confirmText, token, nomination_start, nomination_end, voting_start, voting_end } = body;

  // Action: confirm phase change via email token — NO auth required, token is the security mechanism
  if (action === 'confirm') {
    return handleConfirmPhaseChange(req, token, phase);
  }

  // Action: verify reset token (for UI step 2 -> 3) — NO auth required, token is the security mechanism
  if (action === 'verify_reset_token') {
    return handleVerifyResetToken(req);
  }

  // All other actions require admin auth + CSRF
  const authFail = await requireAdminWithCsrf(req);
  if (authFail) return authFail;

  // Get admin session for audit logging
  const adminSession = await getAdminSession();

  try {
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

      // Check for any pending confirmation (unused token) for any transition from current phase
      // This prevents concurrent phase change and reset operations
      const { data: pendingTokens } = await supabaseServer
        .from('phase_change_tokens')
        .select('to_phase, used')
        .eq('from_phase', currentPhase)
        .eq('used', false)
        .gte('expires_at', new Date().toISOString())
        .limit(1);

      if (pendingTokens && pendingTokens.length > 0) {
        const pendingPhase = pendingTokens[0].to_phase;
        const actionType = pendingPhase === 'SETUP' ? 'reset election' : 'phase change';
        return NextResponse.json({
          error: `A ${actionType} to ${pendingPhase} is already pending. Please complete or cancel it first.`
        }, { status: 400 });
      }

      // Invalidate any existing tokens for this transition (prevents stale tokens from bypassing email confirmation)
      await supabaseServer
        .from('phase_change_tokens')
        .delete()
        .eq('from_phase', currentPhase)
        .eq('to_phase', phase);

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
          admin_session_id: adminSession?.id || null,
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
          text: `An election phase change has been requested.

Current phase: ${currentPhase}
Requested phase: ${phase}

Click the link below to confirm this change (valid for 1 hour):
${confirmUrl}

If you did not request this, please ignore this email.`,
        });
      }

      return NextResponse.json({ 
        success: true, 
        message: 'Confirmation email sent. Check your inbox to proceed.' 
      });
    }

    // Action: confirm phase change via email token (Step 1 of 3: email link click)
    // ONLY marks token as used, does NOT change phase. Phase change happens in 'execute' action.
    if (action === 'confirm') {
      if (!token || !phase) {
        return NextResponse.json({ error: 'Token and phase required' }, { status: 400 });
      }

      const crypto = await import('crypto');
      const tokenHash = crypto.createHash('sha256').update(token).digest('hex');

      // Get current phase for validation
      const { data: settings, error: settingsError } = await supabaseServer
        .from('election_settings')
        .select('current_phase')
        .eq('id', 1)
        .single();

      if (settingsError || !settings) {
        return NextResponse.json({ error: 'Election settings not found' }, { status: 404 });
      }

      const currentPhase = settings.current_phase;

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

      // Validate transition
      const allowed = VALID_TRANSITIONS[currentPhase] || [];
      if (!allowed.includes(phase)) {
        return NextResponse.json(
          { error: `Invalid transition from ${currentPhase} to ${phase}. Allowed: ${allowed.join(', ') || 'none (terminal)'}` },
          { status: 400 }
        );
      }

      // Mark token as used (Step 1 complete - email access confirmed)
      await supabaseServer
        .from('phase_change_tokens')
        .update({ used: true, used_at: new Date().toISOString() })
        .eq('token_hash', tokenHash);

      // Audit log for email confirmation step
      await insertAuditLog({
        action: 'PHASE_CHANGE_EMAIL_CONFIRMED',
        adminId: null,
        details: { from_phase: currentPhase, to_phase: phase, method: 'email_link' },
      });

      const isReset = phase === 'SETUP';
      return NextResponse.json({ 
        success: true, 
        message: isReset 
          ? 'Email confirmed. Return to dashboard and type RESET to complete the phase reset.'
          : 'Email confirmed. Return to dashboard and type CONFIRM to complete the phase change.',
      });
    }

    // Action: verify email confirmation was completed (for UI step 2 -> 3)
    if (action === 'verify_token') {
      if (!phase) {
        return NextResponse.json({ error: 'Target phase required' }, { status: 400 });
      }

      // Verify email confirmation was completed (token exists and is used)
      const { data: tokenData, error: tokenError } = await supabaseServer
        .from('phase_change_tokens')
        .select('*')
        .eq('from_phase', currentPhase)
        .eq('to_phase', phase)
        .eq('used', true)
        .order('created_at', { ascending: false })
        .limit(1)
        .maybeSingle();

      if (tokenError || !tokenData) {
        return NextResponse.json({ 
          error: 'Email confirmation required. Please click the link in the confirmation email first.' 
        }, { status: 400 });
      }

      return NextResponse.json({ 
        success: true, 
        message: 'Email confirmation verified. You may proceed to final confirmation.' 
      });
    }

    // Action: execute phase change with typed confirmation (for UI dialog)
    if (action === 'execute') {
      if (!phase) {
        return NextResponse.json({ error: 'Target phase required' }, { status: 400 });
      }

      // Verify email confirmation was completed FIRST (before other validations)
      const { data: tokenData, error: tokenError } = await supabaseServer
        .from('phase_change_tokens')
        .select('*')
        .eq('from_phase', currentPhase)
        .eq('to_phase', phase)
        .eq('used', true)
        .order('created_at', { ascending: false })
        .limit(1)
        .maybeSingle();

      if (tokenError || !tokenData) {
        return NextResponse.json({ 
          error: 'Email confirmation required. Please click the link in the confirmation email first.' 
        }, { status: 400 });
      }

      // Validate confirmText length
      const confirmValidation = validateLength(confirmText, 'confirmText', INPUT_LIMITS.phase.confirmText);
      if (!confirmValidation.valid) {
        return NextResponse.json({ error: confirmValidation.error }, { status: 400 });
      }
      
      if (confirmText !== 'CONFIRM') {
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

      // Delete the used token for this transition (cleanup after successful phase change)
      await supabaseServer
        .from('phase_change_tokens')
        .delete()
        .eq('from_phase', currentPhase)
        .eq('to_phase', phase)
        .eq('used', true);

      // Audit log
      await insertAuditLog({
        action: 'PHASE_CHANGE',
        adminId: adminSession?.id || null,
        details: { from_phase: currentPhase, to_phase: phase, method: 'ui_confirmation', admin_ip: adminSession?.ip_address },
      });

      return NextResponse.json({ 
        success: true, 
        message: `Phase changed from ${currentPhase} to ${phase}`,
        newPhase: phase,
      });
    }

    // Action: request reset election (sends email with confirmation link)
    if (action === 'request_reset') {
      // Check for any pending confirmation (unused token) for any transition from current phase
      // This prevents concurrent phase change and reset operations
      const { data: pendingTokens } = await supabaseServer
        .from('phase_change_tokens')
        .select('to_phase, used')
        .eq('from_phase', currentPhase)
        .eq('used', false)
        .gte('expires_at', new Date().toISOString())
        .limit(1);

      if (pendingTokens && pendingTokens.length > 0) {
        const pendingPhase = pendingTokens[0].to_phase;
        const actionType = pendingPhase === 'SETUP' ? 'reset election' : 'phase change';
        return NextResponse.json({
          error: `A ${actionType} to ${pendingPhase} is already pending. Please complete or cancel it first.`
        }, { status: 400 });
      }

      // Invalidate any existing tokens for this transition (prevents stale tokens from bypassing email confirmation)
      await supabaseServer
        .from('phase_change_tokens')
        .delete()
        .eq('from_phase', currentPhase)
        .eq('to_phase', 'SETUP');

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
          to_phase: 'SETUP',
          expires_at: expiresAt.toISOString(),
          admin_session_id: adminSession?.id || null,
        });

      if (tokenError) {
        return NextResponse.json({ error: 'Failed to create confirmation token' }, { status: 500 });
      }

      // Send email to admin(s)
      const adminEmail = process.env.ADMIN_EMAIL || process.env.FROM_EMAIL;
      if (adminEmail && resend) {
        const confirmUrl = `${process.env.APP_BASE_URL || 'http://localhost:3000'}/admin/phase/confirm?token=${confirmationToken}&phase=SETUP`;
        
        await resend.emails.send({
          from: process.env.FROM_EMAIL || 'Elections <elections@example.com>',
          to: adminEmail,
          subject: `Confirm Election Reset: ${currentPhase} → SETUP`,
          html: `
            <p>An election reset has been requested.</p>
            <p><strong>Current phase:</strong> ${currentPhase}</p>
            <p><strong>Requested phase:</strong> SETUP</p>
            <p>Click the link below to confirm this reset (valid for 1 hour):</p>
            <p><a href="${confirmUrl}">${confirmUrl}</a></p>
            <p>If you did not request this, please ignore this email.</p>
          `,
          text: `An election reset has been requested.

Current phase: ${currentPhase}
Requested phase: SETUP

Click the link below to confirm this reset (valid for 1 hour):
${confirmUrl}

If you did not request this, please ignore this email.`,
        });
      }

      return NextResponse.json({ 
        success: true, 
        message: 'Confirmation email sent. Check your inbox to proceed.' 
      });
    }

    // Action: verify reset token (for UI step 2 -> 3)
    if (action === 'verify_reset_token') {
      // Verify email confirmation was completed (token exists and is used)
      const { data: tokenData, error: tokenError } = await supabaseServer
        .from('phase_change_tokens')
        .select('*')
        .eq('from_phase', currentPhase)
        .eq('to_phase', 'SETUP')
        .eq('used', true)
        .order('created_at', { ascending: false })
        .limit(1)
        .maybeSingle();

      if (tokenError || !tokenData) {
        return NextResponse.json({ 
          error: 'Email confirmation required. Please click the link in the confirmation email first.' 
        }, { status: 400 });
      }

      return NextResponse.json({ 
        success: true, 
        message: 'Email confirmation verified. You may proceed to final confirmation.' 
      });
    }

    // Action: execute reset with typed confirmation (for UI dialog)
    if (action === 'execute_reset') {
      if (!confirmText) {
        return NextResponse.json({ error: 'Confirmation text required' }, { status: 400 });
      }

      // Verify email confirmation was completed FIRST (before other validations)
      const { data: tokenData, error: tokenError } = await supabaseServer
        .from('phase_change_tokens')
        .select('*')
        .eq('from_phase', currentPhase)
        .eq('to_phase', 'SETUP')
        .eq('used', true)
        .order('created_at', { ascending: false })
        .limit(1)
        .maybeSingle();

      if (tokenError || !tokenData) {
        return NextResponse.json({ 
          error: 'Email confirmation required. Please click the link in the confirmation email first.' 
        }, { status: 400 });
      }

      // Validate confirmText length
      const confirmValidation = validateLength(confirmText, 'confirmText', INPUT_LIMITS.phase.confirmText);
      if (!confirmValidation.valid) {
        return NextResponse.json({ error: confirmValidation.error }, { status: 400 });
      }
      
      if (confirmText !== 'RESET') {
        return NextResponse.json({ error: 'Must type RESET to proceed' }, { status: 400 });
      }

      // Perform reset
      const { error: updateError } = await supabaseServer
        .from('election_settings')
        .update({ current_phase: 'SETUP', updated_at: new Date().toISOString() })
        .eq('id', 1);

      if (updateError) {
        return NextResponse.json({ error: 'Failed to reset election' }, { status: 500 });
      }

      // Delete the used token for this transition (cleanup after successful reset)
      await supabaseServer
        .from('phase_change_tokens')
        .delete()
        .eq('from_phase', currentPhase)
        .eq('to_phase', 'SETUP')
        .eq('used', true);

      // Audit log
      await insertAuditLog({
        action: 'PHASE_CHANGE',
        adminId: adminSession?.id || null,
        details: { from_phase: currentPhase, to_phase: 'SETUP', method: 'admin_reset', admin_ip: adminSession?.ip_address },
      });

      return NextResponse.json({
        success: true,
        message: 'Election reset to SETUP phase',
        newPhase: 'SETUP',
      });
    }

    // Action: cancel pending phase change or reset (deletes unused token)
    if (action === 'cancel') {
      if (!phase) {
        return NextResponse.json({ error: 'Target phase required' }, { status: 400 });
      }

      // Delete unused token for this transition
      const { error: deleteError } = await supabaseServer
        .from('phase_change_tokens')
        .delete()
        .eq('from_phase', currentPhase)
        .eq('to_phase', phase)
        .eq('used', false);

      if (deleteError) {
        return NextResponse.json({ error: 'Failed to cancel' }, { status: 500 });
      }

      // Audit log
      await insertAuditLog({
        action: 'PHASE_CHANGE_CANCELLED',
        adminId: adminSession?.id || null,
        details: { from_phase: currentPhase, to_phase: phase, admin_ip: adminSession?.ip_address },
      });

      return NextResponse.json({
        success: true,
        message: `Pending ${phase === 'SETUP' ? 'reset election' : 'phase change'} cancelled.`,
      });
    }


    // Action: update election dates
    if (action === 'update_dates') {
      const { nomination_start, nomination_end, voting_start, voting_end } = body;

      const updates: Record<string, string | null> = {};
      if (nomination_start !== undefined) updates.nomination_start = nomination_start;
      if (nomination_end !== undefined) updates.nomination_end = nomination_end;
      if (voting_start !== undefined) updates.voting_start = voting_start;
      if (voting_end !== undefined) updates.voting_end = voting_end;

      if (Object.keys(updates).length === 0) {
        return NextResponse.json({ error: 'No date fields provided' }, { status: 400 });
      }

      updates.updated_at = new Date().toISOString();

      const { error: updateError } = await supabaseServer
        .from('election_settings')
        .update(updates)
        .eq('id', 1);

      if (updateError) {
        return NextResponse.json({ error: 'Failed to update election dates' }, { status: 500 });
      }

      // Audit log
      await insertAuditLog({
        action: 'ELECTION_DATES_UPDATED',
        adminId: adminSession?.id || null,
        details: { ...updates, admin_ip: adminSession?.ip_address },
      });

      return NextResponse.json({
        success: true,
        message: 'Election dates updated',
      });
    }

    return NextResponse.json({ error: 'Invalid action' }, { status: 400 });
  } catch (err: unknown) {
    return apiError(err);
  }
}

// Handler for email confirmation link (no auth required - token is security mechanism)
async function handleConfirmPhaseChange(req: Request, token: string | undefined, phase: string | undefined) {
  if (!token || !phase) {
    return NextResponse.json({ error: 'Token and phase required' }, { status: 400 });
  }

  const crypto = await import('crypto');
  const tokenHash = crypto.createHash('sha256').update(token).digest('hex');

  // Get current phase for validation
  const { data: settings, error: settingsError } = await supabaseServer
    .from('election_settings')
    .select('current_phase')
    .eq('id', 1)
    .single();

  if (settingsError || !settings) {
    return NextResponse.json({ error: 'Election settings not found' }, { status: 404 });
  }

  const currentPhase = settings.current_phase;

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

  // Validate transition (skip for reset - SETUP is allowed from any phase as admin reset)
  const isReset = phase === 'SETUP';
  if (!isReset) {
    const allowed = VALID_TRANSITIONS[currentPhase] || [];
    if (!allowed.includes(phase)) {
      return NextResponse.json(
        { error: `Invalid transition from ${currentPhase} to ${phase}. Allowed: ${allowed.join(', ') || 'none (terminal)'}` },
        { status: 400 }
      );
    }
  }

  // Mark token as used (Step 1 complete - email access confirmed)
  await supabaseServer
    .from('phase_change_tokens')
    .update({ used: true, used_at: new Date().toISOString() })
    .eq('token_hash', tokenHash);

  // Audit log for email confirmation step
  await insertAuditLog({
    action: 'PHASE_CHANGE_EMAIL_CONFIRMED',
    adminId: null,
    details: { from_phase: currentPhase, to_phase: phase, method: 'email_link' },
  });

  return NextResponse.json({
    success: true,
    message: isReset
      ? 'Email confirmed. Return to dashboard and type RESET to complete the phase reset.'
      : 'Email confirmed. Return to dashboard and type CONFIRM to complete the phase change.',
  });
}

// Handler for verify reset token (no auth required - token is security mechanism)
async function handleVerifyResetToken(req: Request) {
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

  // Verify email confirmation was completed (token exists and is used)
  const { data: tokenData, error: tokenError } = await supabaseServer
    .from('phase_change_tokens')
    .select('*')
    .eq('from_phase', currentPhase)
    .eq('to_phase', 'SETUP')
    .eq('used', true)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  if (tokenError || !tokenData) {
    return NextResponse.json({
      error: 'Email confirmation required. Please click the link in the confirmation email first.'
    }, { status: 400 });
  }

  return NextResponse.json({
    success: true,
    message: 'Email confirmation verified. You may proceed to final confirmation.'
  });
}