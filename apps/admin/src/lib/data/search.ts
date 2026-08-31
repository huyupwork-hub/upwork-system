/**
 * The same tsquery construction the Flutter client uses
 * (`InspectionSearch.toTsQuery` in apps/mobile/lib/src/data/models.dart).
 *
 * Deliberately a mirror rather than a second design: both clients query the one
 * stored `search_tsv` column and its existing GIN index, so if the two built
 * different queries the same words would find different rows depending on which
 * app you asked. `test/search.test.ts` pins the cases the Dart tests pin.
 *
 * User input never reaches Postgres as tsquery syntax. Terms are extracted as
 * runs of letters and digits, so `&`, `|`, `!`, `:` and parentheses cannot
 * compose an expression of the caller's own.
 */
export function toTsQuery(raw: string): string | null {
  const terms = raw.toLowerCase().match(/[\p{L}\p{N}]+/gu);
  if (!terms || terms.length === 0) return null;
  return terms.map((t) => `${t}:*`).join(' & ');
}
