/// Repository contracts.
///
/// These interfaces exist for one reason: the widget tests need a seam that does
/// not reach the network. They are not a speculative abstraction layer — there is
/// exactly one production implementation of each, in supabase_repositories.dart.
library;

import 'models.dart';

abstract interface class AuthRepository {
  /// Emits whenever the session appears or disappears.
  Stream<String?> get userIdChanges;

  /// The signed-in user's id, or null.
  String? get currentUserId;

  Future<void> signIn({required String email, required String password});

  Future<void> signOut();
}

abstract interface class ProfileRepository {
  /// The signed-in user's profile.
  ///
  /// Created by the `on_auth_user_created` trigger, so it should always exist.
  /// Throws [ProfileMissingException] if it does not, rather than inventing one —
  /// a missing profile means the schema bootstrap failed and must be visible.
  Future<Profile> loadCurrent();
}

abstract interface class InspectionsRepository {
  /// Persists a draft. `inspector_id` comes from the live session.
  ///
  /// [id] is the row's primary key, device-generated (D5). Callers normally
  /// leave it null and the repository mints one. The offline path supplies it,
  /// because it has to know the id *before* the write is attempted: if the
  /// insert reaches Postgres and the response never comes back, the draft is
  /// stashed locally under that same id and the later sync upserts onto the row
  /// that already exists. Without a shared key that case is a duplicate.
  Future<Inspection> create(NewInspection draft, {String? id});

  /// The signed-in inspector's own inspections, newest first.
  ///
  /// Ordered inspection_date DESC, then created_at DESC, then id DESC. The last
  /// key is what makes the order total: without it two inspections recorded on
  /// the same day and written in the same transaction could come back in either
  /// order between calls.
  Future<List<Inspection>> listMine();

  /// The same list, narrowed by a free-text query over site name, address and
  /// client.
  ///
  /// Server-side, through the stored tsvector and its GIN index. Ownership stays
  /// with RLS — no inspector id is sent from the UI — so a query can only ever
  /// range over rows the caller could already read.
  Future<List<Inspection>> searchMine(String query);

  /// Moves a draft to `submitted`. One way — there is no unsubmit (D10).
  ///
  /// Only `status` is sent. `submitted_at` is stamped by the database trigger,
  /// so the timestamp cannot disagree with the status and a client cannot
  /// backdate a submission.
  ///
  /// Once this returns, the record is frozen (D17): every later write, to the
  /// inspection or its items, photos and storage objects, is refused by policy
  /// rather than by the UI. Submitting is also what makes the work visible to a
  /// reviewer (D3), so it is deliberately not something to do by accident.
  ///
  /// Throws [NotPermittedException] if the row was not a draft the caller owns.
  /// RLS denies this update by matching zero rows rather than raising, so the
  /// absence of an error is not evidence that anything changed.
  Future<Inspection> submit(String inspectionId);
}

class ProfileMissingException implements Exception {
  const ProfileMissingException(this.userId);
  final String userId;

  @override
  String toString() =>
      'No profile row for user $userId. The on_auth_user_created trigger '
      'should have created one; the account may predate the migration.';
}

class NotSignedInException implements Exception {
  const NotSignedInException();

  @override
  String toString() => 'No active session.';
}

/// The inspection exists only on this device and has not reached Supabase yet.
///
/// Raised by `submit`, and the reason offline submission is not merely absent
/// from the UI but refused at the boundary. `submitted_at` is stamped by a
/// database trigger and D17 immutability is a database rule; a locally
/// "submitted" flag would be a claim no server ever made, and there would be
/// nothing to unwind once it turned out to be false.
class DraftNotSyncedException implements Exception {
  const DraftNotSyncedException(this.inspectionId);
  final String inspectionId;

  @override
  String toString() =>
      'This inspection has not synced yet. It can be submitted once it has '
      'reached the server.';
}

abstract interface class InspectionItemsRepository {
  /// Items for one inspection, in `sort_order` then `created_at`.
  Future<List<InspectionItem>> listFor(String inspectionId);

  /// Persists a new item under [inspectionId].
  ///
  /// [id] is device-generated, on the same terms as an inspection's.
  Future<InspectionItem> create(
    String inspectionId,
    NewInspectionItem draft, {
    String? id,
  });

  /// Updates the editable fields of an existing item.
  Future<InspectionItem> update(
    String itemId, {
    required String title,
    String? description,
    String? area,
    required ItemSeverity severity,
    required ItemStatus status,
  });

  Future<void> delete(String itemId);
}

/// Raised when the database accepted the request but changed nothing, which is
/// how RLS denies an UPDATE or DELETE — zero rows matched, no error.
///
/// Without this the app would report a silent denial as success, which is the
/// exact failure the pgTAP suite tests for at the database level.
class NotPermittedException implements Exception {
  const NotPermittedException(this.action);
  final String action;

  @override
  String toString() =>
      'Not permitted to $action. It may belong to another inspector.';
}

/// Where photo bytes come from.
///
/// This exists so the widget tests never touch a platform channel. There is one
/// production implementation (`ImagePickerPhotoSource`) and one fake; it is not
/// a media abstraction layer, just the seam at the plugin boundary.
abstract interface class PhotoSource {
  /// Null when the user cancels — cancelling is not an error.
  Future<CapturedPhoto?> capture();

  Future<CapturedPhoto?> pickFromGallery();
}

abstract interface class PhotosRepository {
  /// Photos attached to one item, oldest first.
  Future<List<ItemPhoto>> listFor(String itemId);

  /// Uploads the object, then inserts its metadata row.
  ///
  /// If the metadata insert fails, the just-uploaded object is deleted so the
  /// bucket is not left holding something nothing references.
  Future<ItemPhoto> upload({
    required String inspectionId,
    required String itemId,
    required CapturedPhoto photo,
  });

  /// Deletes the metadata row first, then the object.
  ///
  /// That order is deliberate: an orphaned object is invisible and reclaimable,
  /// whereas an orphaned metadata row renders as a broken image. If the object
  /// delete fails afterwards the row stays deleted and [PhotoCleanupException]
  /// is thrown so the failure is visible rather than silently swallowed.
  Future<void> delete(ItemPhoto photo);

  /// A short-lived signed URL. The bucket is private; there is no public URL.
  Future<String> signedUrl(ItemPhoto photo, {Duration ttl});

  /// The object's bytes, for embedding in a report.
  ///
  /// Goes through the same private path and the same policies as everything
  /// else — it is a read the caller was already entitled to, not a new access
  /// route. Throws if the object cannot be read; the report says so explicitly
  /// rather than dropping the photo.
  Future<List<int>> bytes(ItemPhoto photo);
}

/// The metadata row was deleted but its Storage object could not be.
///
/// Deliberately not a silent failure and deliberately not a rollback: the row is
/// gone, and recreating it would resurrect a photo the user asked to remove.
/// The object is orphaned, invisible to every query, and its path is
/// recomputable from the id, so it can be reclaimed later without a queue.
class PhotoCleanupException implements Exception {
  const PhotoCleanupException(this.storagePath, this.cause);

  final String storagePath;
  final Object cause;

  @override
  String toString() =>
      'The photo was removed, but its stored file could not be deleted '
      '($storagePath): $cause';
}

/// The photo failed the client-side size or content-type guard.
///
/// The same limits exist as CHECK constraints on `item_photos` and on the
/// bucket; this stops a doomed upload before it spends the user's bandwidth.
class PhotoRejectedException implements Exception {
  const PhotoRejectedException(this.message);
  final String message;

  @override
  String toString() => message;
}
