import 'package:fieldproof/src/data/models.dart';
import 'package:fieldproof/src/data/repositories.dart';
import 'package:fieldproof/src/data/photo_workflow.dart';
import 'package:fieldproof/src/ui/app.dart';
import 'package:fieldproof/src/ui/inspection_detail_screen.dart';
import 'package:fieldproof/src/ui/item_editor_sheet.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// Widget coverage for Inspection Detail and punch-item CRUD.
///
/// These prove the client contract only — the right payload, errors surfaced,
/// the parent never caller-supplied. They prove nothing about RLS, and the fake
/// repository deliberately enforces no ownership rule, so a test here cannot
/// accidentally "pass" isolation. That lives in pgTAP `020`/`060` and in the
/// hosted smoke test.
void main() {
  late FakeAuthRepository auth;
  late FakeProfileRepository profiles;
  late FakeInspectionsRepository inspections;
  late FakeInspectionItemsRepository items;
  late FakeObjectStore objectStore;
  late FakePhotoMetadataStore photoMeta;
  late PhotoWorkflow photos;
  late FakePhotoSource source;

  final draft = Inspection(
    id: 'insp-1',
    inspectorId: 'user-1',
    siteName: 'Harbour View Apartments',
    siteAddress: '12 Dock Road',
    clientName: 'Meridian Property Group',
    inspectionDate: DateTime(2026, 8, 20),
    status: InspectionStatus.draft,
  );

  setUp(() {
    auth = FakeAuthRepository();
    profiles = FakeProfileRepository();
    inspections = FakeInspectionsRepository(initial: [draft]);
    items = FakeInspectionItemsRepository();
    objectStore = FakeObjectStore();
    photoMeta = FakePhotoMetadataStore();
    photos = PhotoWorkflow(
      objects: objectStore,
      metadata: photoMeta,
      currentUserId: () => 'user-1',
    );
    source = FakePhotoSource();
  });

  tearDown(() => auth.dispose());

  Future<void> openDetail(WidgetTester tester) async {
    await tester.pumpWidget(
      FieldProofApp(
        auth: auth,
        profiles: profiles,
        inspections: inspections,
        items: items,
        photos: photos,
        source: source,
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

  Future<void> openEditor(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('add-item-button')));
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('save-item-button')));
    await tester.pumpAndSettle();
  }

  group('inspection detail', () {
    testWidgets('shows site, client, date and status', (tester) async {
      await openDetail(tester);

      expect(find.byType(InspectionDetailScreen), findsOneWidget);
      expect(find.text('Harbour View Apartments'), findsOneWidget);
      expect(find.text('12 Dock Road'), findsOneWidget);
      expect(find.text('Meridian Property Group'), findsOneWidget);
      expect(find.text('2026-08-20'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('detail-status'))).data,
        'Draft',
      );
    });

    testWidgets('empty punch list invites the first item', (tester) async {
      await openDetail(tester);
      expect(find.byKey(const Key('items-empty')), findsOneWidget);
    });
  });

  group('create', () {
    testWidgets('the editor offers exactly the schema fields', (tester) async {
      await openDetail(tester);
      await openEditor(tester);

      // Title, Area, Detail — and nothing else. Assignee and Template are
      // Figma-only and must not appear as inputs (D14).
      expect(find.byType(CupertinoTextField), findsNWidgets(3));
      expect(find.text('Assignee'), findsNothing);
      expect(find.text('Template'), findsNothing);
    });

    testWidgets('severity offers the four schema values, not the mockup three',
        (tester) async {
      await openDetail(tester);
      await openEditor(tester);

      for (final label in ['Low', 'Medium', 'High', 'Critical']) {
        expect(find.text(label), findsWidgets,
            reason: '$label must be offered');
      }
      expect(find.text('Minor'), findsNothing);
      expect(find.text('Major'), findsNothing);
    });

    testWidgets('an empty title blocks the save', (tester) async {
      await openDetail(tester);
      await openEditor(tester);
      await save(tester);

      expect(find.text('Title is required.'), findsOneWidget);
      expect(items.insertPayloads, isEmpty);
    });

    testWidgets('a valid item persists and appears in the list',
        (tester) async {
      await openDetail(tester);
      await openEditor(tester);

      final fields = find.byType(CupertinoTextField);
      await tester.enterText(fields.at(0), 'Cracked window pane');
      await tester.enterText(fields.at(1), 'Stairwell');
      await save(tester);

      expect(items.insertPayloads, hasLength(1));
      expect(find.byType(ItemEditorSheet), findsNothing);
      expect(find.text('Cracked window pane'), findsOneWidget);
    });

    testWidgets('the parent comes from the screen, never from the form',
        (tester) async {
      await openDetail(tester);
      await openEditor(tester);
      await tester.enterText(
        find.byType(CupertinoTextField).at(0),
        'Exposed wiring',
      );
      await save(tester);

      final payload = items.insertPayloads.single;
      expect(payload['inspection_id'], 'insp-1');
      expect(payload.containsKey('status'), isFalse);
      expect(payload['severity'], 'medium');
    });

    testWidgets('a rejected insert is shown and the sheet stays open',
        (tester) async {
      items.failWith = const NotPermittedException('create this item');

      await openDetail(tester);
      await openEditor(tester);
      await tester.enterText(
        find.byType(CupertinoTextField).at(0),
        'Blocked item',
      );
      await save(tester);

      expect(find.byKey(const Key('item-editor-error')), findsOneWidget);
      expect(find.byType(ItemEditorSheet), findsOneWidget);
      expect(items.rows, isEmpty);
    });
  });

  group('submitted inspections are read-only (D17)', () {
    final submitted = Inspection(
      id: 'insp-2',
      inspectorId: 'user-1',
      siteName: 'Northgate Retail Park',
      inspectionDate: DateTime(2026, 8, 22),
      status: InspectionStatus.submitted,
    );

    Future<void> openSubmitted(WidgetTester tester) async {
      inspections.rows
        ..clear()
        ..add(submitted);
      items.rows.add(
        const InspectionItem(
          id: 'item-x',
          inspectionId: 'insp-2',
          sortOrder: 0,
          title: 'Recorded defect',
          severity: ItemSeverity.high,
          status: ItemStatus.open,
        ),
      );

      await tester.pumpWidget(
        FieldProofApp(
          auth: auth,
          profiles: profiles,
          inspections: inspections,
          items: items,
          photos: photos,
          source: source,
        ),
      );
      await tester.pumpAndSettle();

      final fields = find.byType(CupertinoTextField);
      await tester.enterText(fields.at(0), 'a@example.com');
      await tester.enterText(fields.at(1), 'correct-horse');
      await tester.tap(find.widgetWithText(CupertinoButton, 'Sign In'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Northgate Retail Park'));
      await tester.pumpAndSettle();
    }

    testWidgets('there is no add affordance', (tester) async {
      await openSubmitted(tester);
      expect(find.byType(InspectionDetailScreen), findsOneWidget);
      expect(find.byKey(const Key('add-item-button')), findsNothing);
    });

    testWidgets('it says why it is read-only', (tester) async {
      await openSubmitted(tester);
      expect(find.byKey(const Key('read-only-notice')), findsOneWidget);
    });

    testWidgets('tapping an item does not open the editor', (tester) async {
      await openSubmitted(tester);
      await tester.tap(find.text('Recorded defect'));
      await tester.pumpAndSettle();

      expect(find.byType(ItemEditorSheet), findsNothing);
    });

    testWidgets('items are still readable', (tester) async {
      await openSubmitted(tester);
      expect(find.text('Recorded defect'), findsOneWidget);
      expect(find.text('High'), findsWidgets);
      expect(
        tester.widget<Text>(find.byKey(const Key('detail-status'))).data,
        'Submitted',
      );
    });
  });

  group('edit, resolve and delete', () {
    Future<void> seedOne(WidgetTester tester) async {
      await openDetail(tester);
      await openEditor(tester);
      await tester.enterText(
        find.byType(CupertinoTextField).at(0),
        'Fire door does not latch',
      );
      await save(tester);
    }

    testWidgets('tapping an item opens it for editing', (tester) async {
      await seedOne(tester);
      await tester.tap(find.text('Fire door does not latch'));
      await tester.pumpAndSettle();

      expect(find.byType(ItemEditorSheet), findsOneWidget);
      expect(find.text('Edit Item'), findsOneWidget);
      expect(find.byKey(const Key('delete-item-button')), findsOneWidget);
    });

    testWidgets('editing the title persists', (tester) async {
      await seedOne(tester);
      await tester.tap(find.text('Fire door does not latch'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byType(CupertinoTextField).at(0),
        'Fire door binds on the frame',
      );
      await save(tester);

      expect(find.text('Fire door binds on the frame'), findsOneWidget);
      expect(find.text('Fire door does not latch'), findsNothing);
      expect(items.rows.single.title, 'Fire door binds on the frame');
    });

    testWidgets('resolving and reopening both work', (tester) async {
      await seedOne(tester);
      expect(items.rows.single.status, ItemStatus.open);

      await tester.tap(find.text('Fire door does not latch'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('item-resolved-switch')));
      await tester.pumpAndSettle();
      await save(tester);

      expect(items.rows.single.status, ItemStatus.resolved);

      // Reopen. Unlike inspections.status (one-way, D10), nothing constrains
      // this transition, so the reverse must work too.
      await tester.tap(find.text('Fire door does not latch'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('item-resolved-switch')));
      await tester.pumpAndSettle();
      await save(tester);

      expect(items.rows.single.status, ItemStatus.open);
    });

    testWidgets('deleting removes it after confirmation', (tester) async {
      await seedOne(tester);
      await tester.tap(find.text('Fire door does not latch'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('delete-item-button')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.widgetWithText(CupertinoActionSheetAction, 'Delete'));
      await tester.pumpAndSettle();

      expect(items.deleted, hasLength(1));
      expect(items.rows, isEmpty);
      expect(find.byKey(const Key('items-empty')), findsOneWidget);
    });

    testWidgets('cancelling the delete confirmation keeps the item',
        (tester) async {
      await seedOne(tester);
      await tester.tap(find.text('Fire door does not latch'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('delete-item-button')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.widgetWithText(CupertinoActionSheetAction, 'Cancel'));
      await tester.pumpAndSettle();

      expect(items.deleted, isEmpty);
      expect(items.rows, hasLength(1));
    });
  });
}
