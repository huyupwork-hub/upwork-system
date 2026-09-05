import { describe, expect, it } from 'vitest';

import { reportFilename } from '@/lib/report_filename';

/**
 * These are the fixtures apps/mobile/test/report_store_test.dart pins, asserted
 * again here (the search.test.ts precedent). Two clients name one document:
 * the name the phone's share sheet offers and the name the console's download
 * saves under must be the same string, or the reviewer files a document under
 * a name the inspector never sent.
 */
describe('reportFilename — parity with the Flutter client', () => {
  it('pins site slug, date and the first eight hex of the id', () => {
    expect(
      reportFilename({
        id: 'a0000000-0000-4000-8000-000000000002',
        siteName: 'Northgate Retail Park',
        inspectionDate: '2026-08-22',
      }),
    ).toBe('fieldproof-northgate-retail-park-20260822-a0000000.pdf');
  });

  it('falls back to "inspection" when the site name has nothing to slug', () => {
    expect(
      reportFilename({
        id: 'f0e1d2c3-0000-4000-8000-000000000009',
        siteName: '???',
        inspectionDate: '2026-01-02',
      }),
    ).toBe('fieldproof-inspection-20260102-f0e1d2c3.pdf');
  });

  // Not a Dart-pinned fixture; it follows from the same two regexes and the
  // same ASCII-only class, and is here so a "friendlier" slug cannot drift in
  // on one side only.
  it('collapses, trims and lower-cases the way the Dart regexes do', () => {
    expect(
      reportFilename({
        id: 'c0ffee00-0000-4000-8000-000000000003',
        siteName: '  Harbour View — Pier 4 (East)! ',
        inspectionDate: '2026-08-20',
      }),
    ).toBe('fieldproof-harbour-view-pier-4-east-20260820-c0ffee00.pdf');
    expect(
      reportFilename({
        id: 'c0ffee00-0000-4000-8000-000000000003',
        siteName: 'Café Nord',
        inspectionDate: '2026-08-20',
      }),
    ).toBe('fieldproof-caf-nord-20260820-c0ffee00.pdf');
  });
});
