import { redirect } from 'next/navigation';

import { createClient } from '@/lib/supabase/server';
import { resolveAccess, type Access } from '@/lib/data/access';

/**
 * Resolves the caller once per request: session, then their own profile row.
 *
 * The profile read goes through the same authenticated client as everything
 * else, so `profiles_select_self` is what returns it. There is no privileged
 * lookup and no role claim trusted from the token — D4 keeps `role` out of the
 * client's reach, and reading it from the table is what makes that matter.
 */
export async function currentAccess(): Promise<Access> {
  const supabase = createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) return resolveAccess({ userId: null, profile: null });

  const { data: profile } = await supabase
    .from('profiles')
    .select('role, full_name')
    .eq('id', user.id)
    .maybeSingle();

  return resolveAccess({ userId: user.id, profile });
}

/** Guard for every page in the console. Sends non-admins away rather than rendering a shell they cannot use. */
export async function requireAdmin(): Promise<{ userId: string }> {
  const access = await currentAccess();
  if (access.kind === 'signed-out') redirect('/sign-in');
  if (access.kind === 'forbidden') redirect('/no-access');
  return { userId: access.userId };
}

export async function currentDisplayName(): Promise<string | null> {
  const supabase = createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return null;

  const { data } = await supabase
    .from('profiles')
    .select('full_name')
    .eq('id', user.id)
    .maybeSingle();

  return (data?.full_name as string | undefined) ?? user.email ?? null;
}
