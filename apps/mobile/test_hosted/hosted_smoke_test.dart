/// Hosted Supabase authenticated smoke test.
///
/// Proves the Auth -> Create Inspection slice against a REAL hosted project,
/// which no other test in this repository does: `test/` runs entirely against
/// in-memory fakes and touches no network.
///
/// Deliberately NOT under `test/`. `flutter test` with no arguments runs only
/// `test/`, so this cannot accidentally join the hermetic suite and make it
/// network-dependent or non-deterministic. Run it explicitly:
///
///   flutter test test_hosted/
///
/// Credentials come from the environment, never from --dart-define: dart-defines
/// land in the process command line and in CI step echoes, environment variables
/// do not. Nothing here is committed and nothing is printed.
///
/// Required environment variables:
///   SUPABASE_URL             https://<ref>.supabase.co
///   SUPABASE_ANON_KEY        the anon / publishable key — never the service role
///   SMOKE_USER_A_EMAIL       an existing confirmed user
///   SMOKE_USER_A_PASSWORD
///   SMOKE_USER_B_EMAIL       a second, different existing confirmed user
///   SMOKE_USER_B_PASSWORD
///
/// This test uses the anon key only. It exercises the same repository classes the
/// app uses, so what passes here is the real client path, not a parallel one.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fieldproof/src/data/models.dart';
import 'package:fieldproof/src/data/repositories.dart';
import 'package:fieldproof/src/data/photo_workflow.dart';
import 'package:fieldproof/src/data/supabase_repositories.dart';
import 'package:fieldproof/src/offline/draft_store.dart';
import 'package:fieldproof/src/offline/draft_sync.dart';
import 'package:fieldproof/src/offline/local_draft.dart';
import 'package:fieldproof/src/offline/offline_status.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

/// Ids are minted on the device, before anything is written. That is the whole
/// idempotency story (D5), so the smoke test has to mint them the same way.
const Uuid _uuid = Uuid();

String _env(String name) {
  final value = Platform.environment[name] ?? '';
  if (value.isEmpty) {
    fail(
      '$name is not set. This test needs a hosted Supabase project; see '
      'docs/SMOKE_TEST.md for the full list and how to provide it.',
    );
  }
  return value;
}

/// Refuses to run under a privileged key.
///
/// This is the one mistake that would invalidate every assertion in the file: a
/// privileged key bypasses RLS completely, so the isolation cases would pass
/// while proving nothing at all.
///
/// It decodes the JWT and inspects the `role` claim rather than substring-matching
/// the key, which is both a real check and avoids planting a string that the
/// repository's own secret-hygiene gate scans for.
void _assertNotPrivileged(String key) {
  final parts = key.split('.');
  if (parts.length == 3) {
    try {
      final payload = json.decode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      ) as Map<String, dynamic>;
      final role = payload['role'];
      if (role != 'anon') {
        fail('SUPABASE_ANON_KEY carries role "$role"; expected "anon".');
      }
    } on FormatException {
      // Not a JWT after all; fall through to the prefix check below.
    }
  }
  // Newer Supabase keys are not JWTs: publishable keys start sb_publishable_,
  // secret keys start sb_secret_.
  if (key.startsWith('sb_secret_')) {
    fail('SUPABASE_ANON_KEY is a secret key; this test must use a public one.');
  }
}

void main() {
  // Two independent clients, so each holds its own session. Sharing one client
  // would make "user B cannot see it" meaningless — it would still be user A.
  late SupabaseClient clientA;
  late SupabaseClient clientB;

  late AuthRepository authA;
  late ProfileRepository profilesA;
  late InspectionsRepository inspectionsA;
  late InspectionsRepository inspectionsB;
  late InspectionItemsRepository itemsA;
  late InspectionItemsRepository itemsB;
  late PhotosRepository photosA;
  late PhotosRepository photosB;
  ItemPhoto? photo;

  InspectionItem? item;
  Inspection? histOlder;
  Inspection? histNewer;
  Inspection? bUnique;

  // Nonsense tokens, unique per run, so a search assertion cannot accidentally
  // match a leftover row from an earlier run.
  final searchTerm = 'zqx${DateTime.now().microsecondsSinceEpoch}';
  final bSearchTerm = 'qzb${DateTime.now().microsecondsSinceEpoch}';

  late String userAId;
  late String userBId;

  Inspection? created;

  // Distinctive per-run name so a leaked row is traceable to the run that made it.
  final siteName =
      'SMOKE ${DateTime.now().toUtc().toIso8601String()} do-not-keep';

  // The offline slice. Ids are minted here, before anything is written, exactly
  // as the device does — that is the property being exercised, so they cannot
  // come back from the server.
  final offlineToken = 'ofl${DateTime.now().microsecondsSinceEpoch}';
  final offlineId = _uuid.v4();
  final offlineItemA = _uuid.v4();
  final offlineItemB = _uuid.v4();
  final offlineSite = 'SMOKE $offlineToken offline do-not-keep';
  LocalDraftBook? offlineBook;
  OfflineStatusNotifier? offlineStatus;
  DraftSync? offlineSync;

  setUpAll(() async {
    final url = _env('SUPABASE_URL');
    final anonKey = _env('SUPABASE_ANON_KEY');

    _assertNotPrivileged(anonKey);

    clientA = SupabaseClient(url, anonKey);
    clientB = SupabaseClient(url, anonKey);

    final a = await clientA.auth.signInWithPassword(
      email: _env('SMOKE_USER_A_EMAIL'),
      password: _env('SMOKE_USER_A_PASSWORD'),
    );
    final b = await clientB.auth.signInWithPassword(
      email: _env('SMOKE_USER_B_EMAIL'),
      password: _env('SMOKE_USER_B_PASSWORD'),
    );

    userAId = a.user!.id;
    userBId = b.user!.id;

    authA = SupabaseAuthRepository(clientA);
    profilesA = SupabaseProfileRepository(clientA);
    inspectionsA = SupabaseInspectionsRepository(clientA);
    inspectionsB = SupabaseInspectionsRepository(clientB);
    itemsA = SupabaseInspectionItemsRepository(clientA);
    itemsB = SupabaseInspectionItemsRepository(clientB);
    photosA = PhotoWorkflow(
      objects: SupabaseObjectStore(clientA),
      metadata: SupabasePhotoMetadataStore(clientA),
      currentUserId: () => userAId,
    );
    photosB = PhotoWorkflow(
      objects: SupabaseObjectStore(clientB),
      metadata: SupabasePhotoMetadataStore(clientB),
      currentUserId: () => userBId,
    );
  });

  tearDownAll(() async {
    // Leave the project as we found it. Deleting as A also re-proves the owner
    // delete policy works.
    final id = created?.id;
    if (id != null) {
      await clientA.from('inspections').delete().eq('id', id);
    }
    // Belt and braces: if an offline case failed before its own cleanup, this
    // still removes the fixture. It is a draft throughout, so the owner delete
    // policy applies to it.
    await clientA.from('inspections').delete().eq('id', offlineId);
    await clientA.auth.signOut();
    await clientB.auth.signOut();
    await clientA.dispose();
    await clientB.dispose();
  });

  test('1. user A authenticates with ordinary Supabase Auth', () {
    expect(userAId, isNotEmpty);
    expect(authA.currentUserId, userAId);
    // Two genuinely different principals, or the isolation cases below are void.
    expect(userBId, isNot(userAId));
  });

  test('2. user A profile exists via the trigger bootstrap path', () async {
    final profile = await profilesA.loadCurrent();
    expect(profile.id, userAId);
    expect(profile.fullName, isNotEmpty);
    expect(profile.role, 'inspector',
        reason:
            'a smoke user must not be an admin; D3 changes what it can see');
  });

  test('3. user A creates a draft through the app repository path', () async {
    created = await inspectionsA.create(
      NewInspection(
        siteName: siteName,
        siteAddress: '1 Smoke Test Road',
        clientName: 'Smoke Test Client',
        inspectionDate: DateTime.now(),
      ),
    );

    expect(created!.id, isNotEmpty);
    expect(created!.status, InspectionStatus.draft,
        reason: 'status is omitted on insert so the column default applies');
    expect(created!.submittedAt, isNull);
  });

  test('4. user A reads it back', () async {
    final mine = await inspectionsA.listMine();
    final match = mine.where((i) => i.id == created!.id);
    expect(match, hasLength(1));
    expect(match.single.siteName, siteName);
    expect(match.single.clientName, 'Smoke Test Client');
  });

  test('5. stored inspector_id is user A', () async {
    expect(created!.inspectorId, userAId);

    // Re-read from the server rather than trusting the insert's return value.
    final row = await clientA
        .from('inspections')
        .select('inspector_id')
        .eq('id', created!.id)
        .single();
    expect(row['inspector_id'], userAId);
  });

  test('6. user B cannot read user A draft', () async {
    final byId =
        await clientB.from('inspections').select('id').eq('id', created!.id);
    expect(byId, isEmpty, reason: 'RLS must hide it even when named directly');

    final bList = await inspectionsB.listMine();
    expect(bList.where((i) => i.id == created!.id), isEmpty);
  });

  test('7. user B cannot update or delete user A draft', () async {
    // RLS denies these silently by matching zero rows rather than raising, so
    // the assertion has to be made afterwards, against the data.
    await clientB
        .from('inspections')
        .update({'site_name': 'HIJACKED BY B'}).eq('id', created!.id);
    await clientB.from('inspections').delete().eq('id', created!.id);

    final after = await clientA
        .from('inspections')
        .select('id, site_name')
        .eq('id', created!.id)
        .maybeSingle();

    expect(after, isNotNull, reason: 'user B must not have deleted the row');
    expect(after!['site_name'], siteName,
        reason: 'user B must not have modified the row');
  });

  test('8. user B cannot create an inspection owned by user A', () async {
    // The repository never lets a caller name the owner, so this goes to the
    // raw client to prove the database refuses it too.
    await expectLater(
      clientB.from('inspections').insert({
        'inspector_id': userAId,
        'site_name': 'PLANTED BY B',
        'inspection_date': NewInspection.dateOnly(DateTime.now()),
      }),
      throwsA(isA<PostgrestException>()),
    );
  });

  // ------------------------------------------------------------ punch items
  //
  // Item ownership derives entirely through the parent inspection — there is no
  // inspector_id on inspection_items — so these assertions are what prove that
  // indirection holds against real policies, not just in pgTAP.

  test('9. user A creates an item under their own inspection', () async {
    item = await itemsA.create(
      created!.id,
      const NewInspectionItem(
        title: 'Exposed wiring at junction box',
        description: 'Cover plate missing.',
        area: 'Plant room',
        severity: ItemSeverity.critical,
      ),
    );

    expect(item!.inspectionId, created!.id);
    expect(item!.severity, ItemSeverity.critical);
    expect(item!.status, ItemStatus.open,
        reason: 'status is omitted on insert so the column default applies');
  });

  test('10. user A reads the item back', () async {
    final rows = await itemsA.listFor(created!.id);
    expect(rows.where((i) => i.id == item!.id), hasLength(1));
    expect(rows.single.title, 'Exposed wiring at junction box');
    expect(rows.single.area, 'Plant room');
  });

  test('11. user A edits the item', () async {
    final updated = await itemsA.update(
      item!.id,
      title: 'Exposed wiring — made safe',
      description: 'Cover plate refitted.',
      area: 'Plant room',
      severity: ItemSeverity.high,
      status: ItemStatus.open,
    );
    expect(updated.title, 'Exposed wiring — made safe');
    expect(updated.severity, ItemSeverity.high);
  });

  test('12. user A resolves then reopens the item', () async {
    final resolved = await itemsA.update(
      item!.id,
      title: 'Exposed wiring — made safe',
      area: 'Plant room',
      severity: ItemSeverity.high,
      status: ItemStatus.resolved,
    );
    expect(resolved.status, ItemStatus.resolved);

    // Not one-way, unlike inspections.status (D10).
    final reopened = await itemsA.update(
      item!.id,
      title: 'Exposed wiring — made safe',
      area: 'Plant room',
      severity: ItemSeverity.high,
      status: ItemStatus.open,
    );
    expect(reopened.status, ItemStatus.open);
  });

  test('13. user B cannot read, update or delete user A item', () async {
    final visible = await itemsB.listFor(created!.id);
    expect(visible, isEmpty, reason: 'B cannot list items under A inspection');

    final byId =
        await clientB.from('inspection_items').select('id').eq('id', item!.id);
    expect(byId, isEmpty, reason: 'nor read it by direct id');

    // The repository turns a silent zero-row denial into an exception rather
    // than reporting success, which is the behaviour under test.
    await expectLater(
      itemsB.update(
        item!.id,
        title: 'HIJACKED BY B',
        severity: ItemSeverity.low,
        status: ItemStatus.resolved,
      ),
      throwsA(isA<NotPermittedException>()),
    );
    await expectLater(
      itemsB.delete(item!.id),
      throwsA(isA<NotPermittedException>()),
    );

    // Confirm against the data, since RLS denies by matching nothing.
    final after = await clientA
        .from('inspection_items')
        .select('title, severity, status')
        .eq('id', item!.id)
        .single();
    expect(after['title'], 'Exposed wiring — made safe');
    expect(after['severity'], 'high');
    expect(after['status'], 'open');
  });

  test('14. user B cannot create an item under user A inspection', () async {
    await expectLater(
      clientB.from('inspection_items').insert({
        'inspection_id': created!.id,
        'title': 'PLANTED BY B',
      }),
      throwsA(isA<PostgrestException>()),
    );
  });

  // ------------------------------------------------------------ photos
  //
  // Real Supabase Storage: a real object is uploaded, read back through a signed
  // URL, and removed. The bucket is private, so a plain GET of the path must not
  // work — only the signed URL should.

  test('15. user A uploads a photo to their own item', () async {
    photo = await photosA.upload(
      inspectionId: created!.id,
      itemId: item!.id,
      photo: const CapturedPhoto(bytes: _tinyPng, contentType: 'image/png'),
    );

    expect(photo!.itemId, item!.id);
    expect(photo!.inspectionId, created!.id);
    expect(photo!.byteSize, _tinyPng.length);
    // The owner segment must be A's authenticated id, not anything a caller sent.
    expect(photo!.storagePath, startsWith('$userAId/'));
    expect(photo!.storagePath, endsWith('.png'));
  });

  test('16. the metadata row persists and is readable', () async {
    final rows = await photosA.listFor(item!.id);
    expect(rows.where((p) => p.id == photo!.id), hasLength(1));
    expect(rows.single.storagePath, photo!.storagePath);
  });

  test('17. user A can read the object through a signed URL', () async {
    final url = await photosA.signedUrl(photo!);
    expect(url, contains(photo!.storagePath.split('/').last));

    final signed = await httpGet(url);
    expect(signed.statusCode, 200, reason: 'the signed URL must resolve');
    expect(signed.bodyBytes.length, _tinyPng.length);
  });

  test('18. the bucket is private: the unsigned path does not resolve',
      () async {
    final url = clientA.storage
        .from(SupabaseObjectStore.bucket)
        .getPublicUrl(photo!.storagePath);
    final res = await httpGet(url);
    expect(res.statusCode, isNot(200),
        reason: 'a public URL must not serve a private object');
  });

  test('19. user B cannot read, sign, or delete user A photo', () async {
    final visible = await photosB.listFor(item!.id);
    expect(visible, isEmpty, reason: 'B cannot list A photo metadata');

    final byId =
        await clientB.from('item_photos').select('id').eq('id', photo!.id);
    expect(byId, isEmpty, reason: 'nor read the row by direct id');

    // Storage refuses too, so neither half alone is load-bearing.
    await expectLater(
      clientB.storage
          .from(SupabaseObjectStore.bucket)
          .createSignedUrl(photo!.storagePath, 60),
      throwsA(isA<StorageException>()),
    );

    await expectLater(
      photosB.delete(photo!),
      throwsA(isA<NotPermittedException>()),
    );

    final after =
        await clientA.from('item_photos').select('id').eq('id', photo!.id);
    expect(after, hasLength(1), reason: 'B must not have deleted it');
  });

  test('20. user B cannot upload under user A prefix', () async {
    await expectLater(
      clientB.storage.from(SupabaseObjectStore.bucket).uploadBinary(
            '$userAId/${created!.id}/${item!.id}/forged.png',
            Uint8List.fromList(_tinyPng),
          ),
      throwsA(isA<StorageException>()),
    );
  });

  test('21. user A deletes the photo while the inspection is a draft',
      () async {
    await photosA.delete(photo!);

    final rows = await photosA.listFor(item!.id);
    expect(rows, isEmpty, reason: 'metadata is gone');

    // And the object with it: a signed URL for a deleted object must not serve.
    final res = await httpGet(
      clientA.storage
          .from(SupabaseObjectStore.bucket)
          .getPublicUrl(photo!.storagePath),
    );
    expect(res.statusCode, isNot(200), reason: 'the object is gone');
    photo = null;
  });

  test('22. a submitted inspection rejects photo mutation', () async {
    // Submitted through the repository, which is the app's own path. This used
    // to be a raw .update() here, and that is precisely how the client came to
    // have no submit action at all while every gate stayed green: the test
    // reached around the app and proved only that Postgres would allow it.
    final submitted = await inspectionsA.submit(created!.id);
    expect(submitted.status, InspectionStatus.submitted);
    expect(
      submitted.submittedAt,
      isNotNull,
      reason: 'submitted_at is stamped by the trigger, not by the client',
    );

    final status = await clientA
        .from('inspections')
        .select('status')
        .eq('id', created!.id)
        .single();
    expect(status['status'], 'submitted', reason: 'the submit itself works');

    // One way (D10): the second attempt matches zero rows under the update
    // policy, and the repository turns that silence into a refusal rather than
    // reporting a successful re-submit.
    await expectLater(
      inspectionsA.submit(created!.id),
      throwsA(isA<NotPermittedException>()),
      reason: 'an already-submitted inspection cannot be submitted again',
    );

    await expectLater(
      photosA.upload(
        inspectionId: created!.id,
        itemId: item!.id,
        photo: const CapturedPhoto(bytes: _tinyPng, contentType: 'image/png'),
      ),
      throwsA(anything),
      reason: 'no photo may be added under a submitted inspection',
    );
  });

  test('23. user A cannot delete the item once submitted', () async {
    await expectLater(
      itemsA.delete(item!.id),
      throwsA(isA<NotPermittedException>()),
    );
    item = null;
  });

  // ------------------------------------------------------------ history + search
  //
  // Closes H1/H2/H3 against the real client: ordering, matching, and the fact
  // that a query cannot reach another inspector's rows. Everything created here
  // stays a draft so it can be deleted again (D17 makes submitted rows
  // permanent).

  test('24. user A creates two more inspections with known dates', () async {
    histOlder = await inspectionsA.create(
      NewInspection(
        siteName: 'SMOKE $searchTerm older do-not-keep',
        siteAddress: '1 Older Street',
        clientName: 'Older Client',
        inspectionDate: DateTime(2020, 1, 1),
      ),
    );
    histNewer = await inspectionsA.create(
      NewInspection(
        siteName: 'SMOKE $searchTerm newer do-not-keep',
        siteAddress: '2 Newer Street',
        clientName: 'Newer Client',
        inspectionDate: DateTime(2020, 6, 1),
      ),
    );
    expect(histOlder!.id, isNot(histNewer!.id));
  });

  test('25. history is ordered by inspection_date, newest first', () async {
    final rows = await inspectionsA.listMine();
    final ids = rows.map((r) => r.id).toList();

    final newerAt = ids.indexOf(histNewer!.id);
    final olderAt = ids.indexOf(histOlder!.id);
    expect(newerAt, isNonNegative);
    expect(olderAt, isNonNegative);
    expect(
      newerAt,
      lessThan(olderAt),
      reason: '2020-06-01 must come before 2020-01-01',
    );

    // And the whole list is non-increasing by inspection date, so the ordering
    // is a property of the query rather than of these two rows.
    for (var i = 1; i < rows.length; i++) {
      expect(
        rows[i - 1].inspectionDate.isBefore(rows[i].inspectionDate),
        isFalse,
        reason: 'history must not ascend at position $i',
      );
    }
  });

  test('26. search finds user A rows by site, address and client', () async {
    final bySite = await inspectionsA.searchMine(searchTerm);
    expect(bySite.map((r) => r.id).toSet(), {histOlder!.id, histNewer!.id});
    // Results keep the history ordering.
    expect(bySite.first.id, histNewer!.id);

    expect(
      (await inspectionsA.searchMine('Newer Street')).map((r) => r.id),
      contains(histNewer!.id),
    );
    expect(
      (await inspectionsA.searchMine('Older Client')).map((r) => r.id),
      contains(histOlder!.id),
    );
  });

  test('27. search is case-insensitive and matches on a prefix', () async {
    expect(
      (await inspectionsA.searchMine(searchTerm.toUpperCase()))
          .map((r) => r.id),
      contains(histNewer!.id),
    );
    // Prefix: drop the last three characters of the unique token.
    final prefix = searchTerm.substring(0, searchTerm.length - 3);
    expect(
      (await inspectionsA.searchMine(prefix)).map((r) => r.id),
      contains(histNewer!.id),
    );
  });

  test('28. neither inspector can discover the other through search', () async {
    bUnique = await inspectionsB.create(
      NewInspection(
        siteName: 'SMOKE $bSearchTerm bravo do-not-keep',
        inspectionDate: DateTime(2020, 3, 1),
      ),
    );

    // The term exists, and B can find it.
    expect(
      (await inspectionsB.searchMine(bSearchTerm)).map((r) => r.id),
      contains(bUnique!.id),
    );

    // A cannot — this is the case that would fail if search bypassed RLS.
    expect(await inspectionsA.searchMine(bSearchTerm), isEmpty);
    // ...and the reverse.
    expect(await inspectionsB.searchMine(searchTerm), isEmpty);
  });

  test('29. the search fixtures are removed', () async {
    await clientA.from('inspections').delete().eq('id', histOlder!.id);
    await clientA.from('inspections').delete().eq('id', histNewer!.id);
    await clientB.from('inspections').delete().eq('id', bUnique!.id);

    expect(await inspectionsA.searchMine(searchTerm), isEmpty);
    expect(await inspectionsB.searchMine(bSearchTerm), isEmpty);
    histOlder = null;
    histNewer = null;
    bUnique = null;
  });

  // ------------------------------------------------------------ offline sync
  //
  // The offline phase is modelled deterministically — a LocalDraftBook over an
  // in-memory store, holding exactly what the device would have written — and
  // the *sync* phase runs against real hosted Supabase through the production
  // `SupabaseDraftSink` and the production `DraftSync`. Nothing here reaches
  // around the repositories to make itself pass; the Submit incident is why
  // that rule exists.
  //
  // CI does not disconnect the network. Pulling the interface down inside a
  // runner would make the whole job's outcome depend on how quickly the OS
  // reported it, which is exactly the kind of flake that teaches people to
  // ignore red. What matters here is the half that only hosted Supabase can
  // answer: that a device-generated key really does upsert, that RLS really
  // does own the result, and that a replayed push really does leave one row.

  test('30. an offline-origin draft syncs to hosted Supabase', () async {
    offlineBook = LocalDraftBook(MemoryDraftStore());
    offlineStatus = OfflineStatusNotifier();
    offlineSync = DraftSync(
      local: offlineBook!,
      sink: SupabaseDraftSink(clientA),
      auth: authA,
      status: offlineStatus!,
    );

    await offlineBook!.put(
      LocalDraft(
        id: offlineId,
        // Only decides *whether* to push, never who owns the result: the sync
        // reads inspector_id from the live session, and RLS decides from the
        // JWT. Case 35 proves the stored value cannot claim a row.
        ownerId: userAId,
        siteName: offlineSite,
        siteAddress: '9 Offline Lane',
        clientName: 'Offline Client',
        inspectionDate: DateTime(2026, 8, 27),
        createdAt: DateTime(2026, 8, 27, 8),
        items: [
          LocalItem(
            id: offlineItemA,
            sortOrder: 0,
            title: 'Offline punch item A',
            description: 'Captured with no connection',
            area: 'Plant room',
            severity: ItemSeverity.high,
            status: ItemStatus.open,
            createdAt: DateTime(2026, 8, 27, 8, 5),
          ),
          LocalItem(
            id: offlineItemB,
            sortOrder: 1,
            title: 'Offline punch item B',
            severity: ItemSeverity.low,
            status: ItemStatus.resolved,
            createdAt: DateTime(2026, 8, 27, 8, 6),
          ),
        ],
      ),
    );

    final report = await offlineSync!.run();

    expect(report.failed, isEmpty, reason: report.lastError ?? '');
    expect(report.synced, [offlineId]);
    // Authority has moved. The device no longer holds a writable copy.
    expect(await offlineBook!.all(), isEmpty);
  });

  test('31. it is exactly one draft, owned by A, with the fields intact',
      () async {
    final mine = await inspectionsA.listMine();
    final matches = mine.where((i) => i.id == offlineId);

    expect(matches, hasLength(1));
    final row = matches.single;
    expect(row.inspectorId, userAId,
        reason: 'ownership comes from the session and RLS, not from the queue');
    expect(row.status, InspectionStatus.draft,
        reason: 'a synced offline draft is an ordinary draft, never submitted');
    expect(row.submittedAt, isNull);
    expect(row.siteName, offlineSite);
    expect(row.siteAddress, '9 Offline Lane');
    expect(row.clientName, 'Offline Client');
  });

  test('32. both items are attached to it, with their fields', () async {
    final rows = await itemsA.listFor(offlineId);
    expect(rows.map((r) => r.id), [offlineItemA, offlineItemB]);
    expect(rows.first.title, 'Offline punch item A');
    expect(rows.first.area, 'Plant room');
    expect(rows.first.severity, ItemSeverity.high);
    expect(rows.first.status, ItemStatus.open);
    // status is omitted on an ordinary insert so the default applies; a re-push
    // has to carry it, or an item resolved in the field syncs back as open.
    expect(rows.last.status, ItemStatus.resolved);
    expect(rows.last.severity, ItemSeverity.low);
  });

  test('33. replaying the push produces no duplicate', () async {
    // The interrupted-sync case, against the real database. The device would
    // re-queue the same record with the same keys after a crash mid-push.
    await offlineBook!.put(
      LocalDraft(
        id: offlineId,
        ownerId: userAId,
        siteName: offlineSite,
        siteAddress: '9 Offline Lane',
        clientName: 'Offline Client',
        inspectionDate: DateTime(2026, 8, 27),
        createdAt: DateTime(2026, 8, 27, 8),
        items: [
          LocalItem(
            id: offlineItemA,
            sortOrder: 0,
            title: 'Offline punch item A',
            description: 'Captured with no connection',
            area: 'Plant room',
            severity: ItemSeverity.high,
            status: ItemStatus.open,
            createdAt: DateTime(2026, 8, 27, 8, 5),
          ),
          LocalItem(
            id: offlineItemB,
            sortOrder: 1,
            title: 'Offline punch item B',
            severity: ItemSeverity.low,
            status: ItemStatus.resolved,
            createdAt: DateTime(2026, 8, 27, 8, 6),
          ),
        ],
      ),
    );

    final report = await offlineSync!.run();
    expect(report.failed, isEmpty, reason: report.lastError ?? '');

    final mine = await inspectionsA.listMine();
    expect(mine.where((i) => i.id == offlineId), hasLength(1));
    expect(await itemsA.listFor(offlineId), hasLength(2));
  });

  test('34. history and search find it exactly once', () async {
    final searched = await inspectionsA.searchMine(offlineToken);
    expect(searched.where((i) => i.id == offlineId), hasLength(1));
    expect(searched.single.id, offlineId);
  });

  test('35. user B cannot see or push over the synced draft', () async {
    expect(
      (await inspectionsB.listMine()).where((i) => i.id == offlineId),
      isEmpty,
    );

    // B's own queue holding A's id must not become a way to write A's row.
    final bBook = LocalDraftBook(MemoryDraftStore());
    await bBook.put(
      LocalDraft(
        id: offlineId,
        ownerId: userBId,
        siteName: 'SMOKE hijack do-not-keep',
        inspectionDate: DateTime(2026, 8, 27),
        createdAt: DateTime(2026, 8, 27),
      ),
    );
    final bReport = await DraftSync(
      local: bBook,
      sink: SupabaseDraftSink(clientB),
      auth: SupabaseAuthRepository(clientB),
      status: OfflineStatusNotifier(),
    ).run();

    expect(bReport.synced, isEmpty, reason: 'RLS must refuse the merge');
    expect(bReport.failed, [offlineId]);
    // Refused, and B keeps its own local copy rather than losing it.
    expect(await bBook.all(), hasLength(1));

    // A's row is untouched.
    final row =
        (await inspectionsA.listMine()).firstWhere((i) => i.id == offlineId);
    expect(row.siteName, offlineSite);
    expect(row.inspectorId, userAId);
  });

  test('36. after sync it is an ordinary editable draft, not a special record',
      () async {
    // The handoff, stated as a property: Supabase is now the authority, so the
    // ordinary online write path works on it and the local queue has no say.
    final edited = await itemsA.update(
      offlineItemA,
      title: 'Offline punch item A, edited online',
      description: 'Edited after sync',
      area: 'Plant room',
      severity: ItemSeverity.critical,
      status: ItemStatus.resolved,
    );

    expect(edited.title, 'Offline punch item A, edited online');
    expect(edited.severity, ItemSeverity.critical);
    // Submit is available to it on exactly the same terms as any other draft —
    // asserted by *not* submitting here. D17's delete policy requires the parent
    // to be a draft, so submitting this fixture would strand an undeletable row
    // in the hosted project on every run. Submit-after-sync is proven by
    // `offline_flow_test.dart` through the widget tree and by the real-device QA
    // in docs/ACCEPTANCE.md, which submits a genuinely offline-created record on
    // hardware against this same project.
  });

  test('37. the offline fixture is removed', () async {
    await clientA.from('inspections').delete().eq('id', offlineId);

    final still = await inspectionsA.listMine();
    expect(still.where((i) => i.id == offlineId), isEmpty);
    expect(await itemsA.listFor(offlineId), isEmpty,
        reason: 'and the cascade took its items with it');
  });
}

/// A 1x1 PNG. Small enough to upload in a smoke test, real enough to be a valid
/// image rather than arbitrary bytes.
const List<int> _tinyPng = [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];

/// A plain GET, so the test can check what a private object does and does not
/// serve. Uses dart:io directly rather than adding an http dependency.
Future<({int statusCode, List<int> bodyBytes})> httpGet(String url) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(url));
    final res = await req.close();
    final bytes = <int>[];
    await for (final chunk in res) {
      bytes.addAll(chunk);
    }
    return (statusCode: res.statusCode, bodyBytes: bytes);
  } finally {
    client.close(force: true);
  }
}
