import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { requireAdmin, requireAdminWithCsrf, getAdminSession } from '../auth';
import { insertAuditLog } from '@/lib/audit-log';

const MIN_VOTING_TOKEN_TTL_HOURS = 1;
const MAX_VOTING_TOKEN_TTL_HOURS = 2160;

export async function GET() {
  const authFail = await requireAdmin();
  if (authFail) return authFail;

  try {
    const { data, error } = await supabaseServer
      .from('election_settings')
      .select('voting_token_ttl_hours, allow_write_ins, max_nominees_per_member, age_requirement_enabled, minimum_voting_age, allow_adding_member_during_voting')
      .eq('id', 1)
      .single();

    if (error) {
      return NextResponse.json({ error: error.message }, { status: 500 });
    }

    return NextResponse.json({
      votingTokenTtlHours: data.voting_token_ttl_hours,
      allowWriteIns: data.allow_write_ins,
      maxNomineesPerMember: data.max_nominees_per_member,
      ageRequirementEnabled: data.age_requirement_enabled,
      minimumVotingAge: data.minimum_voting_age,
      allowAddingMemberDuringVoting: data.allow_adding_member_during_voting,
    });
  } catch {
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}

export async function PATCH(req: Request) {
  const authFail = await requireAdminWithCsrf(req);
  if (authFail) return authFail;

  const adminSession = await getAdminSession();

  try {
    const { votingTokenTtlHours, allowWriteIns, maxNomineesPerMember, ageRequirementEnabled, minimumVotingAge, allowAddingMemberDuringVoting } = await req.json();

    const patch: Record<string, unknown> = {};

    if (votingTokenTtlHours !== undefined) {
      if (
        !Number.isInteger(votingTokenTtlHours) ||
        votingTokenTtlHours < MIN_VOTING_TOKEN_TTL_HOURS ||
        votingTokenTtlHours > MAX_VOTING_TOKEN_TTL_HOURS
      ) {
        return NextResponse.json(
          {
            error: `votingTokenTtlHours must be an integer between ${MIN_VOTING_TOKEN_TTL_HOURS} and ${MAX_VOTING_TOKEN_TTL_HOURS}`,
          },
          { status: 400 }
        );
      }
      patch.voting_token_ttl_hours = votingTokenTtlHours;
    }

    if (allowWriteIns !== undefined) {
      if (typeof allowWriteIns !== 'boolean') {
        return NextResponse.json({ error: 'allowWriteIns must be a boolean' }, { status: 400 });
      }
      patch.allow_write_ins = allowWriteIns;
    }

    if (maxNomineesPerMember !== undefined) {
      if (!Number.isInteger(maxNomineesPerMember) || maxNomineesPerMember < 1 || maxNomineesPerMember > 3) {
        return NextResponse.json(
          { error: 'maxNomineesPerMember must be an integer between 1 and 3' },
          { status: 400 }
        );
      }
      patch.max_nominees_per_member = maxNomineesPerMember;
    }

    if (ageRequirementEnabled !== undefined) {
      if (typeof ageRequirementEnabled !== 'boolean') {
        return NextResponse.json({ error: 'ageRequirementEnabled must be a boolean' }, { status: 400 });
      }
      if (ageRequirementEnabled === true) {
        if (minimumVotingAge === undefined || minimumVotingAge === null) {
          return NextResponse.json({ error: 'minimumVotingAge is required when ageRequirementEnabled is true' }, { status: 400 });
        }
        if (!Number.isInteger(minimumVotingAge) || minimumVotingAge < 1 || minimumVotingAge > 130) {
          return NextResponse.json({ error: 'minimumVotingAge must be an integer between 1 and 130' }, { status: 400 });
        }
      }
      patch.age_requirement_enabled = ageRequirementEnabled;
      if (minimumVotingAge !== undefined) {
        patch.minimum_voting_age = minimumVotingAge;
      }
    }

    if (allowAddingMemberDuringVoting !== undefined) {
      if (typeof allowAddingMemberDuringVoting !== 'boolean') {
        return NextResponse.json({ error: 'allowAddingMemberDuringVoting must be a boolean' }, { status: 400 });
      }
      // Phase gate: this setting is only changeable during
      // SETUP/NOMINATION/NOMINATION_CLOSED/VOTING (not VOTING_CLOSED/COMPLETED).
      const { data: phaseData, error: phaseError } = await supabaseServer
        .from('election_settings')
        .select('current_phase')
        .eq('id', 1)
        .single();
      if (phaseError) {
        return NextResponse.json({ error: phaseError.message }, { status: 500 });
      }
      if (!['SETUP', 'NOMINATION', 'NOMINATION_CLOSED', 'VOTING'].includes(phaseData.current_phase)) {
        return NextResponse.json(
          { error: 'This setting can only be changed during SETUP, NOMINATION, NOMINATION_CLOSED, or VOTING phases.' },
          { status: 400 }
        );
      }
      patch.allow_adding_member_during_voting = allowAddingMemberDuringVoting;
    }

    if (Object.keys(patch).length === 0) {
      return NextResponse.json({ error: 'No valid settings provided' }, { status: 400 });
    }

    const { data: updatedSettings, error } = await supabaseServer
      .from('election_settings')
      .update(patch)
      .eq('id', 1)
      .select('voting_token_ttl_hours, allow_write_ins, max_nominees_per_member, age_requirement_enabled, minimum_voting_age, allow_adding_member_during_voting')
      .single();

    if (error || !updatedSettings) {
      return NextResponse.json(
        { error: error?.message || 'Failed to update election settings' },
        { status: 500 }
      );
    }

    await insertAuditLog({
      action: 'SETTINGS_UPDATED',
      adminId: adminSession?.id || null,
      details: {
        ...patch,
        admin_ip: adminSession?.ip_address,
      },
    });

    return NextResponse.json({
      success: true,
      votingTokenTtlHours: updatedSettings.voting_token_ttl_hours,
      allowWriteIns: updatedSettings.allow_write_ins,
      maxNomineesPerMember: updatedSettings.max_nominees_per_member,
      ageRequirementEnabled: updatedSettings.age_requirement_enabled,
      minimumVotingAge: updatedSettings.minimum_voting_age,
      allowAddingMemberDuringVoting: updatedSettings.allow_adding_member_during_voting,
    });
  } catch (err: unknown) {
    const errorMsg = err instanceof Error ? err.message : 'Server error';
    return NextResponse.json({ error: errorMsg }, { status: 500 });
  }
}
