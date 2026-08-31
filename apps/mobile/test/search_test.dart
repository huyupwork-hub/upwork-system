import 'package:fieldproof/src/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// The tsquery builder and the ordering contract.
///
/// Matching itself happens in Postgres against the stored `search_tsv` and its
/// GIN index — pgTAP `090` and the hosted smoke prove that. What is testable
/// here is the query the client sends and the order it asks for.
void main() {
  group('tsquery construction', () {
    test('a single word becomes a prefix term', () {
      expect(InspectionSearch.toTsQuery('north'), 'north:*');
    });

    test('several words are ANDed, each a prefix', () {
      expect(
        InspectionSearch.toTsQuery('north retail'),
        'north:* & retail:*',
      );
    });

    test('input is lowercased, so matching is case-insensitive', () {
      // `simple` lowercases what it indexes, so the query must match.
      expect(InspectionSearch.toTsQuery('NorthGate'), 'northgate:*');
    });

    test('tsquery operators in the input cannot compose an expression', () {
      // & | ! : ( ) are tsquery syntax. Passing them through would either error
      // or let the caller write their own query.
      expect(
          InspectionSearch.toTsQuery('north & retail'), 'north:* & retail:*');
      expect(InspectionSearch.toTsQuery('a | b'), 'a:* & b:*');
      expect(InspectionSearch.toTsQuery('!north'), 'north:*');
      expect(InspectionSearch.toTsQuery("o'brien"), 'o:* & brien:*');
    });

    test('punctuation and extra whitespace collapse', () {
      expect(
        InspectionSearch.toTsQuery('  4 Northgate  Way, Leeds. '),
        '4:* & northgate:* & way:* & leeds:*',
      );
    });

    test('digits are searchable', () {
      expect(InspectionSearch.toTsQuery('12 Dock'), '12:* & dock:*');
    });

    test('nothing searchable yields null, not an empty query', () {
      // The caller falls back to the full history rather than sending a query
      // that would match nothing and look broken.
      expect(InspectionSearch.toTsQuery(''), isNull);
      expect(InspectionSearch.toTsQuery('   '), isNull);
      expect(InspectionSearch.toTsQuery('!!! &&'), isNull);
    });

    test('non-ASCII letters survive', () {
      expect(InspectionSearch.toTsQuery('Café'), 'café:*');
    });
  });

  group('history ordering and search', () {
    late FakeInspectionsRepository repo;

    Inspection make(
      String id, {
      required DateTime date,
      DateTime? createdAt,
      String site = 'Site',
      String? address,
      String? client,
      InspectionStatus status = InspectionStatus.draft,
    }) =>
        Inspection(
          id: id,
          inspectorId: 'user-1',
          siteName: site,
          siteAddress: address,
          clientName: client,
          inspectionDate: date,
          status: status,
          createdAt: createdAt,
        );

    setUp(() => repo = FakeInspectionsRepository());

    test('history is inspection_date descending', () async {
      repo.rows.addAll([
        make('a', date: DateTime(2026, 8, 1)),
        make('b', date: DateTime(2026, 8, 20)),
        make('c', date: DateTime(2026, 8, 10)),
      ]);
      final rows = await repo.listMine();
      expect(rows.map((r) => r.id).toList(), ['b', 'c', 'a']);
    });

    test('created_at descending breaks a same-date tie', () async {
      repo.rows.addAll([
        make('a',
            date: DateTime(2026, 8, 1), createdAt: DateTime(2026, 8, 1, 9)),
        make('b',
            date: DateTime(2026, 8, 1), createdAt: DateTime(2026, 8, 1, 17)),
      ]);
      final rows = await repo.listMine();
      expect(rows.map((r) => r.id).toList(), ['b', 'a']);
    });

    test('id breaks a total tie, so the order is deterministic', () async {
      // Same date, no timestamps: without the final key two calls could disagree.
      repo.rows.addAll([
        make('a', date: DateTime(2026, 8, 1)),
        make('c', date: DateTime(2026, 8, 1)),
        make('b', date: DateTime(2026, 8, 1)),
      ]);
      final first = await repo.listMine();
      final second = await repo.listMine();
      expect(first.map((r) => r.id).toList(), ['c', 'b', 'a']);
      expect(second.map((r) => r.id).toList(), first.map((r) => r.id).toList());
    });

    test('search matches the site name', () async {
      repo.rows.addAll([
        make('a', date: DateTime(2026, 8, 1), site: 'Northgate Retail Park'),
        make('b', date: DateTime(2026, 8, 2), site: 'Harbour View'),
      ]);
      final rows = await repo.searchMine('northgate');
      expect(rows.map((r) => r.id).toList(), ['a']);
    });

    test('search matches the address', () async {
      repo.rows.addAll([
        make('a', date: DateTime(2026, 8, 1), address: '12 Dock Road'),
        make('b', date: DateTime(2026, 8, 2), address: '4 Mill Lane'),
      ]);
      expect((await repo.searchMine('dock')).map((r) => r.id), ['a']);
    });

    test('search matches the client', () async {
      repo.rows.addAll([
        make('a', date: DateTime(2026, 8, 1), client: 'Meridian Property'),
        make('b', date: DateTime(2026, 8, 2), client: 'Cavendish Estates'),
      ]);
      expect((await repo.searchMine('cavendish')).map((r) => r.id), ['b']);
    });

    test('search is case-insensitive', () async {
      repo.rows.add(
        make('a', date: DateTime(2026, 8, 1), site: 'Northgate Retail Park'),
      );
      expect(await repo.searchMine('NORTHGATE'), hasLength(1));
    });

    test('results keep the same ordering as history', () async {
      repo.rows.addAll([
        make('a', date: DateTime(2026, 8, 1), site: 'Northgate One'),
        make('b', date: DateTime(2026, 8, 20), site: 'Northgate Two'),
      ]);
      expect((await repo.searchMine('northgate')).map((r) => r.id), ['b', 'a']);
    });

    test('a blank query returns the full history', () async {
      repo.rows.addAll([
        make('a', date: DateTime(2026, 8, 1)),
        make('b', date: DateTime(2026, 8, 2)),
      ]);
      expect(await repo.searchMine('   '), hasLength(2));
    });

    test('drafts and submitted inspections are both searchable', () async {
      repo.rows.addAll([
        make(
          'a',
          date: DateTime(2026, 8, 1),
          site: 'Northgate Draft',
        ),
        make(
          'b',
          date: DateTime(2026, 8, 2),
          site: 'Northgate Submitted',
          status: InspectionStatus.submitted,
        ),
      ]);
      final rows = await repo.searchMine('northgate');
      expect(rows, hasLength(2));
      expect(
        rows.map((r) => r.status).toSet(),
        {InspectionStatus.draft, InspectionStatus.submitted},
      );
    });
  });
}
