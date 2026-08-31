import 'package:fieldproof/src/data/models.dart';
import 'package:fieldproof/src/data/photo_workflow.dart';
import 'package:fieldproof/src/report/report_loader.dart';
import 'package:fieldproof/src/report/report_service.dart';
import 'package:fieldproof/src/ui/app.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// History and search through the widget tree.
///
/// The fake repository does not re-implement ownership — that is RLS's job, and
/// it is proven in pgTAP `090` and the hosted smoke. What these cover is the
/// screen: what is asked for, what is shown, and what happens when answers come
/// back out of order.
void main() {
  late FakeAuthRepository auth;
  late FakeProfileRepository profiles;
  late FakeInspectionsRepository inspections;
  late FakeInspectionItemsRepository items;
  late PhotoWorkflow photos;
  late FakePhotoSource source;
  late ReportService reports;

  Inspection make(
    String id, {
    required DateTime date,
    String site = 'Site',
    String? address,
    String? client,
    InspectionStatus status = InspectionStatus.draft,
  }) => Inspection(
    id: id,
    inspectorId: 'user-1',
    siteName: site,
    siteAddress: address,
    clientName: client,
    inspectionDate: date,
    status: status,
  );

  setUp(() {
    auth = FakeAuthRepository();
    profiles = FakeProfileRepository();
    inspections = FakeInspectionsRepository();
    items = FakeInspectionItemsRepository();
    photos = PhotoWorkflow(
      objects: FakeObjectStore(),
      metadata: FakePhotoMetadataStore(),
      currentUserId: () => 'user-1',
    );
    source = FakePhotoSource();
    reports = ReportService(
      loader: ReportLoader(items: items, photos: photos, profiles: profiles),
      renderer: FakeReportRenderer(),
      sharer: FakeReportSharer(),
    );
  });

  tearDown(() => auth.dispose());

  Future<void> signIn(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      FieldProofApp(
        auth: auth,
        profiles: profiles,
        inspections: inspections,
        items: items,
        photos: photos,
        source: source,
        reports: reports,
      ),
    );
    await tester.pumpAndSettle();

    final fields = find.byType(CupertinoTextField);
    await tester.enterText(fields.at(0), 'a@example.com');
    await tester.enterText(fields.at(1), 'correct-horse');
    await tester.tap(find.widgetWithText(CupertinoButton, 'Sign In'));
    await tester.pumpAndSettle();
  }

  Finder get searchField => find.byKey(const Key('inspections-search'));

  group('history', () {
    testWidgets('shows the inspector\'s own inspections, newest date first',
        (tester) async {
      inspections.rows.addAll([
        make('a', date: DateTime(2026, 8, 1), site: 'Older Site'),
        make('b', date: DateTime(2026, 8, 20), site: 'Newer Site'),
      ]);
      await signIn(tester);

      final newer = tester.getTopLeft(find.text('Newer Site'));
      final older = tester.getTopLeft(find.text('Older Site'));
      expect(newer.dy, lessThan(older.dy), reason: 'newest date first');
    });

    testWidgets('renders address, client, date and status', (tester) async {
      inspections.rows.add(
        make(
          'a',
          date: DateTime(2026, 8, 20),
          site: 'Northgate Retail Park',
          address: '4 Northgate Way',
          client: 'Cavendish Estates',
          status: InspectionStatus.submitted,
        ),
      );
      await signIn(tester);

      expect(find.text('Northgate Retail Park'), findsOneWidget);
      expect(find.textContaining('4 Northgate Way'), findsOneWidget);
      expect(find.textContaining('Cavendish Estates'), findsOneWidget);
      expect(find.textContaining('2026-08-20'), findsOneWidget);
      expect(find.text('Submitted'), findsOneWidget);
    });

    testWidgets('drafts and submitted rows both render', (tester) async {
      inspections.rows.addAll([
        make('a', date: DateTime(2026, 8, 1), site: 'A Draft'),
        make(
          'b',
          date: DateTime(2026, 8, 2),
          site: 'A Submitted',
          status: InspectionStatus.submitted,
        ),
      ]);
      await signIn(tester);

      expect(find.text('Draft'), findsOneWidget);
      expect(find.text('Submitted'), findsOneWidget);
    });

    testWidgets('an empty history invites creating one', (tester) async {
      await signIn(tester);
      expect(find.byKey(const Key('inspections-empty')), findsOneWidget);
    });
  });

  group('search', () {
    setUp(() {
      inspections.rows.addAll([
        make(
          'a',
          date: DateTime(2026, 8, 20),
          site: 'Northgate Retail Park',
          address: '4 Northgate Way, Leeds',
          client: 'Cavendish Estates',
        ),
        make(
          'b',
          date: DateTime(2026, 8, 10),
          site: 'Harbour View Apartments',
          address: '12 Dock Road, Bristol',
          client: 'Meridian Property Group',
        ),
      ]);
    });

    testWidgets('typing narrows the list', (tester) async {
      await signIn(tester);
      expect(find.text('Harbour View Apartments'), findsOneWidget);

      await tester.enterText(searchField, 'northgate');
      await tester.pumpAndSettle();

      expect(find.text('Northgate Retail Park'), findsOneWidget);
      expect(find.text('Harbour View Apartments'), findsNothing);
    });

    testWidgets('search matches the address', (tester) async {
      await signIn(tester);
      await tester.enterText(searchField, 'bristol');
      await tester.pumpAndSettle();

      expect(find.text('Harbour View Apartments'), findsOneWidget);
      expect(find.text('Northgate Retail Park'), findsNothing);
    });

    testWidgets('search matches the client', (tester) async {
      await signIn(tester);
      await tester.enterText(searchField, 'meridian');
      await tester.pumpAndSettle();

      expect(find.text('Harbour View Apartments'), findsOneWidget);
    });

    testWidgets('clearing the query restores the whole history',
        (tester) async {
      await signIn(tester);
      await tester.enterText(searchField, 'northgate');
      await tester.pumpAndSettle();
      expect(find.text('Harbour View Apartments'), findsNothing);

      await tester.enterText(searchField, '');
      await tester.pumpAndSettle();

      expect(find.text('Northgate Retail Park'), findsOneWidget);
      expect(find.text('Harbour View Apartments'), findsOneWidget);
    });

    testWidgets('no matches reads differently from no inspections',
        (tester) async {
      await signIn(tester);
      await tester.enterText(searchField, 'zzzznothing');
      await tester.pumpAndSettle();

      // Distinct keys: "you have none" points at the + button, "nothing
      // matched" points at the query. Showing the same words for both would
      // tell the user their data had vanished.
      expect(find.byKey(const Key('inspections-no-matches')), findsOneWidget);
      expect(find.byKey(const Key('inspections-empty')), findsNothing);
      expect(find.textContaining('zzzznothing'), findsWidgets);
    });

    testWidgets('a stale response cannot overwrite a newer one', (tester) async {
      // "nor" is slow, "northgate" is fast: the earlier request completes last.
      inspections.delays['nor'] = const Duration(milliseconds: 400);
      inspections.delays['northgate'] = const Duration(milliseconds: 10);

      await signIn(tester);

      await tester.enterText(searchField, 'nor');
      await tester.pump(const Duration(milliseconds: 5));
      await tester.enterText(searchField, 'northgate');

      // Let the fast one land, then the slow one.
      await tester.pump(const Duration(milliseconds: 50));
      final afterFast = find.text('Northgate Retail Park').evaluate().length;
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      expect(afterFast, 1, reason: 'the newer query resolved first');
      // Both queries match the same single row here, so the assertion that
      // matters is that the list was not rebuilt from the stale request: the
      // displayed query stays the newer one.
      expect(find.textContaining('nor"'), findsNothing);
      expect(find.text('Northgate Retail Park'), findsOneWidget);
      expect(find.text('Harbour View Apartments'), findsNothing);
    });

    testWidgets('a slow broad query cannot resurrect filtered-out rows',
        (tester) async {
      // The sharper case: the stale query matches MORE rows. If its response
      // were applied, Harbour View would reappear under the query "northgate".
      inspections.delays['h'] = const Duration(milliseconds: 400);
      inspections.delays['northgate'] = const Duration(milliseconds: 10);

      await signIn(tester);
      await tester.enterText(searchField, 'h');
      await tester.pump(const Duration(milliseconds: 5));
      await tester.enterText(searchField, 'northgate');

      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();

      expect(find.text('Northgate Retail Park'), findsOneWidget);
      expect(
        find.text('Harbour View Apartments'),
        findsNothing,
        reason: 'the stale broader result must not be applied',
      );
    });
  });
}
