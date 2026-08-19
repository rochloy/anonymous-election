import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { requireAdmin, getAdminSession } from '../auth';

export async function GET() {
  const authFail = await requireAdmin();
  if (authFail) return authFail;

  try {
    const { data, error } = await supabaseServer
      .from('candidates')
      .select('*')
      .order('created_at', { ascending: true });

    if (error) {
      return NextResponse.json({ error: error.message }, { status: 500 });
    }

    return NextResponse.json({ candidates: data || [] });
  } catch {
    return NextResponse.json({ error: 'Server error' }, { status: 500 });
  }
}

export async function POST(req: Request) {
  const authFail = await requireAdmin();
  if (authFail) return authFail;

  const adminSession = await getAdminSession();

  try {
    const { full_name, statement, photo_url, is_active } = await req.json();

    if (!full_name || !full_name.trim()) {
      return NextResponse.json({ error: 'Candidate name is required' }, { status: 400 });
    }

    const { data, error } = await supabaseServer
      .from('candidates')
      .insert({
        full_name: full_name.trim(),
        statement: statement?.trim() || null,
        photo_url: photo_url?.trim() || null,
        is_active: is_active !== false,
      })
      .select()
      .single();

    if (error) {
      return NextResponse.json({ error: error.message }, { status: 500 });
    }

    // Audit log
    await supabaseServer
      .from('vote_audit_log')
      .insert({
        action: 'CANDIDATE_CREATED',
        admin_id: adminSession?.id || null,
        details: { candidate_id: data.id, full_name: data.full_name, admin_ip: adminSession?.ip_address },
      });

    return NextResponse.json({ success: true, candidate: data });
  } catch (err: unknown) {
    const errorMsg = err instanceof Error ? err.message : 'Server error';
    return NextResponse.json({ error: errorMsg }, { status: 500 });
  }
}

export async function PATCH(req: Request) {
  const authFail = await requireAdmin();
  if (authFail) return authFail;

  const adminSession = await getAdminSession();

  try {
    const { id, full_name, statement, photo_url, is_active } = await req.json();

    if (!id) {
      return NextResponse.json({ error: 'Candidate ID is required' }, { status: 400 });
    }

    const updates: Record<string, unknown> = {};
    if (full_name !== undefined) updates.full_name = full_name.trim();
    if (statement !== undefined) updates.statement = statement?.trim() || null;
    if (photo_url !== undefined) updates.photo_url = photo_url?.trim() || null;
    if (is_active !== undefined) updates.is_active = is_active;

    if (Object.keys(updates).length === 0) {
      return NextResponse.json({ error: 'No fields to update' }, { status: 400 });
    }

    const { data, error } = await supabaseServer
      .from('candidates')
      .update(updates)
      .eq('id', id)
      .select()
      .single();

    if (error) {
      return NextResponse.json({ error: error.message }, { status: 500 });
    }

    // Audit log
    await supabaseServer
      .from('vote_audit_log')
      .insert({
        action: 'CANDIDATE_UPDATED',
        admin_id: adminSession?.id || null,
        details: { candidate_id: id, updates, admin_ip: adminSession?.ip_address },
      });

    return NextResponse.json({ success: true, candidate: data });
  } catch (err: unknown) {
    const errorMsg = err instanceof Error ? err.message : 'Server error';
    return NextResponse.json({ error: errorMsg }, { status: 500 });
  }
}

export async function DELETE(req: Request) {
  const authFail = await requireAdmin();
  if (authFail) return authFail;

  const adminSession = await getAdminSession();

  try {
    const { searchParams } = new URL(req.url);
    const id = searchParams.get('id');

    if (!id) {
      return NextResponse.json({ error: 'Candidate ID is required' }, { status: 400 });
    }

    // Check if candidate has votes
    const { data: votes, error: votesError } = await supabaseServer
      .from('ballots')
      .select('id')
      .eq('candidate_id', id)
      .limit(1);

    if (votesError) {
      return NextResponse.json({ error: votesError.message }, { status: 500 });
    }

    if (votes && votes.length > 0) {
      return NextResponse.json(
        { error: 'Cannot delete candidate with existing votes. Deactivate instead.' },
        { status: 400 }
      );
    }

    const { error } = await supabaseServer
      .from('candidates')
      .delete()
      .eq('id', id);

    if (error) {
      return NextResponse.json({ error: error.message }, { status: 500 });
    }

    // Audit log
    await supabaseServer
      .from('vote_audit_log')
      .insert({
        action: 'CANDIDATE_DELETED',
        admin_id: adminSession?.id || null,
        details: { candidate_id: id, admin_ip: adminSession?.ip_address },
      });

    return NextResponse.json({ success: true, message: 'Candidate deleted' });
  } catch (err: unknown) {
    const errorMsg = err instanceof Error ? err.message : 'Server error';
    return NextResponse.json({ error: errorMsg }, { status: 500 });
  }
}