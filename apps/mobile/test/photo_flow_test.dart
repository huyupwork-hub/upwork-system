import 'package:fieldproof/src/data/models.dart';
import 'package:fieldproof/src/data/photo_workflow.dart';
import 'package:fieldproof/src/ui/app.dart';
import 'package:fieldproof/src/ui/photo_strip.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// Widget coverage for attaching, viewing and removing photos.
///
/// The capture source is faked, so no platform channel is involved; real camera
/// capture is Android device/build evidence (D20), not something a host test can
/// prove. Ownership is likewise not faked — that is pgTAP `080` and the hosted
/// smoke run.
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
    inspectionDate: DateTime(2026, 8, 20),
    status: InspectionStatus.draft,
  );
  final submitted = Inspection(
    id: 'insp-2',
    inspectorId: 'user-1',
    siteName: 'Northgate Retail Park',
    inspectionDate: DateTime(2026, 8, 22),
    status: InspectionStatus.submitted,
  );

  const item = InspectionItem(
    id: 'item-1',
    inspectionId: 'insp-1',
    sortOrder: 0,
    title: 'Cracked pane',
    severity: ItemSeverity.medium,
    status: ItemStatus.open,
  );

  setUp(() {
    auth = FakeAuthRepository();
    profiles = FakeProfileRepository();
    inspections = FakeInspectionsRepository(initial: [draft]);
    items = FakeInspectionItemsRepository(initial: [item]);
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

  Future<void> openItem(WidgetTester tester, {bool submittedParent = false}) async {
    if (submittedParent) {
      inspections.rows
        ..clear()
        ..add(submitted);
      items.rows
        ..clear()
        ..add(
          const InspectionItem(
            id: 'item-1',
            inspectionId: 'insp-2',
            sortOrder: 0,
            title: 'Cracked pane',
            severity: ItemSeverity.medium,
            status: ItemStatus.open,
          ),
        );
    }

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

    await tester.tap(find.text(submittedParent ? 'Northgate Retail Park' : 'Harbour View Apartments'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cracked pane'));
    await tester.pumpAndSettle();
  }

  Future<void> addPhoto(WidgetTester tester, {bool fromCamera = true}) async {
    await tester.tap(find.byKey(const Key('add-photo-button')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(Key(fromCamera ? 'photo-camera' : 'photo-gallery')),
    );
    await tester.pumpAndSettle();
  }

  group('attaching', () {
    testWidgets('the editor offers an add-photo affordance on a draft',
        (tester) async {
      await openItem(tester);
      expect(find.byType(PhotoStrip), findsOneWidget);
      expect(find.byKey(const Key('add-photo-button')), findsOneWidget);
    });

    testWidgets('taking a photo uploads it and shows a thumbnail',
        (tester) async {
      await openItem(tester);
      await addPhoto(tester);

      expect(source.cameraCalls, 1);
      expect(photoMeta.rows, hasLength(1));
      expect(objectStore.objects, hasLength(1));
      expect(
        find.byKey(Key('photo-thumb-${photoMeta.rows.single.id}')),
        findsOneWidget,
      );
    });

    testWidgets('choosing from the library works the same way', (tester) async {
      await openItem(tester);
      await addPhoto(tester, fromCamera: false);

      expect(source.galleryCalls, 1);
      expect(source.cameraCalls, 0);
      expect(photoMeta.rows, hasLength(1));
    });

    testWidgets('cancelling the picker attaches nothing', (tester) async {
      source.next = null; // the user backed out
      await openItem(tester);
      await addPhoto(tester);

      expect(source.cameraCalls, 1);
      expect(photoMeta.rows, isEmpty);
      expect(objectStore.objects, isEmpty);
    });

    testWidgets('a rejected image is reported and nothing is stored',
        (tester) async {
      source.next = CapturedPhoto(
        bytes: List.filled(PhotoLimits.maxBytes + 1, 0),
        contentType: 'image/jpeg',
      );
      await openItem(tester);
      await addPhoto(tester);

      expect(find.byKey(const Key('photo-error')), findsOneWidget);
      expect(objectStore.objects, isEmpty);
      expect(photoMeta.rows, isEmpty);
    });

    testWidgets('a failed metadata insert leaves no object behind',
        (tester) async {
      photoMeta.failInsert = Exception('insert refused');
      await openItem(tester);
      await addPhoto(tester);

      expect(find.byKey(const Key('photo-error')), findsOneWidget);
      expect(objectStore.objects, isEmpty, reason: 'compensated');
      expect(objectStore.removed, hasLength(1));
    });
  });

  group('viewing and deleting', () {
    testWidgets('tapping a thumbnail opens the viewer', (tester) async {
      await openItem(tester);
      await addPhoto(tester);

      await tester.tap(
        find.byKey(Key('photo-thumb-${photoMeta.rows.single.id}')),
      );
      await tester.pumpAndSettle();

      expect(find.byType(PhotoViewer), findsOneWidget);
      expect(find.byKey(const Key('delete-photo-button')), findsOneWidget);
    });

    testWidgets('deleting removes the row and then the object', (tester) async {
      await openItem(tester);
      await addPhoto(tester);
      final path = photoMeta.rows.single.storagePath;

      await tester.tap(
        find.byKey(Key('photo-thumb-${photoMeta.rows.single.id}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('delete-photo-button')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(CupertinoActionSheetAction, 'Delete'),
      );
      await tester.pumpAndSettle();

      expect(photoMeta.rows, isEmpty);
      expect(objectStore.removed, contains(path));
      expect(find.byType(PhotoViewer), findsNothing);
    });

    testWidgets('cancelling the confirmation keeps the photo', (tester) async {
      await openItem(tester);
      await addPhoto(tester);

      await tester.tap(
        find.byKey(Key('photo-thumb-${photoMeta.rows.single.id}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('delete-photo-button')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(CupertinoActionSheetAction, 'Cancel'),
      );
      await tester.pumpAndSettle();

      expect(photoMeta.rows, hasLength(1));
      expect(objectStore.removed, isEmpty);
    });
  });

  group('submitted parent is read-only (D17)', () {
    testWidgets('the item editor is unreachable, so no photo can be added',
        (tester) async {
      await openItem(tester, submittedParent: true);

      // Tapping the row on a submitted inspection does not open the editor at
      // all, so there is no add-photo affordance to reach.
      expect(find.byKey(const Key('add-photo-button')), findsNothing);
      expect(find.byKey(const Key('read-only-notice')), findsOneWidget);
    });
  });
}
