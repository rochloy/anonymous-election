import { createClient, SupabaseClient } from '@supabase/supabase-js';

// Lazy singleton server client using the service-role key.
// NEVER import this into a client component — it would leak the service key.
// Uses a Proxy so `supabaseServer.from(...)` works exactly like a real client,
// but the client is only constructed on first property access (not at import time).
// This prevents `npm run build` from failing when env vars are absent.
let _client: SupabaseClient | null = null;

function getClient(): SupabaseClient {
  if (!_client) {
    _client = createClient(
      process.env.NEXT_PUBLIC_SUPABASE_URL!,
      process.env.SUPABASE_SERVICE_ROLE_KEY!,
      { auth: { persistSession: false } }
    );
  }
  return _client;
}

export const supabaseServer = new Proxy({} as SupabaseClient, {
  get(_target, prop) {
    const client = getClient();
    const value = (client as any)[prop];
    return typeof value === 'function' ? value.bind(client) : value;
  },
});
