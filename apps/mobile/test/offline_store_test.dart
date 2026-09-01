import 'package:fieldproof/src/data/models.dart';
import 'package:fieldproof/src/offline/draft_store.dart';
import 'package:fieldproof/src/offline/local_draft.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Durability, and the shape of what is written.
///
/// The property being proven is the one the offline slice is bought for: a draft
/// captured on a device with no signal is still there after the process dies.
/// These tests get at it two ways — by rebuilding the queue over the same bytes,
/// and by round-tripping through the real `shared_preferences` implementation.
void main() {
  LocalDraft draft({
    String id = 'draft-1',
    String owner = 'user-1',
    List<LocalItem> items = const [],
    DraftSyncState state = DraftSyncState.localOnly,
    String? lastError,
  }) =>
      LocalDraft(
        id: id,
        ownerId: owner,
        siteName: 'Northgate Retail Park',
        siteAddress: '4 Northgate Way, Leeds',
        clientName: 'Cavendish Estates',
        inspectionDate: DateTime(2026, 8, 20),
        createdAt: DateTime(2026, 8, 20, 9, 30),
        items: items,
        state: state,
        lastError: lastError,
      );

  LocalItem item({String id = 'item-1', int sortOrder = 0}) => LocalItem(
        id: id,
        sortOrder: sortOrder,
        title: 'Cracked pane',
        description: 'Hairline crack, north elevation',
        area: 'Stairwell',
        severity: ItemSeverity.high,
        status: ItemStatus.open,
        createdAt: DateTime(2026, 8, 20, 10),
      );

  group('LocalDraftBook', () {
    test(
        'a draft written by one book is read by the next one over the same '
        'bytes', () async {
      final store = MemoryDraftStore();
      await LocalDraftBook(store).put(draft(items: [item()]));

      // A second book with no shared memory: this is process death, modelled as
      // precisely as a host test can. Nothing survives except the bytes.
      final reopened = await LocalDraftBook(store).all();

      expect(reopened, hasLength(1));
      expect(reopened.single.siteName, 'Northgate Retail Park');
      expect(reopened.single.siteAddress, '4 Northgate Way, Leeds');
      expect(reopened.single.clientName, 'Cavendish Estates');
      expect(reopened.single.inspectionDate, DateTime(2026, 8, 20));
      expect(reopened.single.items, hasLength(1));
      expect(reopened.single.items.single.title, 'Cracked pane');
      expect(reopened.single.items.single.severity, ItemSeverity.high);
      expect(reopened.single.items.single.area, 'Stairwell');
    });

    test('every field an item carries survives the round trip', () async {
      final store = MemoryDraftStore();
      await LocalDraftBook(store).put(
        draft(
          items: [
            item().copyWith(status: ItemStatus.resolved),
            item(id: 'item-2', sortOrder: 1)
                .copyWith(description: () => null, area: () => null),
          ],
        ),
      );

      final items = (await LocalDraftBook(store).all()).single.items;
      expect(items.map((i) => i.id), ['item-1', 'item-2']);
      expect(items.first.status, ItemStatus.resolved);
      expect(items.last.description, isNull);
      expect(items.last.area, isNull);
      expect(items.last.sortOrder, 1);
    });

    test(
        'sync state and the last error survive, so a crash mid-push is '
        'visible on relaunch', () async {
      final store = MemoryDraftStore();
      await LocalDraftBook(store).put(
        draft(state: DraftSyncState.syncing, lastError: 'connection closed'),
      );

      final reopened = (await LocalDraftBook(store).all()).single;
      expect(reopened.state, DraftSyncState.syncing);
      expect(reopened.lastError, 'connection closed');
    });

    test('put replaces by id rather than appending', () async {
      final store = MemoryDraftStore();
      final book = LocalDraftBook(store);
      await book.put(draft());
      await book.put(draft(items: [item()]));

      final all = await LocalDraftBook(store).all();
      expect(all, hasLength(1));
      expect(all.single.items, hasLength(1));
    });

    test('remove is what retires a draft, and it persists', () async {
      final store = MemoryDraftStore();
      final book = LocalDraftBook(store);
      await book.put(draft());
      await book.remove('draft-1');

      expect(await LocalDraftBook(store).all(), isEmpty);
    });

    test('ownedBy keeps another inspector on the same handset out', () async {
      final store = MemoryDraftStore();
      final book = LocalDraftBook(store);
      await book.put(draft(id: 'mine', owner: 'user-1'));
      await book.put(draft(id: 'theirs', owner: 'user-2'));

      expect((await book.ownedBy('user-1')).map((d) => d.id), ['mine']);
      expect((await book.ownedBy('user-2')).map((d) => d.id), ['theirs']);
    });

    test('a failed write surfaces rather than silently losing the draft',
        () async {
      final store = MemoryDraftStore()..failWrites = StateError('disk full');
      final book = LocalDraftBook(store);

      await expectLater(book.put(draft()), throwsStateError);
    });

    test('an absent store is an empty queue', () async {
      // The one case that genuinely *is* empty: nothing has ever been written.
      final store = MemoryDraftStore();
      expect(await store.read(), isNull);
      expect(await LocalDraftBook(store).all(), isEmpty);
      expect(LocalDraftBook(store).isUnreadable, isFalse);
    });

    test('a corrupt store is not treated as an empty one', () async {
      // The distinction the whole group below turns on. Returning [] here reads
      // as "you have no offline drafts", and the next ordinary save would then
      // write a fresh document over bytes that still held the inspector's only
      // copy of their work — ACCEPTANCE E3 exactly inverted.
      await expectLater(
        LocalDraftBook(MemoryDraftStore('not json at all')).all(),
        throwsA(isA<DraftStoreUnreadableException>()),
      );
    });

    test('onChanged reports the queue after load and after every change',
        () async {
      final store = MemoryDraftStore();
      final seen = <int>[];
      final book = LocalDraftBook(store, onChanged: (d) => seen.add(d.length));

      await book.all();
      await book.put(draft());
      await book.remove('draft-1');

      expect(seen, [0, 1, 0]);
    });
  });

  /// Unreadable persisted data.
  ///
  /// The contract under test is ACCEPTANCE E3 — *no local change is discarded
  /// without an explicit user action* — applied to the case where the app cannot
  /// understand what it saved. The rule is that it may refuse to work, and may
  /// not pretend the work was never there.
  group('a store that cannot be decoded', () {
    /// Every shape of "something was stored, and it will not decode".
    final corrupt = <String, String>{
      'malformed JSON': 'not json at all',
      'a truncated document': '[{"id":"draft-1","owner_id":',
      'valid JSON of the wrong shape': '[{"nope":1}]',
      'a JSON object rather than a list': '{"id":"draft-1"}',
      'a JSON scalar': '42',
      'a draft missing a required field': '[{"id":"draft-1"}]',
      'a severity that no longer exists': '[{"id":"d","owner_id":"u",'
          '"site_name":"S","inspection_date":"2026-08-20T00:00:00.000",'
          '"created_at":"2026-08-20T00:00:00.000","state":"local_only",'
          '"items":[{"id":"i","sort_order":0,"title":"T",'
          '"severity":"catastrophic","status":"open",'
          '"created_at":"2026-08-20T00:00:00.000"}]}]',
      'an unparseable date': '[{"id":"d","owner_id":"u","site_name":"S",'
          '"inspection_date":"the twentieth","created_at":"2026-08-20T00:00:00.000",'
          '"state":"local_only","items":[]}]',
    };

    for (final entry in corrupt.entries) {
      test('${entry.key} surfaces the typed error', () async {
        await expectLater(
          LocalDraftBook(MemoryDraftStore(entry.value)).all(),
          throwsA(isA<DraftStoreUnreadableException>()),
        );
      });
    }

    test('the message names the underlying cause and promises nothing was lost',
        () async {
      final book = LocalDraftBook(MemoryDraftStore('not json at all'));
      Object? raised;
      try {
        await book.all();
      } catch (e) {
        raised = e;
      }

      // Truthful and specific. A user who can see the parse failure can tell a
      // truncated write from a version mismatch; one shown "Storage error"
      // cannot.
      expect(raised, isA<DraftStoreUnreadableException>());
      expect(raised.toString(), contains('could not be read'));
      expect(raised.toString(), contains('Nothing has been deleted'));
      expect(
        (raised! as DraftStoreUnreadableException).cause,
        isA<FormatException>(),
      );
    });

    test('the raw value is untouched by the failed read', () async {
      const raw = '[{"id":"draft-1","owner_id":';
      final store = MemoryDraftStore(raw);

      await expectLater(
        LocalDraftBook(store).all(),
        throwsA(isA<DraftStoreUnreadableException>()),
      );

      // The bytes that could not be understood are still the bytes on disk.
      // Whatever recovery is ever built has something to recover from.
      expect(await store.read(), raw);
    });

    test('a later write cannot overwrite the unreadable store', () async {
      // The follow-on risk, and the reason returning [] was dangerous rather
      // than merely wrong: an app that believed the queue was empty would
      // happily save a new draft, and that save would replace the only copy of
      // the old one.
      const raw = 'not json at all';
      final store = MemoryDraftStore(raw);
      final book = LocalDraftBook(store);

      await expectLater(
        book.all(),
        throwsA(isA<DraftStoreUnreadableException>()),
      );
      await expectLater(
        book.put(draft(id: 'draft-2')),
        throwsA(isA<DraftStoreUnreadableException>()),
      );
      await expectLater(
        book.remove('draft-1'),
        throwsA(isA<DraftStoreUnreadableException>()),
      );

      expect(await store.read(), raw, reason: 'still exactly what was there');
    });

    test('the failure is sticky, so no later caller sees an empty queue',
        () async {
      final book = LocalDraftBook(MemoryDraftStore('not json at all'));

      for (var attempt = 0; attempt < 3; attempt++) {
        await expectLater(
          book.all(),
          throwsA(isA<DraftStoreUnreadableException>()),
          reason: 'attempt $attempt must fail the same way',
        );
      }
      expect(book.isUnreadable, isTrue);
    });

    test('ownedBy, byId and containingItem all refuse rather than answer',
        () async {
      final book = LocalDraftBook(MemoryDraftStore('not json at all'));

      // Each of these would otherwise answer "no drafts" / "not found", which
      // is a claim the queue is in no position to make.
      await expectLater(
        book.ownedBy('user-1'),
        throwsA(isA<DraftStoreUnreadableException>()),
      );
      await expectLater(
        book.byId('draft-1'),
        throwsA(isA<DraftStoreUnreadableException>()),
      );
      await expectLater(
        book.containingItem('item-1'),
        throwsA(isA<DraftStoreUnreadableException>()),
      );
    });

    test('onChanged is never called, so nothing reports the queue as healthy',
        () async {
      final seen = <int>[];
      final book = LocalDraftBook(
        MemoryDraftStore('not json at all'),
        onChanged: (d) => seen.add(d.length),
      );

      await expectLater(
        book.all(),
        throwsA(isA<DraftStoreUnreadableException>()),
      );
      expect(seen, isEmpty);
    });

    test('a failure that is not a decode failure propagates untouched',
        () async {
      // The decoder catches FormatException, TypeError and ArgumentError,
      // because those are the three ways *persisted data* can be wrong. A store
      // that fails outright is a different fault, and reporting it as the user's
      // saved data being damaged would send them looking in the wrong place —
      // and would hide a bug behind a message about their device.
      final store = MemoryDraftStore()..failReads = StateError('bug');

      await expectLater(LocalDraftBook(store).all(), throwsStateError);
    });
  });

  group('SharedPreferencesDraftStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('round-trips a draft through the real preferences implementation',
        () async {
      const store = SharedPreferencesDraftStore();
      await LocalDraftBook(store).put(draft(items: [item()]));

      final reopened = await LocalDraftBook(store).all();
      expect(reopened, hasLength(1));
      expect(reopened.single.id, 'draft-1');
      expect(reopened.single.items.single.title, 'Cracked pane');
    });

    test('reads as empty before anything has been written', () async {
      const store = SharedPreferencesDraftStore();
      expect(await store.read(), isNull);
      expect(await LocalDraftBook(store).all(), isEmpty);
    });
  });

  group('LocalDraft', () {
    test('presents as a Draft and never as Submitted', () {
      // A device is not entitled to claim a submission happened: submitted_at is
      // stamped by a database trigger (D10) and immutability is a database rule
      // (D17). There is no code path that could set this to submitted.
      expect(draft().toInspection().status, InspectionStatus.draft);
      expect(draft().toInspection().submittedAt, isNull);
    });

    test('the push row takes inspector_id from the argument, not from disk',
        () {
      final row = draft(owner: 'stored-owner').toRow(inspectorId: 'session');
      expect(row['inspector_id'], 'session');
      expect(row['id'], 'draft-1');
      expect(row['inspection_date'], '2026-08-20');
      // Absent so the column defaults apply and the submitted_at/status CHECK
      // holds — the same rule the online insert follows.
      expect(row.containsKey('status'), isFalse);
      expect(row.containsKey('submitted_at'), isFalse);
    });

    test('the item push row carries status, which an insert omits', () {
      // An insert lets the column default to 'open'. A re-push must not: an item
      // the inspector resolved offline would silently sync back as open.
      final row = item().copyWith(status: ItemStatus.resolved).toRow('insp-1');
      expect(row['status'], 'resolved');
      expect(row['inspection_id'], 'insp-1');
      expect(row['id'], 'item-1');
    });
  });
}
