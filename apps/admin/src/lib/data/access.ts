/**
 * Who may use the console.
 *
 * This is an authorisation gate on top of RLS, not a substitute for it. RLS
 * already refuses to hand an inspector anyone else's rows; without this gate an
 * inspector who reached /inspections would see a working console listing their
 * own submitted work, which is not what an admin console is. Both layers stay:
 * remove this and nothing leaks, remove RLS and everything does.
 */

export type Access =
  | { kind: 'signed-out' }
  | { kind: 'forbidden' }
  | { kind: 'admin'; userId: string };

export interface AccessInputs {
  userId: string | null | undefined;
  /** The caller's own profile row, or null when it could not be read. */
  profile: { role?: string | null } | null | undefined;
}

export function resolveAccess({ userId, profile }: AccessInputs): Access {
  if (!userId) return { kind: 'signed-out' };
  // A missing profile is refused rather than assumed benign: failing open here
  // would turn a transient read failure into an authorisation bypass.
  if (!profile) return { kind: 'forbidden' };
  if (profile.role !== 'admin') return { kind: 'forbidden' };
  return { kind: 'admin', userId };
}
