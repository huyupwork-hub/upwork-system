import { createBrowserClient } from '@supabase/ssr';

import { readSupabaseEnv } from '@/lib/env';

/**
 * Only needed where a component genuinely runs in the browser. The console is
 * server-rendered throughout, so this exists for parity of configuration rather
 * than because the UI depends on it.
 */
export function createClient() {
  const { url, anonKey } = readSupabaseEnv();
  return createBrowserClient(url, anonKey);
}
