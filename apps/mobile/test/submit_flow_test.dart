import 'package:fieldproof/src/data/models.dart';
import 'package:fieldproof/src/data/photo_workflow.dart';
import 'package:fieldproof/src/data/repositories.dart';
import 'package:fieldproof/src/report/report_loader.dart';
import 'package:fieldproof/src/report/report_service.dart';
import 'package:fieldproof/src/ui/app.dart';
import 'package:fieldproof/src/ui/theme.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// Submitting a draft, through the widget tree.
///
/// This closes a gap real-device QA found: every gate was green and the
/// database enforced the transition correctly, but the app had no way to
/// perform it — the hosted smoke reached around the client and wrote
/// `status = 'submitted'` itself. These tests exist so the app's own path is
/// the thing under test.
///
/// They prove the client contract only. That an inspection is genuinely frozen
/// afterwards is the database's job, proven in pgTAP `070` and hosted smoke
/// cases 22–23; the fake repository enforces no ownership rule of its own.
void main() {
  late FakeAuthRepository auth;
  late FakeProfileRepository profiles;
  late FakeInspectionsRepository inspections;
  late FakeInspectionItemsRepository items;
  late PhotoWorkflow photos;
  late FakePhotoSource source;
  late ReportService reports;

  Inspection make(InspectionStatus status) => Inspection(
        id: 'insp-1',
        inspectorId: 'user-1',
        siteName: 'Harbour View Apartments',
        siteAddress: '12 Dock Road',
        clientName: 'Meridian Property Group',
        inspectionDate: DateTime(2026, 8, 20),
        status: status,
        submittedAt:
            status == InspectionStatus.submitted ? DateTime(2026, 8, 22) : null,
      );

  void build(InspectionStatus status) {
    auth = FakeAuthRepository();
    profiles = FakeProfileRepository();
    inspections = FakeInspectionsRepository(initial: [make(status)]);
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
  }

  setUp(() => build(InspectionStatus.draft));
  tearDown(() => auth.dispose());

  /// A status word as rendered inside a list card, not anywhere on screen.
  ///
  /// The parity pass gave the list a filter whose segments are also spelled
  /// "Drafts"/"Submitted", and a summary strip that counts them. An unscoped
  /// find.text can therefore match furniture instead of the row, so these
  /// assertions say which one they mean.
  Finder statusInCard(String label) => find.descendant(
        of: find.byType(InsetCard),
        matching: find.text(label),
      );

  Future<void> openDetail(WidgetTester tester) async {
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

    await tester.tap(find.text('Harbour View Apartments'));
    await tester.pumpAndSettle();
  }

  Finder submitButton() => find.byKey(const Key('submit-inspection-button'));

  group('the control', () {
    testWidgets('a draft offers a submit action', (tester) async {
      await openDetail(tester);
      expect(submitButton(), findsOneWidget);
    });

    testWidgets('a submitted inspection has no submit action at all',
        (tester) async {
      build(InspectionStatus.submitted);
      await openDetail(tester);

      // Absent, not disabled — the same rule the add and report actions follow.
      expect(submitButton(), findsNothing);
    });

    testWidgets('an inspection with no items can still be submitted',
        (tester) async {
      // A site with nothing wrong is a real result. Requiring a defect would
      // push people into inventing one.
      await openDetail(tester);
      expect(items.rows, isEmpty);
      expect(submitButton(), findsOneWidget);
    });
  });

  group('confirmation', () {
    testWidgets('submitting asks first, naming both consequences',
        (tester) async {
      await openDetail(tester);
      await tester.tap(submitButton());
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('submit-confirm-sheet')), findsOneWidget);
      expect(find.textContaining('permanent record'), findsOneWidget);
      expect(find.textContaining('Reviewers'), findsOneWidget);
      expect(inspections.submitted, isEmpty);
    });

    testWidgets('cancelling submits nothing and leaves the draft editable',
        (tester) async {
      await openDetail(tester);
      await tester.tap(submitButton());
      await tester.pumpAndSettle();

      await tester
          .tap(find.widgetWithText(CupertinoActionSheetAction, 'Cancel'));
      await tester.pumpAndSettle();

      expect(inspections.submitted, isEmpty);
      expect(find.byKey(const Key('detail-status')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('detail-status'))).data,
          'Draft');
      expect(find.byKey(const Key('add-item-button')), findsOneWidget);
    });
  });

  group('submitting', () {
    Future<void> confirm(WidgetTester tester) async {
      await tester.tap(submitButton());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('submit-confirm-button')));
      await tester.pumpAndSettle();
    }

    testWidgets('sends only the id, and the screen becomes the frozen record',
        (tester) async {
      await openDetail(tester);
      await confirm(tester);

      expect(inspections.submitted, ['insp-1']);
      expect(tester.widget<Text>(find.byKey(const Key('detail-status'))).data,
          'Submitted');
    });

    testWidgets('the editing affordances disappear once submitted',
        (tester) async {
      await openDetail(tester);
      await confirm(tester);

      // The screen must not keep offering what the database will now refuse.
      expect(find.byKey(const Key('add-item-button')), findsNothing);
      expect(submitButton(), findsNothing);
      expect(find.byKey(const Key('generate-report-button')), findsOneWidget);
      expect(find.textContaining('can no longer be changed'), findsOneWidget);
    });

    testWidgets('a refusal is surfaced and nothing is claimed to have changed',
        (tester) async {
      inspections.submitFailsWith =
          const NotPermittedException('submit this inspection');
      await openDetail(tester);
      await confirm(tester);

      expect(find.byKey(const Key('submit-error')), findsOneWidget);
      // Still a draft, and still submittable — the failure did not half-apply.
      expect(tester.widget<Text>(find.byKey(const Key('detail-status'))).data,
          'Draft');
      expect(submitButton(), findsOneWidget);
    });

    testWidgets('the history list reflects the new status on return',
        (tester) async {
      await openDetail(tester);
      await confirm(tester);

      await tester.tap(find.text('Inspections').first);
      await tester.pumpAndSettle();

      // Without a reload on return the list would still say Draft for work that
      // is now frozen — stale exactly where the user looks to confirm it.
      expect(statusInCard('Submitted'), findsOneWidget);
      expect(statusInCard('Draft'), findsNothing);
    });
  });
}
