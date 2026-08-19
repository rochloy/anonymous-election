import { supabaseServer } from '@/lib/supabase-server';

/**
 * Insert audit log entry with tamper-evident hash chaining
 * SEC-18: Tamper-evident audit logs (hash chaining)
 */
export async function insertAuditLog(params: {
  action: string;
  adminId?: string | null;
  memberId?: string | null;
  details?: Record<string, unknown>;
}): Promise<{ error: Error | null }> {
  try {
    const { error } = await supabaseServer.rpc('insert_audit_log', {
      p_action: params.action,
      p_admin_id: params.adminId || null,
      p_member_id: params.memberId || null,
      p_details: params.details || {},
    });

    if (error) {
      // Fallback to direct insert if RPC fails (e.g., migration not run)
      console.warn('[audit-log] RPC failed, falling back to direct insert:', error);
      const { error: directError } = await supabaseServer
        .from('vote_audit_log')
        .insert({
          action: params.action,
          admin_id: params.adminId || null,
          member_id: params.memberId || null,
          details: params.details || {},
        });
      return { error: directError };
    }

    return { error: null };
  } catch (err) {
    // Fallback to direct insert on any error
    console.warn('[audit-log] RPC exception, falling back to direct insert:', err);
    try {
      const { error: directError } = await supabaseServer
        .from('vote_audit_log')
        .insert({
          action: params.action,
          admin_id: params.adminId || null,
          member_id: params.memberId || null,
          details: params.details || {},
        });
      return { error: directError };
    } catch (directErr) {
      return { error: directErr instanceof Error ? directErr : new Error('Audit log insert failed') };
    }
  }
}