import type { SubmittedInspection } from './data/types';

/**
 * The same name the Flutter client gives the report (`reportFilenameFor` in
 * apps/mobile/lib/src/report/report_sharer.dart).
 *
 * A mirror, not a second design, for the toTsQuery reason (data/search.ts):
 * the inspector's share sheet and the reviewer's download are one document,
 * and it should be called one thing wherever it lands. `test/report_filename.test.ts`
 * pins the fixtures report_store_test.dart pins.
 *
 * `fieldproof-<site slug>-<yyyymmdd>-<first eight hex of the id>.pdf`. The slug
 * keeps ASCII letters and digits only: every other run becomes one dash, the
 * ends are trimmed, the result lower-cased, and a name with nothing left
 * becomes `inspection`. The date is the inspection's own date, not the
 * submission timestamp. PostgREST serialises the `date` column as
 * `yyyy-mm-dd`; the Dart side parses that same string and re-emits year, month
 * and day, so the eight digits agree without either side formatting a clock.
 */
export function reportFilename(
  inspection: Pick<SubmittedInspection, 'id' | 'siteName' | 'inspectionDate'>,
): string {
  const site = inspection.siteName
    .replace(/[^A-Za-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .toLowerCase();
  const stamp = inspection.inspectionDate.slice(0, 10).replace(/-/g, '');
  const shortId = inspection.id.replace(/-/g, '').slice(0, 8);
  return `fieldproof-${site || 'inspection'}-${stamp}-${shortId}.pdf`;
}
