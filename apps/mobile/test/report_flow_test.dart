import 'package:fieldproof/src/data/models.dart';
import 'package:fieldproof/src/data/photo_workflow.dart';
import 'package:fieldproof/src/report/report_loader.dart';
import 'package:fieldproof/src/report/report_service.dart';
import 'package:fieldproof/src/ui/app.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// The Generate Report flow, end to end through the widget tree.
///
/// The renderer and the share sheet are both faked, so no platform channel is
/// loaded — `printing` never runs here. The real renderer is exercised directly
/// in `report_renderer_test.dart`.
void main() {
  late FakeAuthRepository auth;
  late FakeProfileRepository profiles;
  late FakeInspectionsRepository inspections;
  late FakeInspectionItemsRepository items;
  late FakeObjectStore objectStore;
  late FakePhotoMetadataStore photoMeta;
  late PhotoWorkflow photos;
  late FakePhotoSource source;
  late FakeReportRenderer reportRenderer;
  late FakeReportSharer reportSharer;
  late ReportService reports;

  final submitted = Inspection(
    id: 'a0000000-0000-4000-8000-000000000002',
    inspectorId: 'user-1',
    siteName: 'Northgate Retail Park',
    inspectionDate: DateTime(2026, 8, 22),
    status: InspectionStatus.submitted,
    submittedAt: DateTime.utc(2026, 8, 22, 14),
  );

  final draft = Inspection(
    id: 'a0000000-0000-4000-8000-000000000001',
    inspectorId: 'user-1',
    siteName: 'Harbour View Apartments',
    inspectionDate: DateTime(2026, 8, 20),
    status: InspectionStatus.draft,
  );

  setUp(() {
    auth = FakeAuthRepository();
    profiles = FakeProfileRepository();
    inspections = FakeInspectionsRepository();
    items = FakeInspectionItemsRepository();
    objectStore = FakeObjectStore();
    photoMeta = FakePhotoMetadataStore();
    photos = PhotoWorkflow(
      objects: objectStore,
      metadata: photoMeta,
      currentUserId: () => 'user-1',
    );
    source = FakePhotoSource();
    reportRenderer = FakeReportRenderer();
    reportSharer = FakeReportSharer();
    reports = ReportService(
      loader: ReportLoader(items: items, photos: photos, profiles: profiles),
      renderer: reportRenderer,
      sharer: reportSharer,
    );
  });

  tearDown(() => auth.dispose());

  Future<void> open(WidgetTester tester, Inspection inspection) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    inspections.rows
      ..clear()
      ..add(inspection);

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

    await tester.tap(find.text(inspection.siteName));
    await tester.pumpAndSettle();
  }

  group('eligibility', () {
    testWidgets('a submitted inspection exposes the report action',
        (tester) async {
      await open(tester, submitted);
      expect(find.byKey(const Key('generate-report-button')), findsOneWidget);
    });

    testWidgets('a draft has no report action at all', (tester) async {
      await open(tester, draft);

      // Absent, not disabled: an affordance that can never succeed is worse
      // than its absence (D21).
      expect(find.byKey(const Key('generate-report-button')), findsNothing);
      // The draft keeps its add-item action instead.
      expect(find.byKey(const Key('add-item-button')), findsOneWidget);
    });
  });

  group('generating', () {
    testWidgets('renders and shares, with a filename derived from the record',
        (tester) async {
      items.rows.add(
        InspectionItem(
          id: 'item-1',
          inspectionId: submitted.id,
          sortOrder: 0,
          title: 'Exposed wiring',
          severity: ItemSeverity.critical,
          status: ItemStatus.open,
        ),
      );

      await open(tester, submitted);
      await tester.tap(find.byKey(const Key('generate-report-button')));
      await tester.pumpAndSettle();

      expect(reportRenderer.rendered, hasLength(1));
      expect(reportSharer.shared, hasLength(1));
      expect(
        reportSharer.filenames.single,
        startsWith('fieldproof-northgate-retail-park-20260822-'),
      );
    });

    testWidgets('the rendered snapshot carries the inspection and its items',
        (tester) async {
      items.rows.addAll([
        InspectionItem(
          id: 'item-1',
          inspectionId: submitted.id,
          sortOrder: 0,
          title: 'First',
          severity: ItemSeverity.high,
          status: ItemStatus.open,
        ),
        InspectionItem(
          id: 'item-2',
          inspectionId: submitted.id,
          sortOrder: 1,
          title: 'Second',
          severity: ItemSeverity.low,
          status: ItemStatus.resolved,
        ),
      ]);

      await open(tester, submitted);
      await tester.tap(find.byKey(const Key('generate-report-button')));
      await tester.pumpAndSettle();

      final snap = reportRenderer.rendered.single;
      expect(snap.inspection.id, submitted.id);
      expect(snap.items.map((i) => i.item.title).toList(), ['First', 'Second']);
      expect(snap.summary.open, 1);
      expect(snap.summary.resolved, 1);
    });

    testWidgets('a render failure is surfaced and nothing is shared',
        (tester) async {
      reportRenderer.failWith = Exception('renderer blew up');

      await open(tester, submitted);
      await tester.tap(find.byKey(const Key('generate-report-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('report-error')), findsOneWidget);
      expect(reportSharer.shared, isEmpty);
    });

    testWidgets('a share failure is surfaced', (tester) async {
      reportSharer.failWith = Exception('share sheet unavailable');

      await open(tester, submitted);
      await tester.tap(find.byKey(const Key('generate-report-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('report-error')), findsOneWidget);
    });

    testWidgets('the action returns to idle after a failure', (tester) async {
      reportRenderer.failWith = Exception('nope');

      await open(tester, submitted);
      await tester.tap(find.byKey(const Key('generate-report-button')));
      await tester.pumpAndSettle();

      // Still tappable: a one-off failure must not strand the screen.
      expect(find.byKey(const Key('generate-report-button')), findsOneWidget);
      expect(find.byKey(const Key('report-progress')), findsNothing);
    });

    testWidgets('a missing profile fails the report without sharing anything',
        (tester) async {
      profiles.throwMissing = true;

      await open(tester, submitted);
      // The detail screen surfaces its own load error; the report action is
      // still present, and pressing it must not share a half-built document.
      await tester.tap(find.byKey(const Key('generate-report-button')));
      await tester.pumpAndSettle();

      expect(reportSharer.shared, isEmpty);
      expect(find.byKey(const Key('report-error')), findsOneWidget);
    });
  });
}
