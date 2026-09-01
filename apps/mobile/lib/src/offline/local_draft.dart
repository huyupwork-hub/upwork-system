/// The records the device holds for a draft that was created while offline.
///
/// Scope is exactly D5: an inspection that is still `draft` and has **never**
/// been pushed. Nothing here mirrors a server-backed row, so this is not a local
/// copy of the database and cannot drift from one. A draft exists in exactly one
/// place until its first sync, which is why there is no conflict to resolve and
/// no version vector, tombstone or operation log in this file.
///
/// The models deliberately reuse the domain enums from `models.dart` rather than
/// declaring offline-only equivalents: a punch item captured in a basement means
/// the same thing as one captured on a rooftop with signal, and two enums that
/// had to be kept in agreement would eventually disagree.
library;

import '../data/models.dart';

/// Where a local draft is in its one and only transition.
///
/// There is no `synced` member, and that is the point. "Synced" is represented
/// by the record no longer existing locally — the handoff to Supabase/RLS
/// authority is a deletion, not a flag. A `synced` state stored on the device
/// would be a second writable authority for a row the server already owns,
/// which is the dual-source-of-truth bug this design exists to avoid.
enum DraftSyncState {
  /// Held on the device. Editable here, and nowhere else.
  localOnly,

  /// A push is in flight. Persisted so that a crash mid-push is visible on
  /// relaunch as a draft that needs retrying, rather than as a draft that
  /// silently looks untouched.
  syncing;

  /// Raises on a value this version does not know.
  ///
  /// It used to fall back to `localOnly`, which looks harmless — that is the
  /// safe state to be in — but it is the same silent-normalisation bug as the
  /// rest: an unknown value means the stored document was written by something
  /// this build does not understand, and defaulting it lets a later write
  /// persist this build's guess over whatever was actually recorded.
  ///
  /// `ArgumentError` rather than a dedicated type, so it arrives at the queue's
  /// decoder through the same boundary as an unknown `severity` or `status`
  /// (`ItemSeverity.fromWire`), which converts it to
  /// `DraftStoreUnreadableException`. Raising the store's own exception here
  /// would need `local_draft.dart` to import `draft_store.dart`, which imports
  /// this file.
  static DraftSyncState fromJson(String value) => switch (value) {
        'local_only' => DraftSyncState.localOnly,
        'syncing' => DraftSyncState.syncing,
        _ => throw ArgumentError.value(
            value, 'state', 'unknown offline draft sync state'),
      };

  String get json => switch (this) {
        DraftSyncState.localOnly => 'local_only',
        DraftSyncState.syncing => 'syncing',
      };
}

/// A punch item belonging to an offline-origin draft.
class LocalItem {
  const LocalItem({
    required this.id,
    required this.sortOrder,
    required this.title,
    required this.severity,
    required this.status,
    required this.createdAt,
    this.description,
    this.area,
  });

  /// Device-generated, and the final `inspection_items.id` after sync.
  final String id;
  final int sortOrder;
  final String title;
  final String? description;
  final String? area;
  final ItemSeverity severity;
  final ItemStatus status;
  final DateTime createdAt;

  LocalItem copyWith({
    String? title,
    String? Function()? description,
    String? Function()? area,
    ItemSeverity? severity,
    ItemStatus? status,
  }) =>
      LocalItem(
        id: id,
        sortOrder: sortOrder,
        title: title ?? this.title,
        description: description == null ? this.description : description(),
        area: area == null ? this.area : area(),
        severity: severity ?? this.severity,
        status: status ?? this.status,
        createdAt: createdAt,
      );

  /// The domain object the rest of the app already knows how to render.
  ///
  /// The UI never learns whether an item came from Postgres or from disk, which
  /// is what keeps a single draft editor working for both.
  InspectionItem toItem(String inspectionId) => InspectionItem(
        id: id,
        inspectionId: inspectionId,
        sortOrder: sortOrder,
        title: title,
        description: description,
        area: area,
        severity: severity,
        status: status,
        createdAt: createdAt,
      );

  /// The row a sync upserts. Shaped exactly like `NewInspectionItem.toInsert`,
  /// including `status`, which an insert omits but a re-push must carry — a
  /// resolved item that synced as `open` would quietly lose a field the
  /// inspector set.
  Map<String, dynamic> toRow(String inspectionId) => {
        'id': id,
        'inspection_id': inspectionId,
        'sort_order': sortOrder,
        'title': title,
        'description': description,
        'area': area,
        'severity': severity.wire,
        'status': status.wire,
      };

  Map<String, dynamic> toJson() => {
        'id': id,
        'sort_order': sortOrder,
        'title': title,
        'description': description,
        'area': area,
        'severity': severity.wire,
        'status': status.wire,
        'created_at': createdAt.toIso8601String(),
      };

  factory LocalItem.fromJson(Map<String, dynamic> json) => LocalItem(
        id: json['id'] as String,
        sortOrder: (json['sort_order'] as num).toInt(),
        title: json['title'] as String,
        description: json['description'] as String?,
        area: json['area'] as String?,
        severity: ItemSeverity.fromWire(json['severity'] as String),
        status: ItemStatus.fromWire(json['status'] as String),
        createdAt: DateTime.parse(json['created_at'] as String),
      );
}

/// An inspection created on this device while the server was unreachable.
class LocalDraft {
  const LocalDraft({
    required this.id,
    required this.ownerId,
    required this.siteName,
    required this.inspectionDate,
    required this.createdAt,
    this.siteAddress,
    this.clientName,
    this.items = const [],
    this.state = DraftSyncState.localOnly,
    this.lastError,
  });

  /// Device-generated, and the final `inspections.id` after sync. One local
  /// draft therefore maps to at most one server row, by construction rather
  /// than by bookkeeping.
  final String id;

  /// The inspector who was authenticated when this draft was created.
  ///
  /// Stored so a draft is never pushed under a different session's identity —
  /// not as authority. At sync time `inspector_id` is taken from the live
  /// session and RLS decides; this field only decides whether to try.
  final String ownerId;

  final String siteName;
  final String? siteAddress;
  final String? clientName;
  final DateTime inspectionDate;
  final DateTime createdAt;
  final List<LocalItem> items;
  final DraftSyncState state;

  /// Why the last push failed, if it did. Surfaced verbatim; a sync failure the
  /// user cannot see is a sync failure they cannot act on.
  final String? lastError;

  LocalDraft copyWith({
    List<LocalItem>? items,
    DraftSyncState? state,
    String? Function()? lastError,
  }) =>
      LocalDraft(
        id: id,
        ownerId: ownerId,
        siteName: siteName,
        siteAddress: siteAddress,
        clientName: clientName,
        inspectionDate: inspectionDate,
        createdAt: createdAt,
        items: items ?? this.items,
        state: state ?? this.state,
        lastError: lastError == null ? this.lastError : lastError(),
      );

  /// Always `draft`. A local record can never present itself as submitted:
  /// submission is a server transition that stamps `submitted_at` by trigger,
  /// and nothing on this device is entitled to claim it happened (D10, D17).
  Inspection toInspection() => Inspection(
        id: id,
        inspectorId: ownerId,
        siteName: siteName,
        siteAddress: siteAddress,
        clientName: clientName,
        inspectionDate: inspectionDate,
        status: InspectionStatus.draft,
        createdAt: createdAt,
      );

  /// The row a sync upserts.
  ///
  /// `inspector_id` is **not** here: the sync supplies it from the live session,
  /// so a value written to disk can never become the claimed owner of a row.
  /// `status` and `submitted_at` are absent so the column defaults apply and the
  /// submitted_at/status CHECK holds.
  Map<String, dynamic> toRow({required String inspectorId}) => {
        'id': id,
        'inspector_id': inspectorId,
        'site_name': siteName,
        'site_address': siteAddress,
        'client_name': clientName,
        'inspection_date': NewInspection.dateOnly(inspectionDate),
      };

  Map<String, dynamic> toJson() => {
        'id': id,
        'owner_id': ownerId,
        'site_name': siteName,
        'site_address': siteAddress,
        'client_name': clientName,
        'inspection_date': inspectionDate.toIso8601String(),
        'created_at': createdAt.toIso8601String(),
        'state': state.json,
        'last_error': lastError,
        'items': items.map((i) => i.toJson()).toList(growable: false),
      };

  factory LocalDraft.fromJson(Map<String, dynamic> json) => LocalDraft(
        id: json['id'] as String,
        ownerId: json['owner_id'] as String,
        siteName: json['site_name'] as String,
        siteAddress: json['site_address'] as String?,
        clientName: json['client_name'] as String?,
        inspectionDate: DateTime.parse(json['inspection_date'] as String),
        createdAt: DateTime.parse(json['created_at'] as String),
        state: DraftSyncState.fromJson(json['state'] as String),
        lastError: json['last_error'] as String?,
        // Required, not defaulted. `?? const []` here would decode a document
        // whose items key this build could not find as a draft with no punch
        // items, and the next write would make that permanent — the same
        // disappearing-work bug as filtering the list. `toJson` always writes
        // the key, so a document without it did not come from this version.
        // A non-map entry raises a TypeError from the cast rather than being
        // skipped, for the same reason.
        items: (json['items'] as List<dynamic>)
            .map((e) => LocalItem.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
      );
}
