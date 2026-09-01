/// The one-way handoff: local authority → Supabase authority.
///
/// A draft created offline is authoritative on the device until this succeeds,
/// and never afterwards. There is no merge, no conflict resolution and no
/// last-write-wins, because there is nothing to merge: D5 restricts the offline
/// scope to inspections that have never been pushed, so until the moment below
/// the row exists in exactly one place.
library;

import '../data/models.dart';
import '../data/repositories.dart';
import 'draft_store.dart';
import 'local_draft.dart';
import 'offline_status.dart';

/// The remote half of a push.
///
/// A port for the same reason `PhotoObjectStore` is one (D19): the ordering and
/// its failure behaviour are the part most likely to be wrong, and a test that
/// cannot force "the items failed after the inspection landed" proves nothing
/// about it. One production implementation, in `supabase_repositories.dart`, and
/// one fake.
///
/// Every method runs as the ordinary authenticated session. There is no
/// privileged path here and no `inspector_id` is ever accepted from the caller
/// as authority — RLS decides, exactly as it does for the online path.
abstract interface class RemoteDraftSink {
  /// Upserts the inspection on its device-generated primary key.
  ///
  /// Merge rather than ignore-duplicates: a partially synced draft stays
  /// editable on the device, so a retry has to carry whatever changed since the
  /// attempt that failed. `ON CONFLICT DO NOTHING` would push the row once and
  /// then silently ignore every later edit.
  ///
  /// This needs no new policy. The owner UPDATE policy is
  /// `using (inspector_id = auth.uid() and status = 'draft' and not is_admin())`
  /// with a matching `WITH CHECK`, so an owner may overwrite their own draft and
  /// nobody may overwrite anyone else's — and a submitted row refuses the update
  /// entirely, which is D17 doing its job on a path it was not written for.
  Future<void> putInspection(Map<String, dynamic> row);

  /// Upserts items on their device-generated primary keys, in one statement.
  Future<void> putItems(List<Map<String, dynamic>> rows);

  /// Deletes items under [inspectionId] whose id is not in [keepIds].
  ///
  /// Reachable only when an earlier attempt pushed items and the inspector then
  /// deleted one locally before the draft finished syncing. Without it the
  /// server would keep a punch item the inspector removed, and "synced" would
  /// describe a record that does not match what is on the device.
  Future<void> pruneItems(String inspectionId, Set<String> keepIds);

  /// Reads the inspection back, or null if it is not there.
  ///
  /// Sync is not allowed to infer success from the absence of an exception. A
  /// write that was refused silently — the shape RLS uses for UPDATE and DELETE
  /// — returns no error at all, so the only honest evidence that a row exists is
  /// having read it.
  Future<Inspection?> readInspection(String id);

  /// The ids actually persisted under [inspectionId].
  Future<Set<String>> readItemIds(String inspectionId);
}

/// A push completed without error but the server does not hold what it should.
class DraftSyncException implements Exception {
  const DraftSyncException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// What one run did. Reported rather than logged, so the UI can be truthful.
class SyncReport {
  const SyncReport({
    this.synced = const [],
    this.failed = const [],
    this.lastError,
  });

  /// Ids that reached Supabase and are no longer held locally.
  final List<String> synced;

  /// Ids still on the device.
  final List<String> failed;

  final String? lastError;

  bool get isClean => failed.isEmpty;
}

/// Pushes offline-origin drafts, once each, in the order they were created.
class DraftSync {
  DraftSync({
    required LocalDraftBook local,
    required RemoteDraftSink sink,
    required AuthRepository auth,
    required OfflineStatusNotifier status,
  })  : _local = local,
        _sink = sink,
        _auth = auth,
        _status = status;

  final LocalDraftBook _local;
  final RemoteDraftSink _sink;
  final AuthRepository _auth;
  final OfflineStatusNotifier _status;

  bool _running = false;

  /// True while a run is in progress, so resume and the manual retry cannot
  /// overlap. Two concurrent runs would both upsert the same rows — harmless,
  /// because the writes are idempotent — and could both try to retire the same
  /// local record, which is not worth reasoning about when a boolean prevents
  /// it.
  bool get isRunning => _running;

  /// Pushes every pending draft belonging to the signed-in inspector.
  ///
  /// Never throws. A sync failure is a state the user is shown and can retry
  /// from, not an exception thrown out of a lifecycle callback.
  Future<SyncReport> run() async {
    if (_running) return const SyncReport();

    final userId = _auth.currentUserId;
    // No session means no ownership, and a draft pushed under an unknown
    // identity is exactly the ambiguity §3 forbids. The queue simply waits.
    if (userId == null) return const SyncReport();

    _running = true;
    _status.setSyncing(true);
    try {
      final pending = await _local.ownedBy(userId);
      final synced = <String>[];
      final failed = <String>[];
      String? lastError;

      for (final draft in pending) {
        try {
          await _push(draft, userId);
          synced.add(draft.id);
        } catch (e) {
          failed.add(draft.id);
          lastError = e.toString();
        }
      }

      // Cleared only by a run that left nothing behind, so a stale message
      // cannot outlive the problem it described.
      _status.setLastError(failed.isEmpty ? null : lastError);
      if (failed.isEmpty && synced.isNotEmpty) {
        _status.setRemoteUnavailable(false);
      }
      return SyncReport(synced: synced, failed: failed, lastError: lastError);
    } finally {
      _running = false;
      _status.setSyncing(false);
    }
  }

  /// One draft, parent before children, verified before the local copy is let
  /// go.
  ///
  /// The order of the last two steps is the whole design. Local state is retired
  /// **after** the server has been read back, so a crash at any earlier point
  /// leaves the draft on the device and the next run upserts the same keys onto
  /// the same rows. The failure mode this rules out is the expensive one: a
  /// device that deletes its only copy of an inspection because a write appeared
  /// to work.
  Future<void> _push(LocalDraft draft, String userId) async {
    await _local.put(draft.copyWith(state: DraftSyncState.syncing));

    try {
      // inspector_id comes from the live session, never from the stored record.
      await _sink.putInspection(draft.toRow(inspectorId: userId));

      final persisted = await _sink.readInspection(draft.id);
      if (persisted == null) {
        throw const DraftSyncException(
          'The inspection did not persist. Nothing was removed from this '
          'device; try syncing again.',
        );
      }
      if (persisted.inspectorId != userId) {
        // Cannot happen through RLS, which is the point of asserting it: if it
        // ever did, retiring the local copy would hand the inspector's work to
        // someone else.
        throw const DraftSyncException(
          'The server holds this inspection under a different inspector. It '
          'was left on this device.',
        );
      }

      final wanted = draft.items.map((i) => i.id).toSet();
      if (draft.items.isNotEmpty) {
        await _sink.putItems(
          draft.items.map((i) => i.toRow(draft.id)).toList(growable: false),
        );
      }
      await _sink.pruneItems(draft.id, wanted);

      final actual = await _sink.readItemIds(draft.id);
      final missing = wanted.difference(actual);
      if (missing.isNotEmpty) {
        throw DraftSyncException(
          '${missing.length} punch item(s) did not persist. The draft was left '
          'on this device; try syncing again.',
        );
      }
      final extra = actual.difference(wanted);
      if (extra.isNotEmpty) {
        throw DraftSyncException(
          'The server holds ${extra.length} punch item(s) this draft does not. '
          'The draft was left on this device.',
        );
      }

      // Proven. Supabase and RLS are now the authority for this inspection, and
      // this device stops being one.
      await _local.remove(draft.id);
    } catch (e) {
      // The draft survives every failure, with the reason attached. A retry is
      // the same upsert onto the same keys, so it cannot duplicate what the
      // failed attempt managed to write.
      await _local.put(
        draft.copyWith(
          state: DraftSyncState.localOnly,
          lastError: () => e.toString(),
        ),
      );
      if (isTransportFailure(e)) _status.setRemoteUnavailable(true);
      rethrow;
    }
  }
}
