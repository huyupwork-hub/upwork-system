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
    test('a draft written by one book is read by the next one over the same '
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

    test('sync state and the last error survive, so a crash mid-push is '
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

    test('unreadable stored bytes yield an empty queue, not a broken app',
        () async {
      expect(await LocalDraftBook(MemoryDraftStore('not json')).all(), isEmpty);
      // Well-formed JSON of the wrong shape too — that raises out of the casts
      // in fromJson rather than out of the parser, and means the same thing.
      expect(
        await LocalDraftBook(MemoryDraftStore('[{"nope":1}]')).all(),
        isEmpty,
      );
      expect(await LocalDraftBook(MemoryDraftStore('{}')).all(), isEmpty);
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
