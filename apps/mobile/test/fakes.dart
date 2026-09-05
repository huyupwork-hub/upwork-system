import 'dart:async';

import 'package:fieldproof/src/data/models.dart';
import 'package:fieldproof/src/data/photo_workflow.dart';
import 'dart:typed_data';

import 'package:fieldproof/src/data/repositories.dart';
import 'package:fieldproof/src/offline/draft_sync.dart';
import 'package:fieldproof/src/report/report_renderer.dart';
import 'package:fieldproof/src/report/report_sharer.dart';
import 'package:fieldproof/src/report/report_snapshot.dart';
import 'package:fieldproof/src/report/report_store.dart';

/// In-memory stand-ins. They model the *client* contract only. Access control is
/// the database's job and is proven by the pgTAP suite in supabase/tests — these
/// fakes deliberately do not re-implement RLS, because a fake that enforced it
/// would prove nothing about the real policies.
class FakeAuthRepository implements AuthRepository {
  FakeAuthRepository({String? initialUserId}) : _userId = initialUserId;

  final _controller = StreamController<String?>.broadcast();
  String? _userId;

  /// Credentials this fake will accept.
  final Map<String, String> accounts = {'a@example.com': 'correct-horse'};

  /// Set to make signIn throw, to exercise error rendering.
  Object? failWith;

  int signOutCount = 0;

  @override
  Stream<String?> get userIdChanges => _controller.stream;

  @override
  String? get currentUserId => _userId;

  @override
  Future<void> signIn({required String email, required String password}) async {
    if (failWith != null) throw failWith!;
    if (accounts[email] != password) {
      throw Exception('Invalid login credentials');
    }
    _userId = 'user-${email.hashCode}';
    _controller.add(_userId);
  }

  @override
  Future<void> signOut() async {
    signOutCount++;
    _userId = null;
    _controller.add(null);
  }

  Future<void> dispose() => _controller.close();
}

class FakeProfileRepository implements ProfileRepository {
  FakeProfileRepository({this.profile, this.throwMissing = false});

  Profile? profile;
  bool throwMissing;

  /// Set to make `loadCurrent` throw — the profile row lives on the server, so
  /// it is unreachable exactly when everything else is.
  ///
  /// This fake had no such mode, and that is why 263 passing tests missed the
  /// defect real-device QA found: the history screen loaded the profile before
  /// the list, so on a cold offline start one unreachable call blanked the
  /// whole screen and the inspector's saved drafts looked lost. Every fake that
  /// stands in for something across a network needs a way to be unreachable, or
  /// the offline path is only ever tested half-connected.
  Object? failWith;

  @override
  Future<Profile> loadCurrent() async {
    if (failWith != null) throw failWith!;
    if (throwMissing) throw const ProfileMissingException('user-1');
    return profile ??
        const Profile(
            id: 'user-1', fullName: 'Inspector Alpha', role: 'inspector');
  }
}

class FakeInspectionsRepository implements InspectionsRepository {
  FakeInspectionsRepository(
      {List<Inspection>? initial, this.sessionUserId = 'user-1'})
      : rows = [...?initial];

  final List<Inspection> rows;
  final String sessionUserId;

  /// Every insert payload this repository was asked to persist.
  ///
  /// Recorded *before* [failWith] is honoured, because it is the record of what
  /// was asked, not of what succeeded. A real client builds the request and
  /// sends it, and only then learns it failed — so a test asserting "the id we
  /// sent is the id we kept locally" needs the payload of the attempt that
  /// failed, which is exactly the case that matters for idempotency.
  final List<Map<String, dynamic>> insertPayloads = [];

  /// Set to make `create` throw — the write was refused, or never arrived.
  Object? failWith;

  /// Set to make `listMine` and `searchMine` throw.
  ///
  /// Separate from [failWith] because they model different things. An RLS
  /// refusal rejects the write while reads keep working, which is what
  /// `app_flow_test` uses [failWith] for. Losing the network fails both, so a
  /// test that means "offline" sets both.
  Object? readFailsWith;

  @override
  Future<Inspection> create(NewInspection draft, {String? id}) async {
    // Mirrors the production path: the owner comes from the session, and the
    // primary key is device-generated — supplied by the caller when it has one,
    // minted here when it does not.
    final payload = draft.toInsert(
      inspectorId: sessionUserId,
      id: id ?? 'inspection-${rows.length + 1}',
    );
    insertPayloads.add(payload);

    if (failWith != null) throw failWith!;

    final created = Inspection(
      id: payload['id'] as String,
      inspectorId: payload['inspector_id'] as String,
      siteName: payload['site_name'] as String,
      siteAddress: payload['site_address'] as String?,
      clientName: payload['client_name'] as String?,
      inspectionDate: DateTime.parse(payload['inspection_date'] as String),
      status: InspectionStatus.draft,
    );
    rows.insert(0, created);
    return created;
  }

  /// Per-query artificial latency, so a test can make an earlier request
  /// finish *after* a later one and prove the stale result is discarded.
  final Map<String, Duration> delays = {};

  /// Ids this repository was asked to submit, in order.
  final List<String> submitted = [];

  /// Set to make submit() fail, standing in for the policy refusing it.
  Object? submitFailsWith;

  @override
  Future<Inspection> submit(String inspectionId) async {
    if (submitFailsWith != null) throw submitFailsWith!;

    final index = rows.indexWhere((r) => r.id == inspectionId);
    // Mirrors the production shape rather than RLS: the real refusal is a
    // zero-row update, which the repository turns into this exception. The fake
    // does not re-implement ownership — that is the database's job, proven in
    // pgTAP 070 and the hosted smoke.
    if (index < 0 || rows[index].status != InspectionStatus.draft) {
      throw const NotPermittedException('submit this inspection');
    }

    submitted.add(inspectionId);
    final was = rows[index];
    final now = Inspection(
      id: was.id,
      inspectorId: was.inspectorId,
      siteName: was.siteName,
      siteAddress: was.siteAddress,
      clientName: was.clientName,
      inspectionDate: was.inspectionDate,
      status: InspectionStatus.submitted,
      // Server-stamped in production; the fake supplies one so callers can
      // assert the screen renders what the server returned.
      submittedAt: DateTime(2026, 9, 1, 12),
      createdAt: was.createdAt,
    );
    rows[index] = now;
    return now;
  }

  @override
  Future<List<Inspection>> listMine() async {
    if (readFailsWith != null) throw readFailsWith!;
    await _wait('');
    return List.unmodifiable(_ordered(rows));
  }

  @override
  Future<List<Inspection>> searchMine(String query) async {
    if (readFailsWith != null) throw readFailsWith!;
    await _wait(query);
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return List.unmodifiable(_ordered(rows));

    // Stands in for the tsvector through the same predicate the offline queue
    // uses, so "what this word matches" has one definition on the client. It was
    // a substring scan before the offline slice, which was a *looser* rule than
    // Postgres applies — the fake would have matched things the database does
    // not. It deliberately still does NOT re-implement ownership; that is RLS's
    // job, proven in pgTAP `090` and the hosted smoke.
    bool matches(Inspection r) => InspectionSearch.matches(
          needle,
          siteName: r.siteName,
          siteAddress: r.siteAddress,
          clientName: r.clientName,
        );

    return List.unmodifiable(_ordered(rows.where(matches).toList()));
  }

  Future<void> _wait(String query) async {
    final delay = delays[query.trim()];
    if (delay != null) await Future<void>.delayed(delay);
  }

  /// inspection_date DESC, then created_at DESC, then id DESC — the same total
  /// order the repository asks Postgres for, from the one shared definition, so
  /// the fake cannot drift from the order the merged offline history uses.
  List<Inspection> _ordered(List<Inspection> input) =>
      InspectionOrder.newestFirst(input);
}

/// In-memory punch items.
///
/// Note what this does NOT do: it enforces no ownership rule of any kind. Any
/// caller can read or mutate anything in it. That is deliberate — a fake that
/// re-implemented RLS would only be testing the fake. Ownership is proven by
/// pgTAP (`020`, `060`) and by the hosted smoke test against real policies.
class FakeInspectionItemsRepository implements InspectionItemsRepository {
  FakeInspectionItemsRepository({List<InspectionItem>? initial})
      : rows = [...?initial];

  final List<InspectionItem> rows;

  /// Every insert payload this repository was asked to persist.
  final List<Map<String, dynamic>> insertPayloads = [];

  /// Ids passed to delete().
  final List<String> deleted = [];

  Object? failWith;

  int _seq = 0;

  @override
  Future<List<InspectionItem>> listFor(String inspectionId) async {
    final matching = rows.where((r) => r.inspectionId == inspectionId).toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return List.unmodifiable(matching);
  }

  @override
  Future<InspectionItem> create(
    String inspectionId,
    NewInspectionItem draft, {
    String? id,
  }) async {
    if (failWith != null) throw failWith!;

    final existing = await listFor(inspectionId);
    final sortOrder = existing.isEmpty ? 0 : existing.last.sortOrder + 1;

    // Mirrors the production path: the parent comes from the argument, never
    // from the draft, so a caller cannot name another inspection.
    final payload = draft.toInsert(
      inspectionId: inspectionId,
      sortOrder: sortOrder,
      id: id ?? 'item-${++_seq}',
    );
    insertPayloads.add(payload);

    final item = InspectionItem(
      id: payload['id'] as String,
      inspectionId: payload['inspection_id'] as String,
      sortOrder: payload['sort_order'] as int,
      title: payload['title'] as String,
      description: payload['description'] as String?,
      area: payload['area'] as String?,
      severity: ItemSeverity.fromWire(payload['severity'] as String),
      status: ItemStatus.open,
    );
    rows.add(item);
    return item;
  }

  @override
  Future<InspectionItem> update(
    String itemId, {
    required String title,
    String? description,
    String? area,
    required ItemSeverity severity,
    required ItemStatus status,
  }) async {
    if (failWith != null) throw failWith!;

    final index = rows.indexWhere((r) => r.id == itemId);
    if (index < 0) throw const NotPermittedException('update this item');

    final old = rows[index];
    final updated = InspectionItem(
      id: old.id,
      inspectionId: old.inspectionId,
      sortOrder: old.sortOrder,
      title: title.trim(),
      description: NewInspectionItem.nullIfBlank(description),
      area: NewInspectionItem.nullIfBlank(area),
      severity: severity,
      status: status,
    );
    rows[index] = updated;
    return updated;
  }

  @override
  Future<void> delete(String itemId) async {
    if (failWith != null) throw failWith!;

    deleted.add(itemId);
    final before = rows.length;
    rows.removeWhere((r) => r.id == itemId);
    if (rows.length == before) {
      throw const NotPermittedException('delete this item');
    }
  }
}

/// A capture source that never touches a platform channel.
class FakePhotoSource implements PhotoSource {
  FakePhotoSource({this.failWith});

  /// What the next pick returns. Null models the user cancelling.
  ///
  /// Deliberately not a constructor parameter: `{this.next}` would override this
  /// initializer with null whenever the argument was omitted, so the default
  /// source would silently behave as a cancelled picker.
  CapturedPhoto? next = const CapturedPhoto(
    bytes: [1, 2, 3, 4],
    contentType: 'image/jpeg',
  );
  Object? failWith;

  int cameraCalls = 0;
  int galleryCalls = 0;

  @override
  Future<CapturedPhoto?> capture() async {
    cameraCalls++;
    if (failWith != null) throw failWith!;
    return next;
  }

  @override
  Future<CapturedPhoto?> pickFromGallery() async {
    galleryCalls++;
    if (failWith != null) throw failWith!;
    return next;
  }
}

/// In-memory bucket. Enforces no ownership rule — see the note on
/// [FakeInspectionItemsRepository]; that is the database's job.
class FakeObjectStore implements PhotoObjectStore {
  final Map<String, List<int>> objects = {};
  final List<String> removed = [];

  Object? failPut;
  Object? failRemove;

  @override
  Future<void> put(String path, List<int> bytes, String contentType) async {
    if (failPut != null) throw failPut!;
    objects[path] = bytes;
  }

  @override
  Future<void> remove(String path) async {
    if (failRemove != null) throw failRemove!;
    removed.add(path);
    objects.remove(path);
  }

  @override
  Future<String> signedUrl(String path, Duration ttl) async =>
      'https://example.test/signed/$path';

  /// Set to make a download fail, so the report's 'photograph unavailable'
  /// path can be exercised.
  Object? failDownload;

  @override
  Future<List<int>> download(String path) async {
    if (failDownload != null) throw failDownload!;
    final bytes = objects[path];
    if (bytes == null) throw StateError('no object at $path');
    return bytes;
  }
}

/// In-memory `item_photos`.
class FakePhotoMetadataStore implements PhotoMetadataStore {
  final List<ItemPhoto> rows = [];

  Object? failInsert;

  /// Models an RLS refusal: the delete matches nothing.
  bool denyDelete = false;

  @override
  Future<List<ItemPhoto>> listFor(String itemId) async =>
      List.unmodifiable(rows.where((r) => r.itemId == itemId));

  @override
  Future<ItemPhoto> insert({
    required String photoId,
    required String itemId,
    required String inspectionId,
    required String storagePath,
    required String contentType,
    required int byteSize,
  }) async {
    if (failInsert != null) throw failInsert!;
    final photo = ItemPhoto(
      id: photoId,
      itemId: itemId,
      inspectionId: inspectionId,
      storagePath: storagePath,
      contentType: contentType,
      byteSize: byteSize,
    );
    rows.add(photo);
    return photo;
  }

  @override
  Future<bool> deleteById(String photoId) async {
    if (denyDelete) return false;
    final before = rows.length;
    rows.removeWhere((r) => r.id == photoId);
    return rows.length != before;
  }
}

/// Records what it was asked to render, and returns bytes that look like a PDF.
class FakeReportRenderer implements ReportRenderer {
  final List<ReportSnapshot> rendered = [];
  Object? failWith;

  /// What the next render returns, when a test needs a document of a
  /// particular size — the over-the-cap case. Null keeps the default.
  Uint8List? output;

  @override
  Future<Uint8List> render(ReportSnapshot snapshot) async {
    if (failWith != null) throw failWith!;
    rendered.add(snapshot);
    return output ?? Uint8List.fromList('%PDF-1.7 fake'.codeUnits);
  }
}

/// In-memory report bucket. Write-once like the real one: a second put at an
/// existing key records the attempt and completes without overwriting, which
/// is what the production store's Duplicate mapping amounts to. Enforces no
/// ownership rule — see the note on [FakeInspectionItemsRepository]; the
/// write-once policy itself is proven in pgTAP `110` and hosted smoke 22b.
class FakeReportStore implements ReportStore {
  final Map<String, Uint8List> objects = {};

  /// Every path a put was asked for, in order, including the attempts
  /// [failPut] refused — the record of what was asked, not of what landed.
  final List<String> puts = [];

  /// Set to make `put` throw: a `SocketException` stands in for no signal, a
  /// `StorageException` for the bucket answering no.
  Object? failPut;

  /// Set to make `published` throw — the listing lives on the server, so it is
  /// unreachable exactly when everything else is, and the screens must show
  /// "could not check" rather than "not uploaded" (D28).
  Object? failPublished;

  @override
  Future<void> put(String path, Uint8List bytes) async {
    puts.add(path);
    if (failPut != null) throw failPut!;
    objects.putIfAbsent(path, () => bytes);
  }

  @override
  Future<Set<String>> published(String inspectorId) async {
    if (failPublished != null) throw failPublished!;
    return {
      for (final path in objects.keys)
        if (path.startsWith('$inspectorId/')) path.split('/')[1],
    };
  }
}

/// Stands in for the platform share sheet — no platform channel is loaded.
class FakeReportSharer implements ReportSharer {
  final List<String> filenames = [];
  final List<Uint8List> shared = [];
  Object? failWith;

  @override
  Future<bool> share(Uint8List bytes, {required String filename}) async {
    if (failWith != null) throw failWith!;
    shared.add(bytes);
    filenames.add(filename);
    return true;
  }
}

// ---------------------------------------------------------------- offline

/// An in-memory stand-in for the server half of a draft push.
///
/// Like every other fake here it re-implements no ownership rule — RLS is proven
/// by pgTAP and the hosted smoke. What it *does* model faithfully is the shape
/// of an upsert on a device-generated key, because that is the property the sync
/// tests are about: writing the same row twice must leave one row.
class FakeDraftSink implements RemoteDraftSink {
  FakeDraftSink({this.sessionUserId = 'user-1'});

  final String sessionUserId;

  /// The upserted rows, keyed by primary key. A map, not a list, because that is
  /// what `ON CONFLICT (id) DO UPDATE` amounts to — a test that used a list
  /// would report duplicates the database would never have created, and would
  /// prove nothing about idempotency.
  final Map<String, Map<String, dynamic>> inspections = {};
  final Map<String, Map<String, dynamic>> items = {};

  /// Every call, in order, so a test can assert the parent was written before
  /// its children.
  final List<String> calls = [];

  /// Set to make the next inspection upsert fail.
  Object? failInspection;

  /// Set to make the next item upsert fail. Combined with [failAfterInspection]
  /// this reproduces the partial-failure case: the parent lands, the children
  /// do not.
  Object? failItems;

  /// Set to make the verifying read report the inspection as absent, which is
  /// how a silently refused write looks from the client.
  bool inspectionReadsAsMissing = false;

  @override
  Future<void> putInspection(Map<String, dynamic> row) async {
    calls.add('putInspection');
    if (failInspection != null) throw failInspection!;
    final id = row['id'] as String;
    inspections[id] = {...row, 'status': 'draft', 'submitted_at': null};
  }

  @override
  Future<void> putItems(List<Map<String, dynamic>> rows) async {
    calls.add('putItems');
    if (failItems != null) throw failItems!;
    for (final row in rows) {
      items[row['id'] as String] = {...row};
    }
  }

  @override
  Future<void> pruneItems(String inspectionId, Set<String> keepIds) async {
    calls.add('pruneItems');
    items.removeWhere(
      (id, row) =>
          row['inspection_id'] == inspectionId && !keepIds.contains(id),
    );
  }

  @override
  Future<Inspection?> readInspection(String id) async {
    calls.add('readInspection');
    if (inspectionReadsAsMissing) return null;
    final row = inspections[id];
    if (row == null) return null;
    return Inspection(
      id: row['id'] as String,
      inspectorId: row['inspector_id'] as String,
      siteName: row['site_name'] as String,
      siteAddress: row['site_address'] as String?,
      clientName: row['client_name'] as String?,
      inspectionDate: DateTime.parse(row['inspection_date'] as String),
      status: InspectionStatus.draft,
      createdAt: DateTime(2026, 9, 1),
    );
  }

  @override
  Future<Set<String>> readItemIds(String inspectionId) async {
    calls.add('readItemIds');
    return items.entries
        .where((e) => e.value['inspection_id'] == inspectionId)
        .map((e) => e.key)
        .toSet();
  }
}
