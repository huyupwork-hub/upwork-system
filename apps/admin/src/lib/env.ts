/**
 * Browser-visible Supabase configuration.
 *
 * Both values here are published into the client bundle by design and neither
 * confers privilege: the anon/publishable key is only ever as powerful as the
 * RLS policies allow. A privileged key would break that, so `assertPublishable`
 * refuses one at startup rather than trusting review to catch it. The check is
 * an allowlist (the key must *be* anon/publishable) rather than a denylist,
 * because a denylist only rejects the shapes you thought of.
 */

export interface SupabaseEnv {
  url: string;
  anonKey: string;
}

function decodeJwtRole(key: string): string | null {
  const parts = key.split('.');
  if (parts.length !== 3) return null;
  try {
    const json = Buffer.from(parts[1], 'base64').toString('utf8');
    const payload = JSON.parse(json) as { role?: unknown };
    return typeof payload.role === 'string' ? payload.role : null;
  } catch {
    return null;
  }
}

/**
 * Throws unless the key is one of the two publishable shapes: a legacy anon JWT
 * (`role: "anon"`) or a `sb_publishable_` key. Anything else — including a
 * privileged key — fails closed.
 */
export function assertPublishable(key: string): void {
  if (key.startsWith('sb_publishable_')) return;

  const role = decodeJwtRole(key);
  if (role === 'anon') return;

  throw new Error(
    'NEXT_PUBLIC_SUPABASE_ANON_KEY is not a publishable key. The admin app must ' +
      'never be given a privileged key: it runs in the browser, and RLS is the ' +
      'only thing standing between a reviewer and every inspector’s drafts.',
  );
}

export function readSupabaseEnv(
  source: Record<string, string | undefined> = process.env,
): SupabaseEnv {
  const url = source.NEXT_PUBLIC_SUPABASE_URL;
  const anonKey = source.NEXT_PUBLIC_SUPABASE_ANON_KEY;

  if (!url) throw new Error('NEXT_PUBLIC_SUPABASE_URL is not set.');
  if (!anonKey) throw new Error('NEXT_PUBLIC_SUPABASE_ANON_KEY is not set.');

  assertPublishable(anonKey);
  return { url, anonKey };
}
