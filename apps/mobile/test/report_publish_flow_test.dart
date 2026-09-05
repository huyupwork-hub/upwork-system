import 'dart:io';
import 'dart:typed_data';

import 'package:fieldproof/src/data/models.dart';
import 'package:fieldproof/src/data/photo_workflow.dart';
import 'package:fieldproof/src/data/repositories.dart';
import 'package:fieldproof/src/report/report_loader.dart';
import 'package:fieldproof/src/report/report_service.dart';
import 'package:fieldproof/src/ui/app.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'fakes.dart';

/// The stored report, through the widget tree (D21 amended, D31).
///
/// What these prove is the client contract around the upload: that it runs
/// only once the submission is permanent, that its failure is reported under
/// its own keys and never as a submit failure, that the state on screen is read
/// from the bucket rather than remembered, and that "could not check" is never
/// shown as "not uploaded" (D28). The bucket's policies are pgTAP `110`'s and
/// the hosted smoke's to prove; the fake store enforces none of them.
void main() {
  late FakeAuthRepository auth;
  late FakeProfileRepository profiles;
  late FakeInspectionsRepository inspections;
  late FakeInspectionItemsRepository items;
  late PhotoWorkflow photos;
  late FakePhotoSource source;
  late FakeReportStore store;
  late FakeReportSharer sharer;
  late ReportService reports;

  /// The one name the INSERT policy admits, for the session's own uid.
  const path = 'user-1/insp-1/report.pdf';

  final pdf = Uint8List.fromList('%PDF-1.7 stored'.codeUnits);

  Inspection make(
    String id,
    String site,
    InspectionStatus status, {
    DateTime? date,
  }) =>
      Inspection(
        id: id,
        inspectorId: 'user-1',
        siteName: site,
        clientName: 'Meridian Property Group',
        inspectionDate: date ?? DateTime(2026, 8, 20),
        status: status,
        submittedAt:
            status == InspectionStatus.submitted ? DateTime(2026, 8, 22) : null,
      );

  Inspection draft() =>
      make('insp-1', 'Harbour View Apartments', InspectionStatus.draft);

  Inspection submitted() =>
      make('insp-1', 'Harbour View Apartments', InspectionStatus.submitted);

  void build(List<Inspection> initial) {
    auth = FakeAuthRepository();
    profiles = FakeProfileRepository();
    inspections = FakeInspectionsRepository(initial: initial);
    items = FakeInspectionItemsRepository();
    photos = PhotoWorkflow(
      objects: FakeObjectStore(),
      metadata: FakePhotoMetadataStore(),
      currentUserId: () => 'user-1',
    );
    source = FakePhotoSource();
    store = FakeReportStore();
    sharer = FakeReportSharer();
    reports = ReportService(
      loader: ReportLoader(items: items, photos: photos, profiles: profiles),
      renderer: FakeReportRenderer(),
      sharer: sharer,
      store: store,
      currentUserId: () => 'user-1',
    );
  }

  setUp(() => build([draft()]));
  tearDown(() => auth.dispose());

  Future<void> pumpApp(WidgetTester tester) async {
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
  }

  Future<void> signIn(WidgetTester tester) async {
    final fields = find.byType(CupertinoTextField);
    await tester.enterText(fields.at(0), 'a@example.com');
    await tester.enterText(fields.at(1), 'correct-horse');
    await tester.tap(find.widgetWithText(CupertinoButton, 'Sign In'));
    await tester.pumpAndSettle();
  }

  Future<void> openDetail(WidgetTester tester, String site) async {
    await pumpApp(tester);
    await signIn(tester);
    await tester.tap(find.text(site));
    await tester.pumpAndSettle();
  }

  Future<void> confirmSubmit(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('submit-inspection-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('submit-confirm-button')));
    await tester.pumpAndSettle();
  }

  String status(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('detail-status'))).data!;

  String textOf(WidgetTester tester, String key) =>
      tester.widget<Text>(find.byKey(Key(key))).data!;

  Finder key(String name) => find.byKey(Key(name));

  group('submitting', () {
    testWidgets(
        'uploads one rendering at the pinned name once the record is permanent',
        (tester) async {
      await openDetail(tester, 'Harbour View Apartments');
      await confirmSubmit(tester);

      expect(inspections.submitted, ['insp-1']);
      expect(status(tester), 'Submitted');
      expect(store.objects.keys, [path]);
      expect(key('report-published'), findsOneWidget);
      expect(key('publish-report-button'), findsNothing);
    });

    testWidgets('an upload failure is not a submit failure', (tester) async {
      store.failPut = const SocketException('no route to host');

      await openDetail(tester, 'Harbour View Apartments');
      await confirmSubmit(tester);

      // The submission stands, and the screen says so everywhere it can:
      // status, notice, the repository's own record — and the error copy
      // itself opens with it.
      expect(inspections.submitted, ['insp-1']);
      expect(status(tester), 'Submitted');
      expect(key('read-only-notice'), findsOneWidget);
      expect(key('submit-error'), findsNothing);
      expect(key('submit-inspection-button'), findsNothing);

      expect(key('report-publish-error'), findsOneWidget);
      expect(
        textOf(tester, 'report-publish-error'),
        startsWith('The inspection was submitted.'),
      );
      expect(key('report-unpublished'), findsOneWidget);
      // A failure in transit is a doubt, not a read: the bytes may have landed
      // after the response was lost, and the row does not claim otherwise.
      expect(
        textOf(tester, 'report-unpublished'),
        'The PDF report may not have been uploaded for reviewers.',
      );
      expect(key('publish-report-button'), findsOneWidget);
      expect(key('report-published'), findsNothing);
      expect(store.objects, isEmpty);
    });

    testWidgets('a refusal is stated as an absence, not a doubt',
        (tester) async {
      store.failPut = const StorageException(
        'new row violates row-level security policy',
        statusCode: '403',
      );

      await openDetail(tester, 'Harbour View Apartments');
      await confirmSubmit(tester);

      // The server answered, so the phone knows nothing landed.
      expect(status(tester), 'Submitted');
      expect(
        textOf(tester, 'report-unpublished'),
        'The PDF report has not been uploaded for reviewers.',
      );
      expect(textOf(tester, 'report-publish-error'), contains('row-level'));
      expect(key('publish-report-button'), findsOneWidget);
    });

    testWidgets('the retry uploads what the first attempt could not',
        (tester) async {
      store.failPut = const SocketException('no route to host');
      await openDetail(tester, 'Harbour View Apartments');
      await confirmSubmit(tester);
      expect(key('publish-report-button'), findsOneWidget);

      store.failPut = null;
      await tester.tap(key('publish-report-button'));
      await tester.pumpAndSettle();

      expect(store.puts, hasLength(2));
      expect(store.objects.keys, [path]);
      expect(key('report-published'), findsOneWidget);
      expect(key('report-publish-error'), findsNothing);
      expect(key('publish-report-button'), findsNothing);
      // The record was submitted exactly once; the retry touched the bucket
      // only.
      expect(inspections.submitted, ['insp-1']);
    });

    testWidgets('a refused submit never reaches the bucket', (tester) async {
      inspections.submitFailsWith =
          const NotPermittedException('submit this inspection');

      await openDetail(tester, 'Harbour View Apartments');
      await confirmSubmit(tester);

      expect(key('submit-error'), findsOneWidget);
      expect(status(tester), 'Draft');
      expect(store.puts, isEmpty);
      expect(key('report-published'), findsNothing);
      expect(key('report-unpublished'), findsNothing);
      expect(key('report-state-unknown'), findsNothing);
    });
  });

  group('opening a submitted inspection', () {
    testWidgets(
        'with no stored report offers the upload, and the tap stores it',
        (tester) async {
      build([submitted()]);
      await openDetail(tester, 'Harbour View Apartments');

      // The retry for a phone killed between submit and upload, and the
      // backfill for a record submitted from a build that never uploaded.
      expect(key('report-unpublished'), findsOneWidget);
      expect(key('publish-report-button'), findsOneWidget);
      expect(key('report-published'), findsNothing);
      expect(store.puts, isEmpty);

      await tester.tap(key('publish-report-button'));
      await tester.pumpAndSettle();

      expect(store.objects.keys, [path]);
      expect(key('report-published'), findsOneWidget);
      expect(key('publish-report-button'), findsNothing);
      // Opening the record submitted nothing.
      expect(inspections.submitted, isEmpty);
    });

    testWidgets('with a stored report shows it and uploads nothing',
        (tester) async {
      build([submitted()]);
      store.objects[path] = pdf;
      await openDetail(tester, 'Harbour View Apartments');

      expect(key('report-published'), findsOneWidget);
      expect(key('report-unpublished'), findsNothing);
      expect(key('publish-report-button'), findsNothing);
      // Read from the bucket, not re-uploaded: nothing was asked of the
      // store beyond the listing.
      expect(store.puts, isEmpty);
    });

    testWidgets('a draft shows no report state at all', (tester) async {
      await openDetail(tester, 'Harbour View Apartments');

      expect(status(tester), 'Draft');
      expect(key('report-published'), findsNothing);
      expect(key('report-unpublished'), findsNothing);
      expect(key('report-state-unknown'), findsNothing);
      expect(key('publish-report-button'), findsNothing);
      expect(store.puts, isEmpty);
    });

    testWidgets(
        'a bucket that cannot be read is "could not check", and the findings '
        'still render', (tester) async {
      build([submitted()]);
      store.failPublished = const SocketException('no route to host');
      items.rows.add(
        const InspectionItem(
          id: 'item-1',
          inspectionId: 'insp-1',
          sortOrder: 0,
          title: 'Exposed wiring',
          severity: ItemSeverity.critical,
          status: ItemStatus.open,
        ),
      );

      await openDetail(tester, 'Harbour View Apartments');

      // The record is the content and it is on screen; the bucket's silence
      // is stated as its own thing, never as "not uploaded" (D28).
      expect(find.text('Exposed wiring'), findsOneWidget);
      expect(key('report-state-unknown'), findsOneWidget);
      expect(key('report-check-retry'), findsOneWidget);
      expect(key('report-unpublished'), findsNothing);
      expect(key('publish-report-button'), findsNothing);
      expect(key('report-published'), findsNothing);

      // The retry asks the bucket again rather than remembering anything.
      store.failPublished = null;
      await tester.tap(key('report-check-retry'));
      await tester.pumpAndSettle();

      expect(key('report-state-unknown'), findsNothing);
      expect(key('report-unpublished'), findsOneWidget);
      expect(key('publish-report-button'), findsOneWidget);
    });

    testWidgets('sharing the PDF never touches the store', (tester) async {
      // A real-shaped id: the share sheet's filename takes eight hex of it,
      // and a share that failed before the sheet would prove nothing here.
      build([
        make(
          'a0000000-0000-4000-8000-000000000001',
          'Harbour View Apartments',
          InspectionStatus.submitted,
        ),
      ]);
      await openDetail(tester, 'Harbour View Apartments');

      await tester.tap(key('generate-report-button'));
      await tester.pumpAndSettle();

      // The share happened — the sheet was handed the bytes, and no error
      // stood in for it — and the store saw none of it.
      expect(key('report-error'), findsNothing);
      expect(sharer.shared, hasLength(1));
      expect(store.puts, isEmpty);
      expect(store.objects, isEmpty);
      // The share does not change what the screen knows about the bucket.
      expect(key('report-unpublished'), findsOneWidget);
    });
  });

  group('the Reports tab', () {
    const harbour = 'user-1/insp-1/report.pdf';
    const northgate = 'user-1/insp-2/report.pdf';

    // Newest first, the order the list shows them: Northgate, then Harbour.
    List<Inspection> rows() => [
          make(
            'insp-1',
            'Harbour View Apartments',
            InspectionStatus.submitted,
            date: DateTime(2026, 8, 20),
          ),
          make(
            'insp-2',
            'Northgate Retail Park',
            InspectionStatus.submitted,
            date: DateTime(2026, 8, 22),
          ),
          make('insp-3', 'Dockside Warehouse', InspectionStatus.draft),
        ];

    setUp(() => build(rows()));

    Future<void> openReports(WidgetTester tester) async {
      await pumpApp(tester);
      if (auth.currentUserId == null) await signIn(tester);
      await tester.tap(find.text('Reports').first);
      await tester.pumpAndSettle();
    }

    testWidgets("shows each submitted row's state from the store",
        (tester) async {
      store.objects[northgate] = pdf;
      await openReports(tester);

      expect(key('report-uploaded-insp-2'), findsOneWidget);
      expect(key('report-upload-insp-2'), findsNothing);
      expect(key('report-upload-insp-1'), findsOneWidget);
      expect(key('report-uploaded-insp-1'), findsNothing);
      // A draft has no report to have uploaded.
      expect(key('report-uploaded-insp-3'), findsNothing);
      expect(key('report-upload-insp-3'), findsNothing);
      expect(key('report-state-unknown'), findsNothing);

      expect(key('upload-missing-reports-button'), findsOneWidget);
      expect(find.text('Upload 1 missing report'), findsOneWidget);
      // Looking is not uploading (D25).
      expect(store.puts, isEmpty);
    });

    testWidgets('offers no catch-up when nothing is missing', (tester) async {
      store.objects[harbour] = pdf;
      store.objects[northgate] = pdf;
      await openReports(tester);

      expect(key('report-uploaded-insp-1'), findsOneWidget);
      expect(key('report-uploaded-insp-2'), findsOneWidget);
      expect(key('upload-missing-reports-button'), findsNothing);
    });

    testWidgets('the catch-up uploads the missing ones on a tap and names them',
        (tester) async {
      await openReports(tester);
      expect(find.text('Upload 2 missing reports'), findsOneWidget);

      await tester.tap(key('upload-missing-reports-button'));
      await tester.pumpAndSettle();

      expect(store.objects.keys.toSet(), {harbour, northgate});
      expect(store.puts, hasLength(2));
      expect(key('reports-publish-summary'), findsOneWidget);
      final summary = textOf(tester, 'reports-publish-summary');
      expect(summary, startsWith('Uploaded '));
      expect(summary, contains('Northgate Retail Park'));
      expect(summary, contains('Harbour View Apartments'));
      expect(summary, isNot(contains('Skipped')));
      expect(summary, isNot(contains('Failed')));

      // The rows say what the bucket says now, and there is nothing left to
      // catch up.
      expect(key('report-uploaded-insp-1'), findsOneWidget);
      expect(key('report-uploaded-insp-2'), findsOneWidget);
      expect(key('report-upload-insp-1'), findsNothing);
      expect(key('report-upload-insp-2'), findsNothing);
      expect(key('upload-missing-reports-button'), findsNothing);
    });

    testWidgets("a row's own Upload publishes that one only", (tester) async {
      await openReports(tester);

      await tester.tap(key('report-upload-insp-1'));
      await tester.pumpAndSettle();

      expect(store.objects.keys, [harbour]);
      expect(key('report-uploaded-insp-1'), findsOneWidget);
      expect(key('report-upload-insp-2'), findsOneWidget);
      expect(find.text('Upload 1 missing report'), findsOneWidget);
      expect(
        textOf(tester, 'reports-publish-summary'),
        'Uploaded Harbour View Apartments',
      );
    });

    testWidgets('the catch-up stops at the first sign of no signal',
        (tester) async {
      store.failPut = const SocketException('no route to host');
      await openReports(tester);

      await tester.tap(key('upload-missing-reports-button'));
      await tester.pumpAndSettle();

      // One attempt, then nothing: the second would meet the same silence.
      expect(store.puts, hasLength(1));
      expect(store.objects, isEmpty);
      final summary = textOf(tester, 'reports-publish-summary');
      expect(summary, contains('Skipped Harbour View Apartments (no signal)'));
      expect(summary, contains('Failed Northgate Retail Park:'));
      expect(summary, contains('could not be reached'));
      expect(summary, isNot(contains('Uploaded')));

      // Both still offered: the state was re-read from the bucket, which
      // holds neither.
      expect(key('report-upload-insp-1'), findsOneWidget);
      expect(key('report-upload-insp-2'), findsOneWidget);
      expect(find.text('Upload 2 missing reports'), findsOneWidget);
    });

    testWidgets('the catch-up continues past a refusal and reports it',
        (tester) async {
      store.failPut = const StorageException(
        'The object exceeded the maximum allowed size',
        statusCode: '413',
      );
      await openReports(tester);

      await tester.tap(key('upload-missing-reports-button'));
      await tester.pumpAndSettle();

      // A refusal is about one inspection; the next still gets its turn.
      expect(store.puts, hasLength(2));
      final summary = textOf(tester, 'reports-publish-summary');
      expect(summary, startsWith('Failed Northgate Retail Park, Harbour View'));
      expect(summary, contains('maximum allowed size'));
      expect(summary, isNot(contains('Skipped')));
    });

    testWidgets('a bucket that cannot be read claims nothing per row',
        (tester) async {
      store.failPublished = const SocketException('no route to host');
      await openReports(tester);

      // The rows are there; what is not there is any claim about them, and
      // any button that would count them as missing (D28).
      expect(find.text('Harbour View Apartments'), findsOneWidget);
      expect(find.text('Northgate Retail Park'), findsOneWidget);
      expect(key('report-state-unknown'), findsOneWidget);
      expect(key('report-uploaded-insp-1'), findsNothing);
      expect(key('report-upload-insp-1'), findsNothing);
      expect(key('report-uploaded-insp-2'), findsNothing);
      expect(key('report-upload-insp-2'), findsNothing);
      expect(key('upload-missing-reports-button'), findsNothing);
      expect(store.puts, isEmpty);

      store.failPublished = null;
      await tester.tap(key('report-check-retry'));
      await tester.pumpAndSettle();

      expect(key('report-state-unknown'), findsNothing);
      expect(key('report-upload-insp-1'), findsOneWidget);
      expect(key('report-upload-insp-2'), findsOneWidget);
      expect(key('upload-missing-reports-button'), findsOneWidget);
    });

    testWidgets('a fresh tree over the same store shows the same state',
        (tester) async {
      await openReports(tester);
      await tester.tap(key('upload-missing-reports-button'));
      await tester.pumpAndSettle();
      expect(store.objects.keys.toSet(), {harbour, northgate});

      // A new widget tree remembers nothing; the state is the bucket's. Torn
      // down first, because a second FieldProofApp at the root would update
      // the existing elements in place and keep their state — which is the
      // opposite of what this proves. The session is still signed in, so the
      // shell mounts directly.
      await tester.pumpWidget(const SizedBox.shrink());
      await openReports(tester);

      expect(key('report-uploaded-insp-1'), findsOneWidget);
      expect(key('report-uploaded-insp-2'), findsOneWidget);
      expect(key('report-upload-insp-1'), findsNothing);
      expect(key('report-upload-insp-2'), findsNothing);
      expect(key('upload-missing-reports-button'), findsNothing);
      expect(key('reports-publish-summary'), findsNothing);
      expect(store.puts, hasLength(2));
    });
  });
}
