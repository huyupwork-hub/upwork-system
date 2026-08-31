import { createServerClient, type CookieOptions } from '@supabase/ssr';
import { cookies } from 'next/headers';

import { readSupabaseEnv } from '@/lib/env';

/**
 * The request-scoped Supabase client. Every query in this app goes through it,
 * carrying the reviewer's own session — so PostgREST sees an ordinary
 * `authenticated` user and RLS decides what comes back. There is no privileged
 * client anywhere in this codebase, which is what makes the admin policies the
 * actual authority rather than a convention the UI agrees to follow.
 */
export function createClient() {
  const { url, anonKey } = readSupabaseEnv();
  const store = cookies();

  return createServerClient(url, anonKey, {
    cookies: {
      getAll() {
        return store.getAll();
      },
      setAll(
        toSet: { name: string; value: string; options: CookieOptions }[],
      ) {
        try {
          for (const { name, value, options } of toSet) {
            store.set(name, value, options);
          }
        } catch {
          // Server Components cannot set cookies. Refresh is handled by the
          // server actions and the middleware, so ignoring it here is safe.
        }
      },
    },
  });
}
