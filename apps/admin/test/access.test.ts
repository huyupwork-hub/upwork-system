import { describe, expect, it } from 'vitest';

import { resolveAccess } from '@/lib/data/access';

/**
 * The authorisation gate. RLS is the authority over *data*; this decides who
 * gets a console at all. Both matter, and neither is asserted by the other.
 */
describe('resolveAccess', () => {
  it('sends an unauthenticated visitor to sign in', () => {
    expect(resolveAccess({ userId: null, profile: null })).toEqual({
      kind: 'signed-out',
    });
    expect(resolveAccess({ userId: undefined, profile: undefined })).toEqual({
      kind: 'signed-out',
    });
  });

  it('refuses an authenticated inspector', () => {
    expect(
      resolveAccess({ userId: 'u1', profile: { role: 'inspector' } }),
    ).toEqual({ kind: 'forbidden' });
  });

  it('admits an admin', () => {
    expect(resolveAccess({ userId: 'u1', profile: { role: 'admin' } })).toEqual({
      kind: 'admin',
      userId: 'u1',
    });
  });

  it('fails closed when the profile cannot be read', () => {
    // A transient read failure must not become an authorisation bypass.
    expect(resolveAccess({ userId: 'u1', profile: null })).toEqual({
      kind: 'forbidden',
    });
  });

  it('fails closed on an unknown or absent role', () => {
    expect(resolveAccess({ userId: 'u1', profile: {} })).toEqual({
      kind: 'forbidden',
    });
    expect(
      resolveAccess({ userId: 'u1', profile: { role: 'superuser' } }),
    ).toEqual({ kind: 'forbidden' });
    expect(resolveAccess({ userId: 'u1', profile: { role: null } })).toEqual({
      kind: 'forbidden',
    });
  });

  it('is not satisfied by a role that merely contains "admin"', () => {
    expect(
      resolveAccess({ userId: 'u1', profile: { role: 'not-admin' } }),
    ).toEqual({ kind: 'forbidden' });
    expect(
      resolveAccess({ userId: 'u1', profile: { role: 'Admin' } }),
    ).toEqual({ kind: 'forbidden' });
  });
});
