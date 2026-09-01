/// The offline seam, placed at the repository boundary and nowhere else.
///
/// These two classes implement the interfaces the app already talks to, so no
/// widget asks whether it is online: the New Inspection sheet, the punch-list
/// editor, History and search call exactly the methods they always called. That
/// is the difference between one draft editor that happens to work offline and
/// two editors that have to be kept in agreement.
///
/// What they do **not** do is cache the server. Nothing server-backed is stored
/// locally: no submitted inspections, no other people's work, no read-through
/// mirror. The queue holds drafts that originated on this device and have never
/// been pushed (D5), and that is all it will ever hold.
library;

import 'package:uuid/uuid.dart';

import '../data/models.dart';
import '../data/repositories.dart';
import 'draft_store.dart';
import 'local_draft.dart';
import 'offline_status.dart';

/// History, search, creation and submission, over both sources.
class OfflineFirstInspectionsRepository implements InspectionsRepository {
  OfflineFirstInspectionsRepository({
    required InspectionsRepository remote,
    required LocalDraftBook local,
    required AuthRepository auth,
    required OfflineStatusNotifier status,
    Uuid? uuid,
  })  : _remote = remote,
        _local = local,
        _auth = auth,
        _status = status,
        _uuid = uuid ?? const Uuid();

  final InspectionsRepository _remote;
  final LocalDraftBook _local;
  final AuthRepository _auth;
  final OfflineStatusNotifier _status;
  final Uuid _uuid;

  /// Tries the server; keeps the draft locally only when the server could not be
  /// reached.
  ///
  /// The id is minted **before** the attempt, which is what makes the ugly case
  /// safe: if the insert commits and the response is lost, the local record
  /// carries the same primary key, and the sync that follows upserts onto the
  /// row that already exists instead of creating a second one.
  ///
  /// A refusal is not an outage. `isTransportFailure` sends a `PostgrestException`
  /// straight back to the caller, because a draft the database has already
  /// rejected would sit in the queue failing forever while the UI implied it was
  /// merely waiting for signal.
  @override
  Future<Inspection> create(NewInspection draft, {String? id}) async {
    final userId = _auth.currentUserId;
    // §3: an offline draft belongs to the inspector who is signed in. There is
    // no anonymous capture, because ownership assigned later is ownership
    // guessed later.
    if (userId == null) throw const NotSignedInException();

    final draftId = id ?? _uuid.v4();
    try {
      final created = await _remote.create(draft, id: draftId);
      _status.setRemoteUnavailable(false);
      return created;
    } catch (e) {
      if (!isTransportFailure(e)) rethrow;

      final local = LocalDraft(
        id: draftId,
        ownerId: userId,
        siteName: draft.siteName.trim(),
        siteAddress: _nullIfBlank(draft.siteAddress),
        clientName: _nullIfBlank(draft.clientName),
        inspectionDate: draft.inspectionDate,
        createdAt: DateTime.now(),
      );
      // Persisted before this returns, so the sheet cannot report a saved draft
      // the device did not actually keep.
      await _local.put(local);
      _status.setRemoteUnavailable(true);
      return local.toInspection();
    }
  }

  /// One history, from two sources, in one order.
  ///
  /// When the server is unreachable the local drafts are still returned and the
  /// status carries `remoteUnavailable`, so the screen can say what is missing.
  /// The alternative — an empty list — would hide the draft the inspector just
  /// created, which is the one thing they are looking for.
  @override
  Future<List<Inspection>> listMine() => _merge((r) => r.listMine(), null);

  @override
  Future<List<Inspection>> searchMine(String query) =>
      _merge((r) => r.searchMine(query), query);

  Future<List<Inspection>> _merge(
    Future<List<Inspection>> Function(InspectionsRepository) remoteCall,
    String? query,
  ) async {
    final userId = _auth.currentUserId;
    if (userId == null) throw const NotSignedInException();

    var locals = await _local.ownedBy(userId);
    if (query != null) {
      locals = locals.where((d) => _matches(query, d)).toList(growable: false);
    }

    final remote = await _remoteOrEmpty(remoteCall);

    // Keyed by id, server wins. This is what makes the crash-after-insert case
    // invisible to the user: a draft whose row reached Postgres before the local
    // record was retired exists in both lists under one key, and appears once.
    final byId = <String, Inspection>{
      for (final draft in locals) draft.id: draft.toInspection(),
    };
    for (final row in remote) {
      byId[row.id] = row;
    }

    return InspectionOrder.newestFirst(byId.values);
  }

  /// The server's rows, or none when the server could not be reached.
  ///
  /// A refusal still propagates: only a transport failure is allowed to become
  /// "the server said nothing". Anything else is an answer the caller must see.
  Future<List<Inspection>> _remoteOrEmpty(
    Future<List<Inspection>> Function(InspectionsRepository) remoteCall,
  ) async {
    try {
      final rows = await remoteCall(_remote);
      _status.setRemoteUnavailable(false);
      return rows;
    } catch (e) {
      if (!isTransportFailure(e)) rethrow;
      _status.setRemoteUnavailable(true);
      return const [];
    }
  }

  /// The same predicate the tsquery expresses, over the same three fields.
  static bool _matches(String query, LocalDraft draft) =>
      InspectionSearch.matches(
        query,
        siteName: draft.siteName,
        siteAddress: draft.siteAddress,
        clientName: draft.clientName,
      );

  /// Submission stays a live server transition (§13).
  ///
  /// Refused at the boundary rather than only hidden in the UI: `submitted_at`
  /// is stamped by a database trigger and immutability is a database rule (D17),
  /// so a locally applied "submitted" would be a claim no server ever made.
  @override
  Future<Inspection> submit(String inspectionId) async {
    final pending = await _local.byId(inspectionId);
    if (pending != null) throw DraftNotSyncedException(inspectionId);
    return _remote.submit(inspectionId);
  }

  static String? _nullIfBlank(String? v) {
    final trimmed = v?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }
}

/// Punch items, routed by whether their inspection is still local.
///
/// A server-backed inspection is never edited from the queue. §14 and D5 both
/// exclude it, and the reason is worth keeping in view: the moment a device may
/// modify a row another client can also modify, this file would need conflict
/// semantics, and the slice would stop being small.
class OfflineFirstInspectionItemsRepository
    implements InspectionItemsRepository {
  OfflineFirstInspectionItemsRepository({
    required InspectionItemsRepository remote,
    required LocalDraftBook local,
    Uuid? uuid,
  })  : _remote = remote,
        _local = local,
        _uuid = uuid ?? const Uuid();

  final InspectionItemsRepository _remote;
  final LocalDraftBook _local;
  final Uuid _uuid;

  @override
  Future<List<InspectionItem>> listFor(String inspectionId) async {
    final draft = await _local.byId(inspectionId);
    if (draft == null) return _remote.listFor(inspectionId);

    // Same order the database is asked for: sort_order, then created_at.
    final items = [...draft.items]..sort((a, b) {
        final byOrder = a.sortOrder.compareTo(b.sortOrder);
        if (byOrder != 0) return byOrder;
        return a.createdAt.compareTo(b.createdAt);
      });
    return items.map((i) => i.toItem(inspectionId)).toList(growable: false);
  }

  @override
  Future<InspectionItem> create(
    String inspectionId,
    NewInspectionItem draft, {
    String? id,
  }) async {
    final parent = await _local.byId(inspectionId);
    if (parent == null) return _remote.create(inspectionId, draft, id: id);

    // Append at the end, exactly as the Supabase repository does.
    final last = parent.items.isEmpty ? -1 : parent.items.last.sortOrder;
    final item = LocalItem(
      id: id ?? _uuid.v4(),
      sortOrder: last + 1,
      title: draft.title.trim(),
      description: NewInspectionItem.nullIfBlank(draft.description),
      area: NewInspectionItem.nullIfBlank(draft.area),
      severity: draft.severity,
      status: ItemStatus.open,
      createdAt: DateTime.now(),
    );
    await _local.put(parent.copyWith(items: [...parent.items, item]));
    return item.toItem(inspectionId);
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
    final parent = await _local.containingItem(itemId);
    if (parent == null) {
      return _remote.update(
        itemId,
        title: title,
        description: description,
        area: area,
        severity: severity,
        status: status,
      );
    }

    final index = parent.items.indexWhere((i) => i.id == itemId);
    final updated = parent.items[index].copyWith(
      title: title.trim(),
      description: () => NewInspectionItem.nullIfBlank(description),
      area: () => NewInspectionItem.nullIfBlank(area),
      severity: severity,
      status: status,
    );
    final items = [...parent.items]..[index] = updated;
    await _local.put(parent.copyWith(items: items));
    return updated.toItem(parent.id);
  }

  @override
  Future<void> delete(String itemId) async {
    final parent = await _local.containingItem(itemId);
    if (parent == null) return _remote.delete(itemId);

    final items =
        parent.items.where((i) => i.id != itemId).toList(growable: false);
    await _local.put(parent.copyWith(items: items));
  }
}
