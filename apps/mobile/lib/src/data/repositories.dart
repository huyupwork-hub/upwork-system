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
  Future<Inspection> create(NewInspection draft);

  /// The signed-in inspector's own inspections, newest first.
  Future<List<Inspection>> listMine();
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

abstract interface class InspectionItemsRepository {
  /// Items for one inspection, in `sort_order` then `created_at`.
  Future<List<InspectionItem>> listFor(String inspectionId);

  /// Persists a new item under [inspectionId].
  Future<InspectionItem> create(String inspectionId, NewInspectionItem draft);

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
