import 'package:fieldproof/src/data/models.dart';
import 'package:fieldproof/src/data/photo_workflow.dart';
import 'package:fieldproof/src/ui/app.dart';
import 'package:fieldproof/src/ui/inspections_screen.dart';
import 'package:fieldproof/src/ui/new_inspection_screen.dart';
import 'package:fieldproof/src/ui/sign_in_screen.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  late FakeAuthRepository auth;
  late FakeProfileRepository profiles;
  late FakeInspectionsRepository inspections;
  late FakeInspectionItemsRepository items;
  late FakeObjectStore objectStore;
  late FakePhotoMetadataStore photoMeta;
  late PhotoWorkflow photos;
  late FakePhotoSource source;

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
  });

  tearDown(() => auth.dispose());

  Future<void> pumpApp(WidgetTester tester) async {
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
  }

  Future<void> signIn(
    WidgetTester tester, {
    String email = 'a@example.com',
    String password = 'correct-horse',
  }) async {
    final fields = find.byType(CupertinoTextField);
    await tester.enterText(fields.at(0), email);
    await tester.enterText(fields.at(1), password);
    await tester.tap(find.widgetWithText(CupertinoButton, 'Sign In'));
    await tester.pumpAndSettle();
  }

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.byIcon(CupertinoIcons.add));
    await tester.pumpAndSettle();
  }

  Future<void> tapCreate(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('create-inspection-button')));
    await tester.pumpAndSettle();
  }

  group('auth gate', () {
    testWidgets('starts signed out', (tester) async {
      await pumpApp(tester);
      expect(find.byType(SignInScreen), findsOneWidget);
      expect(find.text('Field inspection, simplified.'), findsOneWidget);
      expect(find.byType(InspectionsScreen), findsNothing);
    });

    testWidgets('bad credentials surface the real error and do not navigate',
        (tester) async {
      await pumpApp(tester);
      await signIn(tester, password: 'wrong');

      expect(find.byKey(const Key('signin-error')), findsOneWidget);
      expect(find.byType(InspectionsScreen), findsNothing);
    });

    testWidgets('valid credentials reach the inspections screen',
        (tester) async {
      await pumpApp(tester);
      await signIn(tester);

      expect(find.byType(InspectionsScreen), findsOneWidget);
      expect(find.byKey(const Key('inspections-empty')), findsOneWidget);
    });

    testWidgets('signing out returns to sign in', (tester) async {
      await pumpApp(tester);
      await signIn(tester);

      await tester.tap(find.widgetWithText(CupertinoButton, 'Sign Out'));
      await tester.pumpAndSettle();

      expect(auth.signOutCount, 1);
      expect(find.byType(SignInScreen), findsOneWidget);
      expect(find.byType(InspectionsScreen), findsNothing);
    });
  });

  group('profile bootstrap', () {
    testWidgets('a missing profile row is surfaced, not papered over',
        (tester) async {
      profiles.throwMissing = true;
      await pumpApp(tester);
      await signIn(tester);

      expect(find.byKey(const Key('inspections-error')), findsOneWidget);
      expect(find.byKey(const Key('inspections-empty')), findsNothing);
    });
  });

  group('create inspection', () {
    testWidgets('the sheet offers exactly the schema fields', (tester) async {
      await pumpApp(tester);
      await signIn(tester);
      await openSheet(tester);

      // Name, Address, Client — and nothing else. The Figma mockup also shows a
      // Template picker and an editable Inspector; both are rejected in favour
      // of the accepted schema, so neither may appear as an input.
      expect(find.byType(CupertinoTextField), findsNWidgets(3));
      expect(find.text('Name'), findsOneWidget);
      expect(find.text('Address'), findsOneWidget);
      expect(find.text('Client'), findsOneWidget);
      expect(find.text('Template'), findsNothing);
    });

    testWidgets('the inspector is read-only and comes from the profile',
        (tester) async {
      await pumpApp(tester);
      await signIn(tester);
      await openSheet(tester);

      final inspectorRow = find.byKey(const Key('inspector-readonly'));
      expect(inspectorRow, findsOneWidget);
      expect(tester.widget<Text>(inspectorRow).data, 'Inspector Alpha');

      // Read-only means it is not an input at all, not merely disabled.
      expect(
        find.descendant(
          of: find.byType(NewInspectionSheet),
          matching: find.widgetWithText(CupertinoTextField, 'Inspector Alpha'),
        ),
        findsNothing,
      );
    });

    testWidgets('an empty site name blocks the save', (tester) async {
      await pumpApp(tester);
      await signIn(tester);
      await openSheet(tester);
      await tapCreate(tester);

      expect(find.text('Site name is required.'), findsOneWidget);
      expect(inspections.insertPayloads, isEmpty);
    });

    testWidgets('a valid draft persists and appears in the list',
        (tester) async {
      await pumpApp(tester);
      await signIn(tester);
      await openSheet(tester);

      final fields = find.byType(CupertinoTextField);
      await tester.enterText(fields.at(0), 'Harbour View Apartments');
      await tester.enterText(fields.at(1), '12 Dock Road');
      await tester.enterText(fields.at(2), 'Meridian Property Group');
      await tapCreate(tester);

      expect(inspections.insertPayloads, hasLength(1));
      expect(find.byType(NewInspectionSheet), findsNothing);
      expect(find.text('Harbour View Apartments'), findsOneWidget);
      expect(find.text('Draft'), findsOneWidget);
    });

    testWidgets('the owner comes from the session, never from the form',
        (tester) async {
      await pumpApp(tester);
      await signIn(tester);
      await openSheet(tester);

      await tester.enterText(
        find.byType(CupertinoTextField).at(0),
        'Northgate Retail Park',
      );
      await tapCreate(tester);

      final payload = inspections.insertPayloads.single;
      expect(payload['inspector_id'], inspections.sessionUserId);
      expect(payload.containsKey('status'), isFalse);
      expect(payload.containsKey('template'), isFalse);
    });

    testWidgets('a rejected insert is shown and the sheet stays open',
        (tester) async {
      // Stands in for an RLS refusal: the write must not appear to succeed.
      inspections.failWith = Exception(
        'new row violates row-level security policy for table "inspections"',
      );

      await pumpApp(tester);
      await signIn(tester);
      await openSheet(tester);

      await tester.enterText(
        find.byType(CupertinoTextField).at(0),
        'Blocked Site',
      );
      await tapCreate(tester);

      expect(find.byKey(const Key('new-inspection-error')), findsOneWidget);
      expect(find.byType(NewInspectionSheet), findsOneWidget);
      expect(inspections.rows, isEmpty);
    });
  });

  group('history', () {
    testWidgets('renders both persisted lifecycle states', (tester) async {
      inspections.rows.addAll([
        Inspection(
          id: 'i1',
          inspectorId: 'user-1',
          siteName: 'Northgate Retail Park',
          inspectionDate: DateTime(2026, 8, 22),
          status: InspectionStatus.submitted,
        ),
        Inspection(
          id: 'i2',
          inspectorId: 'user-1',
          siteName: 'Harbour View',
          inspectionDate: DateTime(2026, 8, 20),
          status: InspectionStatus.draft,
        ),
      ]);

      await pumpApp(tester);
      await signIn(tester);

      expect(find.text('Northgate Retail Park'), findsOneWidget);
      expect(find.text('Submitted'), findsOneWidget);
      expect(find.text('Draft'), findsOneWidget);
      // The mockup's syncing/offline chips are never persisted (D5).
      expect(find.text('Syncing'), findsNothing);
      expect(find.text('Offline'), findsNothing);
    });
  });
}
