import 'dart:io';

import 'package:fieldproof/src/data/models.dart';
import 'package:fieldproof/src/data/photo_workflow.dart';
import 'package:fieldproof/src/offline/draft_store.dart';
import 'package:fieldproof/src/offline/draft_sync.dart';
import 'package:fieldproof/src/offline/offline_repositories.dart';
import 'package:fieldproof/src/offline/offline_status.dart';
import 'package:fieldproof/src/report/report_loader.dart';
import 'package:fieldproof/src/report/report_service.dart';
import 'package:fieldproof/src/ui/app.dart';
import 'package:fieldproof/src/ui/new_inspection_screen.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// The offline slice through the widget tree.
///
/// The point of these is that there is only ever *one* screen. The same New
/// Inspection sheet, the same punch-list editor and the same history run against
/// the same repository interfaces whether the server is reachable or not — so
/// what is proven here is that the seam sits at the data boundary and the UI
/// never learned about connectivity.
void main() {
  const offline = SocketException('Network is unreachable');

  late FakeAuthRepository auth;
  late FakeProfileRepository profiles;
  late FakeInspectionsRepository remoteInspections;
  late FakeInspectionItemsRepository remoteItems;
  late MemoryDraftStore store;
  late OfflineStatusNotifier status;
  late LocalDraftBook book;
  late OfflineFirstInspectionsRepository inspections;
  late OfflineFirstInspectionItemsRepository items;
  late FakeDraftSink sink;
  late DraftSync sync;
  late PhotoWorkflow photos;
  late FakePhotoSource source;
  late ReportService reports;

  void wire() {
    book = LocalDraftBook(
      store,
      onChanged: (pending) =>
          status.setPendingIds(pending.map((d) => d.id).toSet()),
    );
    inspections = OfflineFirstInspectionsRepository(
      remote: remoteInspections,
      local: book,
      auth: auth,
      status: status,
    );
    items = OfflineFirstInspectionItemsRepository(
      remote: remoteItems,
      local: book,
    );
    sync = DraftSync(local: book, sink: sink, auth: auth, status: status);
    reports = ReportService(
      loader: ReportLoader(items: items, photos: photos, profiles: profiles),
      renderer: FakeReportRenderer(),
      sharer: FakeReportSharer(),
    );
  }

  setUp(() {
    auth = FakeAuthRepository();
    profiles = FakeProfileRepository();
    remoteInspections = FakeInspectionsRepository();
    remoteItems = FakeInspectionItemsRepository();
    store = MemoryDraftStore();
    status = OfflineStatusNotifier();
    sink = FakeDraftSink();
    photos = PhotoWorkflow(
      objects: FakeObjectStore(),
      metadata: FakePhotoMetadataStore(),
      currentUserId: () => 'user-1',
    );
    source = FakePhotoSource();
    wire();
  });

  tearDown(() => auth.dispose());

  /// Signs in and lands on History.
  ///
  /// The default 800x600 viewport is shorter than these screens once a banner
  /// and a submit footer are in play, and a lazy list never builds an off-screen
  /// child, so a taller surface is used — the same accommodation
  /// `item_flow_test.dart` makes, and it changes nothing about the app.
  Future<void> launch(WidgetTester tester, {bool signIn = true}) async {
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
        offline: status,
        onSync: sync.run,
      ),
    );
    await tester.pumpAndSettle();

    if (signIn) {
      final fields = find.byType(CupertinoTextField);
      await tester.enterText(fields.at(0), 'a@example.com');
      await tester.enterText(fields.at(1), 'correct-horse');
      await tester.tap(find.widgetWithText(CupertinoButton, 'Sign In'));
      await tester.pumpAndSettle();
    }
  }

  /// Tears the tree down before rebuilding it, so the relaunch really is one.
  ///
  /// Pumping the new app over the old one would reuse `InspectionsScreen`'s
  /// State — same runtime type, same ValueKey — and the assertion would then be
  /// satisfied by data the previous objects had already loaded, proving nothing
  /// about what survived on disk.
  Future<void> relaunch(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    status = OfflineStatusNotifier();
    wire();
    await launch(tester, signIn: false);
    await tester.pumpAndSettle();
  }

  // Scoped to the sheet: the inspections screen stays mounted underneath and its
  // search box is also a CupertinoTextField, so an unscoped finder would shift
  // every form field by one.
  Finder sheetFields() => find.descendant(
        of: find.byType(NewInspectionSheet),
        matching: find.byType(CupertinoTextField),
      );

  Future<void> createInspection(
    WidgetTester tester, {
    String site = 'Northgate Retail Park',
    String address = '4 Northgate Way, Leeds',
    String client = 'Cavendish Estates',
  }) async {
    await tester.tap(find.byIcon(CupertinoIcons.add));
    await tester.pumpAndSettle();

    await tester.enterText(sheetFields().at(0), site);
    await tester.enterText(sheetFields().at(1), address);
    await tester.enterText(sheetFields().at(2), client);
    await tester.tap(find.byKey(const Key('create-inspection-button')));
    await tester.pumpAndSettle();
  }

  Future<void> addItem(WidgetTester tester, String title) async {
    await tester.tap(find.byKey(const Key('add-item-button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(CupertinoTextField).at(0), title);

    final saveButton = find.byKey(const Key('save-item-button'));
    await tester.ensureVisible(saveButton);
    await tester.pumpAndSettle();
    await tester.tap(saveButton);
    await tester.pumpAndSettle();
  }

  testWidgets('a draft created with no connection appears in History, marked',
      (tester) async {
    await launch(tester);
    remoteInspections.failWith = offline;

    await createInspection(tester);

    expect(find.text('Northgate Retail Park'), findsOneWidget);
    expect(find.byKey(const Key('unsynced-pill')), findsOneWidget);
    // It is a draft *and* it is not on the server. Both, because after a sync
    // one is still true and the other is not.
    expect(find.text('Draft'), findsOneWidget);
    expect(find.byKey(const Key('offline-banner')), findsOneWidget);
  });

  testWidgets('the banner says what is missing rather than hiding it',
      (tester) async {
    await launch(tester);
    remoteInspections.failWith = offline;
    await createInspection(tester);

    final message = tester.widget<Text>(
      find.byKey(const Key('offline-banner-message')),
    );
    expect(message.data, contains('Offline'));
    expect(message.data, contains('only those are shown'));
  });

  testWidgets('nothing offline is shown when everything is online',
      (tester) async {
    await launch(tester);
    await createInspection(tester);

    expect(find.text('Northgate Retail Park'), findsOneWidget);
    expect(find.byKey(const Key('offline-banner')), findsNothing);
    expect(find.byKey(const Key('unsynced-pill')), findsNothing);
  });

  testWidgets(
      'punch items can be added to an offline draft, through the same '
      'editor', (tester) async {
    await launch(tester);
    remoteInspections.failWith = offline;
    await createInspection(tester);

    await tester.tap(find.text('Northgate Retail Park'));
    await tester.pumpAndSettle();
    await addItem(tester, 'Cracked pane');

    expect(find.text('Cracked pane'), findsOneWidget);
  });

  testWidgets('the draft and its items are still there after a relaunch',
      (tester) async {
    await launch(tester);
    remoteInspections.failWith = offline;
    await createInspection(tester);
    await tester.tap(find.text('Northgate Retail Park'));
    await tester.pumpAndSettle();
    await addItem(tester, 'Cracked pane');

    // Still offline when it reopens: the app pushes what it is holding on the
    // way in, so without this the draft would sync during the relaunch and the
    // test would be asserting the wrong thing.
    sink.failInspection = offline;

    // Everything that holds state is rebuilt; only the stored bytes survive.
    // The session survives too, which is what a real relaunch does — signing out
    // is a user action, not a side effect of the process ending.
    await relaunch(tester);

    expect(find.text('Northgate Retail Park'), findsOneWidget);
    expect(find.byKey(const Key('unsynced-pill')), findsOneWidget);

    await tester.tap(find.text('Northgate Retail Park'));
    await tester.pumpAndSettle();
    expect(find.text('Cracked pane'), findsOneWidget);
  });

  testWidgets('search finds an offline draft by site, address and client',
      (tester) async {
    await launch(tester);
    remoteInspections.failWith = offline;
    await createInspection(tester);

    final field = find.byKey(const Key('inspections-search'));
    for (final query in ['northgate', 'leeds', 'cavendish']) {
      await tester.enterText(field, query);
      await tester.pumpAndSettle();
      expect(
        find.text('Northgate Retail Park'),
        findsOneWidget,
        reason: 'the local draft should match "$query"',
      );
    }

    await tester.enterText(field, 'zzzznothing');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('inspections-no-matches')), findsOneWidget);
  });

  testWidgets('an unsynced draft offers no Submit, and says why',
      (tester) async {
    await launch(tester);
    remoteInspections.failWith = offline;
    await createInspection(tester);

    await tester.tap(find.text('Northgate Retail Park'));
    await tester.pumpAndSettle();

    // Absent, not disabled — the same rule the add and report affordances
    // follow. A greyed-out Submit invites a tap that can never work.
    expect(find.byKey(const Key('submit-inspection-button')), findsNothing);
    expect(find.byKey(const Key('detail-unsynced-notice')), findsOneWidget);
    // Still fully editable, which is the whole point of it being local.
    expect(find.byKey(const Key('add-item-button')), findsOneWidget);
  });

  testWidgets('Retry syncs, the marker clears, and the row appears once',
      (tester) async {
    await launch(tester);
    remoteInspections.failWith = offline;
    await createInspection(tester);
    expect(find.byKey(const Key('unsynced-pill')), findsOneWidget);

    // The connection returns. The server-backed row is what the reloaded
    // history will read.
    remoteInspections.failWith = null;
    remoteInspections.rows.add(
      Inspection(
        id: (await book.all()).single.id,
        inspectorId: 'user-1',
        siteName: 'Northgate Retail Park',
        siteAddress: '4 Northgate Way, Leeds',
        clientName: 'Cavendish Estates',
        inspectionDate: DateTime.now(),
        status: InspectionStatus.draft,
      ),
    );

    await tester.tap(find.byKey(const Key('offline-retry-button')));
    await tester.pumpAndSettle();

    expect(find.text('Northgate Retail Park'), findsOneWidget);
    expect(find.byKey(const Key('unsynced-pill')), findsNothing);
    expect(find.byKey(const Key('offline-banner')), findsNothing);
    expect(sink.inspections, hasLength(1));
  });

  testWidgets('once synced, the ordinary Submit flow is available and works',
      (tester) async {
    await launch(tester);
    remoteInspections.failWith = offline;
    await createInspection(tester);

    remoteInspections.failWith = null;
    remoteInspections.rows.add(
      Inspection(
        id: (await book.all()).single.id,
        inspectorId: 'user-1',
        siteName: 'Northgate Retail Park',
        inspectionDate: DateTime.now(),
        status: InspectionStatus.draft,
      ),
    );
    await tester.tap(find.byKey(const Key('offline-retry-button')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Northgate Retail Park'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('detail-unsynced-notice')), findsNothing);

    final submitButton = find.byKey(const Key('submit-inspection-button'));
    await tester.ensureVisible(submitButton);
    await tester.pumpAndSettle();
    await tester.tap(submitButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('submit-confirm-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('detail-status')), findsOneWidget);
    expect(find.text('Submitted'), findsWidgets);
  });

  testWidgets('reopening with a connection pushes the queue unasked',
      (tester) async {
    await launch(tester);
    remoteInspections.failWith = offline;
    await createInspection(tester);

    // Signal is back by the time the app is next opened. An inspector should
    // not have to know a queue exists.
    final id = (await book.all()).single.id;
    remoteInspections.failWith = null;
    remoteInspections.rows.add(
      Inspection(
        id: id,
        inspectorId: 'user-1',
        siteName: 'Northgate Retail Park',
        inspectionDate: DateTime.now(),
        status: InspectionStatus.draft,
      ),
    );

    await relaunch(tester);

    expect(sink.inspections, hasLength(1));
    expect(find.text('Northgate Retail Park'), findsOneWidget);
    expect(find.byKey(const Key('unsynced-pill')), findsNothing);
    expect(find.byKey(const Key('offline-banner')), findsNothing);
  });

  testWidgets('a failed sync keeps the draft and shows the reason',
      (tester) async {
    await launch(tester);
    remoteInspections.failWith = offline;
    await createInspection(tester);

    sink.failInspection = offline;
    await tester.tap(find.byKey(const Key('offline-retry-button')));
    await tester.pumpAndSettle();

    // Not discarded, and not silently swallowed.
    expect(find.text('Northgate Retail Park'), findsOneWidget);
    expect(find.byKey(const Key('unsynced-pill')), findsOneWidget);
    final error = tester.widget<Text>(
      find.byKey(const Key('offline-banner-error')),
    );
    expect(error.data, contains('Network is unreachable'));
  });
}
