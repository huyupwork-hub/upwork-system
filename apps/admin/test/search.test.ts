import { describe, expect, it } from 'vitest';

import { toTsQuery } from '@/lib/data/search';

/**
 * These are the cases apps/mobile/test/search_test.dart pins, asserted again
 * here. The point is not coverage for its own sake: two clients query one
 * stored tsvector, and if their query construction diverged the same words
 * would find different rows depending on which app you asked.
 */
describe('toTsQuery — parity with the Flutter client', () => {
  it('makes a single word a prefix term', () => {
    expect(toTsQuery('north')).toBe('north:*');
  });

  it('ANDs several words, each a prefix', () => {
    expect(toTsQuery('north retail')).toBe('north:* & retail:*');
  });

  it('lowercases, matching the simple configuration', () => {
    expect(toTsQuery('NorthGate')).toBe('northgate:*');
  });

  it('strips tsquery operators so input cannot compose an expression', () => {
    expect(toTsQuery('north & retail')).toBe('north:* & retail:*');
    expect(toTsQuery('a | b')).toBe('a:* & b:*');
    expect(toTsQuery('!north')).toBe('north:*');
    expect(toTsQuery("o'brien")).toBe('o:* & brien:*');
  });

  it('collapses punctuation and whitespace', () => {
    expect(toTsQuery('  4 Northgate  Way, Leeds. ')).toBe(
      '4:* & northgate:* & way:* & leeds:*',
    );
  });

  it('keeps digits searchable', () => {
    expect(toTsQuery('12 Dock')).toBe('12:* & dock:*');
  });

  it('returns null when nothing is searchable', () => {
    expect(toTsQuery('')).toBeNull();
    expect(toTsQuery('   ')).toBeNull();
    expect(toTsQuery('!!! &&')).toBeNull();
  });

  it('keeps non-ASCII letters', () => {
    expect(toTsQuery('Café')).toBe('café:*');
  });
});
