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
