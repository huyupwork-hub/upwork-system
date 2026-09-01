import 'dart:io';

import 'package:fieldproof/src/data/models.dart';
import 'package:fieldproof/src/data/repositories.dart';
import 'package:fieldproof/src/offline/draft_store.dart';
import 'package:fieldproof/src/offline/draft_sync.dart';
import 'package:fieldproof/src/offline/local_draft.dart';
import 'package:fieldproof/src/offline/offline_repositories.dart';
import 'package:fieldproof/src/offline/offline_status.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'fakes.dart';

/// Offline-origin drafts: capture, survival, search, and the one-way handoff to
/// Supabase.
///
/// Nothing here re-implements RLS, and nothing here is evidence about RLS. The
/// database remains the security authority and is proven by pgTAP and the hosted
/// smoke. What these tests own is the client contract: that a draft is kept when
/// the server cannot be reached, that it is not kept when the server *refuses*,
/// that a retried push cannot duplicate, and that local state is never retired
/// on anything weaker than a read-back.
void main() {
  /// What being offline actually looks like to the client: no response.
  ///
  /// Deliberately a real transport exception rather than a bare `Exception`,
  /// because the code under test is required to tell this apart from a refusal
  /// and a test using a generic error would not exercise that decision at all.
  const offline = SocketException('Network is unreachable');

  /// What a refusal looks like: the server answered.
  const refused = PostgrestException(
    message: 'new row violates row-level security policy',
    code: '42501',
  );

  late FakeAuthRepository auth;
  late FakeInspectionsRepository remoteInspections;
  late FakeInspectionItemsRepository remoteItems;
  late MemoryDraftStore store;
  late LocalDraftBook book;
  late OfflineStatusNotifier status;
  late OfflineFirstInspectionsRepository inspections;
  late OfflineFirstInspectionItemsRepository items;
  late FakeDraftSink sink;
  late DraftSync sync;

  /// Rebuilds every object that holds state, over the same durable bytes.
  ///
  /// This is how "survives process death" is proven rather than asserted: the
  /// only thing carried across is the store's contents.
  void build() {
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
  }

  setUp(() {
    auth = FakeAuthRepository(initialUserId: 'user-1');
    remoteInspections = FakeInspectionsRepository();
    remoteItems = FakeInspectionItemsRepository();
    store = MemoryDraftStore();
    status = OfflineStatusNotifier();
    sink = FakeDraftSink();
    build();
  });

  tearDown(() => auth.dispose());

  NewInspection northgate() => NewInspection(
        siteName: 'Northgate Retail Park',
        siteAddress: '4 Northgate Way, Leeds',
        clientName: 'Cavendish Estates',
        inspectionDate: DateTime(2026, 8, 20),
      );

  /// Losing the network fails reads as well as writes.
  ///
  /// Setting only the write would leave history quietly succeeding, which is
  /// not a state a device can actually be in — and it would let a test claim
  /// the app behaves correctly offline while the server was still answering
  /// half its questions.
  void goOffline() {
    remoteInspections.failWith = offline;
    remoteInspections.readFailsWith = offline;
  }

  void goOnline() {
    remoteInspections.failWith = null;
    remoteInspections.readFailsWith = null;
  }

  Future<Inspection> createOffline() {
    goOffline();
    return inspections.create(northgate());
  }

  group('creating a draft while the server is unreachable', () {
    test('the draft is kept, and comes back as an ordinary Draft', () async {
      final created = await createOffline();

      expect(created.siteName, 'Northgate Retail Park');
      expect(created.status, InspectionStatus.draft);
      expect(created.inspectorId, 'user-1');
      expect(await book.all(), hasLength(1));
      expect(status.value.remoteUnavailable, isTrue);
      expect(status.value.pendingIds, {created.id});
    });

    test('a refusal is not an outage: it is not queued, it is raised',
        () async {
      // The distinction the queue's honesty rests on. A draft the database has
      // already rejected would sit here failing forever while the banner implied
      // it was merely waiting for signal.
      remoteInspections.failWith = refused;

      await expectLater(
        inspections.create(northgate()),
        throwsA(isA<PostgrestException>()),
      );
      expect(await book.all(), isEmpty);
    });

    test('creation requires an authenticated session', () async {
      // §3: no anonymous offline inspections. Ownership assigned later is
      // ownership guessed later.
      await auth.signOut();
      goOffline();

      await expectLater(
        inspections.create(northgate()),
        throwsA(isA<NotSignedInException>()),
      );
      expect(await book.all(), isEmpty);
    });

    test(
        'the id is minted before the attempt, so a lost response cannot '
        'duplicate', () async {
      // The insert reached Postgres; only the response was lost. The local
      // record therefore has to carry the primary key the server already holds.
      final created = await createOffline();
      final payload = remoteInspections.insertPayloads.single;

      expect(payload['id'], created.id);
      expect((await book.all()).single.id, created.id);
    });

    test('an online create still works and queues nothing', () async {
      final created = await inspections.create(northgate());

      expect(remoteInspections.rows.single.id, created.id);
      expect(await book.all(), isEmpty);
      expect(status.value.hasPending, isFalse);
      expect(status.value.remoteUnavailable, isFalse);
    });
  });

  group('surviving process death', () {
    test('the draft is still there after everything is reconstructed',
        () async {
      final created = await createOffline();
      build();

      final draft = (await book.all()).single;
      expect(draft.id, created.id);
      expect(draft.siteName, 'Northgate Retail Park');
    });

    test('items added offline survive reconstruction', () async {
      final created = await createOffline();
      await items.create(
        created.id,
        const NewInspectionItem(
          title: 'Cracked pane',
          description: 'Hairline crack',
          area: 'Stairwell',
          severity: ItemSeverity.high,
        ),
      );
      build();

      final rows = await items.listFor(created.id);
      expect(rows, hasLength(1));
      expect(rows.single.title, 'Cracked pane');
      expect(rows.single.area, 'Stairwell');
      expect(rows.single.severity, ItemSeverity.high);
      expect(rows.single.status, ItemStatus.open);
      expect(rows.single.inspectionId, created.id);
    });

    test('an edit survives reconstruction', () async {
      final created = await createOffline();
      final item = await items.create(
        created.id,
        const NewInspectionItem(title: 'Cracked pane'),
      );
      await items.update(
        item.id,
        title: 'Cracked pane, north elevation',
        description: 'Widened since last visit',
        area: 'Stairwell',
        severity: ItemSeverity.critical,
        status: ItemStatus.resolved,
      );
      build();

      final row = (await items.listFor(created.id)).single;
      expect(row.title, 'Cracked pane, north elevation');
      expect(row.description, 'Widened since last visit');
      expect(row.severity, ItemSeverity.critical);
      expect(row.status, ItemStatus.resolved);
    });

    test('a delete survives reconstruction', () async {
      final created = await createOffline();
      final first = await items.create(
        created.id,
        const NewInspectionItem(title: 'Cracked pane'),
      );
      await items.create(
        created.id,
        const NewInspectionItem(title: 'Loose handrail'),
      );
      await items.delete(first.id);
      build();

      final rows = await items.listFor(created.id);
      expect(rows.map((r) => r.title), ['Loose handrail']);
    });

    test('items are appended in order and keep it across reconstruction',
        () async {
      final created = await createOffline();
      for (final title in ['first', 'second', 'third']) {
        await items.create(created.id, NewInspectionItem(title: title));
      }
      build();

      final rows = await items.listFor(created.id);
      expect(rows.map((r) => r.title), ['first', 'second', 'third']);
      expect(rows.map((r) => r.sortOrder), [0, 1, 2]);
    });
  });

  group('history and search over both sources', () {
    setUp(() {
      remoteInspections.rows.add(
        Inspection(
          id: 'server-1',
          inspectorId: 'user-1',
          siteName: 'Harbour View Apartments',
          siteAddress: '12 Dock Road, Bristol',
          clientName: 'Meridian Property Group',
          inspectionDate: DateTime(2026, 8, 10),
          status: InspectionStatus.submitted,
        ),
      );
    });

    test('a local draft appears in history alongside server rows', () async {
      final created = await createOffline();
      goOnline();

      final rows = await inspections.listMine();
      expect(rows.map((r) => r.id), [created.id, 'server-1']);
    });

    test(
        'with the server unreachable, history is the local drafts and the '
        'status says so', () async {
      final created = await createOffline();

      final rows = await inspections.listMine();
      expect(rows.map((r) => r.id), [created.id]);
      expect(status.value.remoteUnavailable, isTrue);
    });

    test('search finds a local draft by site', () async {
      final created = await createOffline();
      expect(
        (await inspections.searchMine('northgate')).map((r) => r.id),
        [created.id],
      );
    });

    test('search finds a local draft by address', () async {
      final created = await createOffline();
      expect(
        (await inspections.searchMine('leeds')).map((r) => r.id),
        [created.id],
      );
    });

    test('search finds a local draft by client', () async {
      final created = await createOffline();
      expect(
        (await inspections.searchMine('cavendish')).map((r) => r.id),
        [created.id],
      );
    });

    test('local search is prefix matching, exactly as the tsquery is',
        () async {
      // "north" finds "Northgate" and "gate" does not, because `term:*` against
      // the stored vector means a prefix. A local draft that matched on infix
      // would make one search box behave like two products (D22).
      final created = await createOffline();
      expect((await inspections.searchMine('north')).map((r) => r.id),
          [created.id]);
      expect(await inspections.searchMine('gate'), isEmpty);
    });

    test('a non-matching query excludes the local draft', () async {
      await createOffline();
      expect(await inspections.searchMine('zzzznothing'), isEmpty);
    });

    test('another inspector signing in on the same handset sees none of it',
        () async {
      await createOffline();
      await auth.signIn(email: 'a@example.com', password: 'correct-horse');
      goOnline();

      final rows = await inspections.listMine();
      expect(rows.map((r) => r.id), ['server-1']);
    });

    test('the merged history keeps the accepted total order', () async {
      goOffline();
      final older = await inspections.create(
        NewInspection(
          siteName: 'Older',
          inspectionDate: DateTime(2026, 8, 1),
        ),
      );
      final newer = await inspections.create(
        NewInspection(
          siteName: 'Newer',
          inspectionDate: DateTime(2026, 8, 25),
        ),
      );
      goOnline();

      final rows = await inspections.listMine();
      expect(rows.map((r) => r.id), [newer.id, 'server-1', older.id]);
    });
  });

  group('submission stays a server transition', () {
    test('an unsynced draft cannot be submitted', () async {
      final created = await createOffline();

      await expectLater(
        inspections.submit(created.id),
        throwsA(isA<DraftNotSyncedException>()),
      );
      // Still a draft, still local, still the inspector's to finish.
      expect((await book.all()).single.id, created.id);
      expect(
        (await inspections.listMine()).single.status,
        InspectionStatus.draft,
      );
    });

    test('after syncing, the ordinary Submit path works', () async {
      final created = await createOffline();
      await items.create(created.id, const NewInspectionItem(title: 'Pane'));

      // The row the server now holds, which the online repository will submit.
      goOnline();
      await sync.run();
      remoteInspections.rows.add(
        Inspection(
          id: created.id,
          inspectorId: 'user-1',
          siteName: 'Northgate Retail Park',
          inspectionDate: DateTime(2026, 8, 20),
          status: InspectionStatus.draft,
        ),
      );

      final submitted = await inspections.submit(created.id);
      expect(submitted.status, InspectionStatus.submitted);
      expect(submitted.submittedAt, isNotNull);
      expect(remoteInspections.submitted, [created.id]);
    });
  });

  group('sync', () {
    test('a first run creates exactly one inspection, owned by the session',
        () async {
      final created = await createOffline();

      final report = await sync.run();

      expect(report.synced, [created.id]);
      expect(report.isClean, isTrue);
      expect(sink.inspections, hasLength(1));
      final row = sink.inspections[created.id]!;
      expect(row['inspector_id'], 'user-1');
      expect(row['site_name'], 'Northgate Retail Park');
    });

    test(
        'inspector_id comes from the live session, never from the stored '
        'record', () async {
      final created = await createOffline();
      // A tampered or stale local record must not decide who owns the row. RLS
      // would refuse it anyway; this proves the app never even forms the claim.
      await book.put((await book.byId(created.id))!);
      await sync.run();

      expect(sink.inspections[created.id]!['inspector_id'], 'user-1');
    });

    test('children are written after the parent', () async {
      final created = await createOffline();
      await items.create(created.id, const NewInspectionItem(title: 'Pane'));

      await sync.run();

      expect(
        sink.calls.indexOf('putInspection'),
        lessThan(sink.calls.indexOf('putItems')),
      );
    });

    test('items land under the right inspection', () async {
      final first = await createOffline();
      final second = await inspections.create(
        NewInspection(siteName: 'Second', inspectionDate: DateTime(2026, 8, 2)),
      );
      final a = await items.create(
        first.id,
        const NewInspectionItem(title: 'A'),
      );
      final b = await items.create(
        second.id,
        const NewInspectionItem(title: 'B'),
      );

      await sync.run();

      expect(sink.items[a.id]!['inspection_id'], first.id);
      expect(sink.items[b.id]!['inspection_id'], second.id);
      expect(await sink.readItemIds(first.id), {a.id});
      expect(await sink.readItemIds(second.id), {b.id});
    });

    test('a successful sync retires the local record', () async {
      await createOffline();
      await sync.run();

      expect(await book.all(), isEmpty);
      expect(status.value.hasPending, isFalse);
      // And it stays retired across a restart — the handoff is a deletion, not
      // a flag that a later load could misread.
      build();
      expect(await book.all(), isEmpty);
    });

    test('after sync the row is represented exactly once', () async {
      final created = await createOffline();
      await sync.run();

      goOnline();
      remoteInspections.rows.add(
        Inspection(
          id: created.id,
          inspectorId: 'user-1',
          siteName: 'Northgate Retail Park',
          inspectionDate: DateTime(2026, 8, 20),
          status: InspectionStatus.draft,
        ),
      );

      final rows = await inspections.listMine();
      expect(rows.where((r) => r.id == created.id), hasLength(1));
    });

    test('running twice does not duplicate anything', () async {
      final created = await createOffline();
      await items.create(created.id, const NewInspectionItem(title: 'Pane'));

      await sync.run();
      await sync.run();

      expect(sink.inspections, hasLength(1));
      expect(sink.items, hasLength(1));
      expect(await sink.readItemIds(created.id), hasLength(1));
    });

    test('a retry after a failed item push does not duplicate the parent',
        () async {
      // The interrupted-sync case: the inspection landed, the items did not.
      // The retry upserts the same keys, so the server ends up with one of each.
      final created = await createOffline();
      await items.create(created.id, const NewInspectionItem(title: 'Pane'));
      sink.failItems = offline;

      final first = await sync.run();
      expect(first.failed, [created.id]);
      expect(sink.inspections, hasLength(1));
      expect(sink.items, isEmpty);

      sink.failItems = null;
      final second = await sync.run();

      expect(second.synced, [created.id]);
      expect(sink.inspections, hasLength(1));
      expect(sink.items, hasLength(1));
    });

    test('a failed sync keeps the draft and its items, with the reason',
        () async {
      final created = await createOffline();
      await items.create(created.id, const NewInspectionItem(title: 'Pane'));
      sink.failInspection = offline;

      final report = await sync.run();

      expect(report.failed, [created.id]);
      final kept = (await book.all()).single;
      expect(kept.id, created.id);
      expect(kept.items, hasLength(1));
      expect(kept.state, DraftSyncState.localOnly);
      expect(kept.lastError, contains('Network is unreachable'));
      expect(status.value.lastError, isNotNull);
      expect(status.value.remoteUnavailable, isTrue);
    });

    test('the draft survives a failure across reconstruction too', () async {
      final created = await createOffline();
      sink.failInspection = offline;
      await sync.run();
      build();

      expect((await book.all()).single.id, created.id);
    });

    test('no exception is not evidence: an unverifiable write is a failure',
        () async {
      // The write "succeeded" and the row is not there. RLS refuses UPDATE and
      // DELETE by matching zero rows *silently*, so the absence of an error
      // proves nothing — only a read-back does.
      final created = await createOffline();
      sink.inspectionReadsAsMissing = true;

      final report = await sync.run();

      expect(report.failed, [created.id]);
      expect((await book.all()).single.id, created.id);
      expect(report.lastError, contains('did not persist'));
    });

    test('an item that did not persist keeps the whole draft local', () async {
      final created = await createOffline();
      await items.create(created.id, const NewInspectionItem(title: 'Pane'));

      // The upsert reports success and writes nothing — the shape a silent
      // refusal takes. Only the read-back catches it.
      final guarded = DraftSync(
        local: book,
        sink: _SwallowingItemSink(sink),
        auth: auth,
        status: status,
      );

      final report = await guarded.run();

      expect(report.failed, [created.id]);
      expect(report.lastError, contains('did not persist'));
      expect((await book.all()).single.items, hasLength(1));
    });

    test(
        'an item deleted locally after a partial sync is removed from the '
        'server', () async {
      final created = await createOffline();
      final doomed = await items.create(
        created.id,
        const NewInspectionItem(title: 'A'),
      );
      await items.create(created.id, const NewInspectionItem(title: 'B'));

      // The first attempt writes both items and then fails, so the draft stays
      // local — and stays editable, which is the whole point of it being local.
      final first = await DraftSync(
        local: book,
        sink: _FailAfterItemsSink(sink, error: offline),
        auth: auth,
        status: status,
      ).run();
      expect(first.failed, [created.id]);
      expect(sink.items, hasLength(2));

      // The inspector removes one before the draft has finished syncing.
      // Without the prune the server would keep a punch item that no longer
      // exists, and "synced" would describe a record the device does not have.
      await items.delete(doomed.id);
      final second = await sync.run();

      expect(second.synced, [created.id]);
      expect(await sink.readItemIds(created.id), hasLength(1));
      expect(sink.items.containsKey(doomed.id), isFalse);
    });

    test('with no session, nothing is pushed and nothing is lost', () async {
      await createOffline();
      await auth.signOut();

      final report = await sync.run();

      expect(report.synced, isEmpty);
      expect(report.failed, isEmpty);
      expect(sink.inspections, isEmpty);
      expect(await book.all(), hasLength(1));
    });

    test('another inspector session does not push the first inspector\'s work',
        () async {
      await createOffline();
      await auth.signIn(email: 'a@example.com', password: 'correct-horse');

      final report = await sync.run();

      expect(report.synced, isEmpty);
      expect(sink.inspections, isEmpty);
      expect(await book.all(), hasLength(1));
    });

    test('one draft failing does not stop the others', () async {
      goOffline();
      final first = await inspections.create(
        NewInspection(siteName: 'First', inspectionDate: DateTime(2026, 8, 1)),
      );
      final second = await inspections.create(
        NewInspection(siteName: 'Second', inspectionDate: DateTime(2026, 8, 2)),
      );

      // Only the second draft's write fails, so the first must still land.
      final selective = _FailOneSink(sink, failFor: second.id, error: offline);
      final report = await DraftSync(
        local: book,
        sink: selective,
        auth: auth,
        status: status,
      ).run();

      expect(report.synced, [first.id]);
      expect(report.failed, [second.id]);
      expect((await book.all()).map((d) => d.id), [second.id]);
    });

    test('a clean run clears the last error', () async {
      await createOffline();
      sink.failInspection = offline;
      await sync.run();
      expect(status.value.lastError, isNotNull);

      sink.failInspection = null;
      await sync.run();

      // A stale message must not outlive the problem it described.
      expect(status.value.lastError, isNull);
      expect(status.value.remoteUnavailable, isFalse);
    });
  });

  group('server-backed records are never edited from the queue', () {
    test('items on a server-backed inspection go to the remote repository',
        () async {
      remoteItems.rows.add(
        const InspectionItem(
          id: 'server-item',
          inspectionId: 'server-1',
          sortOrder: 0,
          title: 'Existing',
          severity: ItemSeverity.low,
          status: ItemStatus.open,
        ),
      );

      await items.update(
        'server-item',
        title: 'Edited online',
        severity: ItemSeverity.high,
        status: ItemStatus.open,
      );

      expect(remoteItems.rows.single.title, 'Edited online');
      expect(await book.all(), isEmpty);
    });

    test('a failed edit of a server-backed item is raised, not queued',
        () async {
      // §14: no offline mutation of rows that exist on the server. Queuing this
      // would create exactly the conflict semantics this slice avoids.
      remoteItems.failWith = offline;

      await expectLater(
        items.update(
          'server-item',
          title: 'x',
          severity: ItemSeverity.low,
          status: ItemStatus.open,
        ),
        throwsA(isA<SocketException>()),
      );
      expect(await book.all(), isEmpty);
    });
  });

  group('an unreadable local store', () {
    /// A store whose bytes will not decode, wired into the ordinary objects.
    void corrupt() {
      store = MemoryDraftStore('not json at all');
      build();
    }

    test('history refuses rather than showing the server rows alone', () async {
      // Returning just the server-backed rows would report the queue as
      // healthy: the inspector would see a list that looks complete, with their
      // unsynced work silently missing from it.
      corrupt();
      remoteInspections.rows.add(
        Inspection(
          id: 'server-1',
          inspectorId: 'user-1',
          siteName: 'Harbour View Apartments',
          inspectionDate: DateTime(2026, 8, 10),
          status: InspectionStatus.draft,
        ),
      );

      await expectLater(
        inspections.listMine(),
        throwsA(isA<DraftStoreUnreadableException>()),
      );
      await expectLater(
        inspections.searchMine('harbour'),
        throwsA(isA<DraftStoreUnreadableException>()),
      );
    });

    test('creating a draft offline does not overwrite the unreadable bytes',
        () async {
      corrupt();
      goOffline();

      await expectLater(
        inspections.create(northgate()),
        throwsA(isA<DraftStoreUnreadableException>()),
      );
      expect(await store.read(), 'not json at all');
    });

    test('sync pushes nothing, reports the failure, and is not clean',
        () async {
      corrupt();

      final report = await sync.run();

      // Never throws out of a lifecycle callback, but never claims success
      // either — and `failed` being empty must not read as "all good".
      expect(report.synced, isEmpty);
      expect(report.failed, isEmpty);
      expect(report.isClean, isFalse);
      expect(report.lastError, contains('could not be read'));
      expect(status.value.lastError, contains('could not be read'));
      expect(sink.inspections, isEmpty);
      expect(await store.read(), 'not json at all');
    });

    test('a document with one readable and one unreadable draft syncs nothing',
        () async {
      // Partial decode would have been worse here than in history: sync retires
      // local records after a successful push, so a queue silently missing an
      // entry would have written the document back without it.
      store = MemoryDraftStore(
        '[{"id":"draft-1","owner_id":"user-1","site_name":"Northgate",'
        '"site_address":null,"client_name":null,'
        '"inspection_date":"2026-08-20T00:00:00.000",'
        '"created_at":"2026-08-20T09:30:00.000","state":"local_only",'
        '"last_error":null,"items":[]},42]',
      );
      final raw = await store.read();
      build();

      final report = await sync.run();

      expect(report.isClean, isFalse);
      expect(report.lastError, contains('could not be read'));
      expect(sink.inspections, isEmpty,
          reason: 'not even the readable draft is pushed');
      expect(await store.read(), raw);
    });

    test('an online create still reaches the server', () async {
      // The queue is broken; the network is not. Refusing an ordinary online
      // create would punish the inspector for a fault that cannot affect it —
      // nothing is written locally on this path.
      corrupt();

      final created = await inspections.create(northgate());
      expect(remoteInspections.rows.single.id, created.id);
      expect(await store.read(), 'not json at all');
    });
  });

  group('isTransportFailure', () {
    test('a PostgREST answer is never an outage', () {
      expect(isTransportFailure(refused), isFalse);
    });

    test('a socket failure is', () {
      expect(isTransportFailure(offline), isTrue);
    });

    test('a retryable auth fetch is; an auth API answer is not', () {
      expect(
        isTransportFailure(AuthRetryableFetchException(message: 'no route')),
        isTrue,
      );
      expect(
        isTransportFailure(
          const AuthApiException('Invalid login credentials',
              statusCode: '400'),
        ),
        isFalse,
      );
    });
  });
}

/// Reports a successful item write and stores nothing — a silent refusal.
class _SwallowingItemSink implements RemoteDraftSink {
  _SwallowingItemSink(this._inner);
  final RemoteDraftSink _inner;

  @override
  Future<void> putInspection(Map<String, dynamic> row) =>
      _inner.putInspection(row);

  @override
  Future<void> putItems(List<Map<String, dynamic>> rows) async {}

  @override
  Future<void> pruneItems(String inspectionId, Set<String> keepIds) async {}

  @override
  Future<Inspection?> readInspection(String id) => _inner.readInspection(id);

  @override
  Future<Set<String>> readItemIds(String inspectionId) =>
      _inner.readItemIds(inspectionId);
}

/// Writes the items, then fails — the interrupted-sync shape.
class _FailAfterItemsSink implements RemoteDraftSink {
  _FailAfterItemsSink(this._inner, {required this.error});

  final RemoteDraftSink _inner;
  final Object error;

  @override
  Future<void> putInspection(Map<String, dynamic> row) =>
      _inner.putInspection(row);

  @override
  Future<void> putItems(List<Map<String, dynamic>> rows) =>
      _inner.putItems(rows);

  @override
  Future<void> pruneItems(String inspectionId, Set<String> keepIds) =>
      throw error;

  @override
  Future<Inspection?> readInspection(String id) => _inner.readInspection(id);

  @override
  Future<Set<String>> readItemIds(String inspectionId) =>
      _inner.readItemIds(inspectionId);
}

/// Fails the push for one inspection id only.
class _FailOneSink implements RemoteDraftSink {
  _FailOneSink(this._inner, {required this.failFor, required this.error});

  final RemoteDraftSink _inner;
  final String failFor;
  final Object error;

  @override
  Future<void> putInspection(Map<String, dynamic> row) {
    if (row['id'] == failFor) throw error;
    return _inner.putInspection(row);
  }

  @override
  Future<void> putItems(List<Map<String, dynamic>> rows) =>
      _inner.putItems(rows);

  @override
  Future<void> pruneItems(String inspectionId, Set<String> keepIds) =>
      _inner.pruneItems(inspectionId, keepIds);

  @override
  Future<Inspection?> readInspection(String id) => _inner.readInspection(id);

  @override
  Future<Set<String>> readItemIds(String inspectionId) =>
      _inner.readItemIds(inspectionId);
}
