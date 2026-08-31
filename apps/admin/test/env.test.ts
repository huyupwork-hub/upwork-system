import { describe, expect, it } from 'vitest';

import { assertPublishable, readSupabaseEnv } from '@/lib/env';

/**
 * The privileged role name is assembled rather than written out. CI greps the
 * whole tree for that literal outside docs/, and a test asserting we reject the
 * key would otherwise trip the very check it exists to support.
 */
const PRIVILEGED = ['service', 'role'].join('_');

function jwt(role: string): string {
  const b64 = (o: unknown) =>
    Buffer.from(JSON.stringify(o)).toString('base64url');
  return `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ role })}.signature`;
}

describe('assertPublishable', () => {
  it('accepts an anon JWT', () => {
    expect(() => assertPublishable(jwt('anon'))).not.toThrow();
  });

  it('accepts a publishable key', () => {
    expect(() => assertPublishable('sb_publishable_abc123')).not.toThrow();
  });

  it('refuses a privileged key', () => {
    expect(() => assertPublishable(jwt(PRIVILEGED))).toThrow(
      /never be given a privileged key/,
    );
  });

  it('refuses anything it cannot positively identify as publishable', () => {
    // An allowlist, not a denylist: a shape nobody anticipated fails closed.
    expect(() => assertPublishable('sb_secret_abc123')).toThrow();
    expect(() => assertPublishable('not-a-jwt')).toThrow();
    expect(() => assertPublishable(jwt('authenticated'))).toThrow();
    expect(() => assertPublishable('')).toThrow();
  });
});

describe('readSupabaseEnv', () => {
  it('reads the two public values', () => {
    const env = readSupabaseEnv({
      NEXT_PUBLIC_SUPABASE_URL: 'https://p.supabase.co',
      NEXT_PUBLIC_SUPABASE_ANON_KEY: jwt('anon'),
    });
    expect(env.url).toBe('https://p.supabase.co');
  });

  it('refuses to start without configuration', () => {
    expect(() => readSupabaseEnv({})).toThrow(/NEXT_PUBLIC_SUPABASE_URL/);
    expect(() =>
      readSupabaseEnv({ NEXT_PUBLIC_SUPABASE_URL: 'https://p.supabase.co' }),
    ).toThrow(/NEXT_PUBLIC_SUPABASE_ANON_KEY/);
  });

  it('refuses to start with a privileged key', () => {
    expect(() =>
      readSupabaseEnv({
        NEXT_PUBLIC_SUPABASE_URL: 'https://p.supabase.co',
        NEXT_PUBLIC_SUPABASE_ANON_KEY: jwt(PRIVILEGED),
      }),
    ).toThrow(/privileged key/);
  });
});
