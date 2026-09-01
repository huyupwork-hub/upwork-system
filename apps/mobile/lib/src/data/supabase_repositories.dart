/// Supabase-backed repositories.
///
/// Every call here goes through the ordinary authenticated client: the anon key
/// plus the signed-in user's JWT. There is no service-role key in this app and no
/// privileged path — the database decides what each request may see, via the
/// policies in supabase/migrations/20260831000300_rls.sql.
library;

import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'models.dart';
import 'photo_workflow.dart';
import 'repositories.dart';

class SupabaseAuthRepository implements AuthRepository {
  SupabaseAuthRepository(this._client);

  final SupabaseClient _client;

  @override
  Stream<String?> get userIdChanges =>
      _client.auth.onAuthStateChange.map((event) => event.session?.user.id);

  @override
  String? get currentUserId => _client.auth.currentUser?.id;

  @override
  Future<void> signIn({required String email, required String password}) async {
    await _client.auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );
  }

  @override
  Future<void> signOut() => _client.auth.signOut();
}

class SupabaseProfileRepository implements ProfileRepository {
  SupabaseProfileRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<Profile> loadCurrent() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) throw const NotSignedInException();

    // maybeSingle(): a missing row is a real condition to handle, not an error to
    // swallow. RLS restricts this to the caller's own row regardless of the filter.
    final row = await _client
        .from('profiles')
        .select('id, full_name, role')
        .eq('id', userId)
        .maybeSingle();

    if (row == null) throw ProfileMissingException(userId);
    return Profile.fromRow(row);
  }
}

class SupabaseInspectionsRepository implements InspectionsRepository {
  SupabaseInspectionsRepository(this._client);

  final SupabaseClient _client;

  static const String _columns =
      'id, inspector_id, site_name, site_address, client_name, '
      'inspection_date, status, submitted_at, created_at';

  @override
  Future<Inspection> create(NewInspection draft) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) throw const NotSignedInException();

    final row = await _client
        .from('inspections')
        .insert(draft.toInsert(inspectorId: userId))
        .select(_columns)
        .single();

    return Inspection.fromRow(row);
  }

  @override
  Future<List<Inspection>> listMine() => _query(null);

  @override
  Future<List<Inspection>> searchMine(String query) {
    final tsQuery = InspectionSearch.toTsQuery(query);
    // Nothing searchable in what was typed — punctuation, or whitespace. Show
    // the history rather than an empty result the user cannot explain.
    if (tsQuery == null) return listMine();
    return _query(tsQuery);
  }

  @override
  Future<Inspection> submit(String inspectionId) async {
    if (_client.auth.currentUser == null) throw const NotSignedInException();

    // Only status. submitted_at is stamped by the inspections_enforce_submission
    // trigger, which is what stops the timestamp disagreeing with the status —
    // and stops a client choosing when it says the work was submitted.
    //
    // No inspector_id filter: the update policy already scopes this to the
    // caller's own drafts, and adding one here would turn a policy denial into
    // a filter miss, which reads the same but proves less.
    final rows = await _client
        .from('inspections')
        .update({'status': InspectionStatus.submitted.wire})
        .eq('id', inspectionId)
        .select(_columns);

    // The update policy's USING clause requires the OLD row to be a draft the
    // caller owns. When it does not match, Postgres updates zero rows and
    // returns success — so an already-submitted inspection, or someone else's,
    // arrives here as an empty list rather than an error. Treating that as a
    // successful submit would report frozen work as freshly submitted.
    if (rows.isEmpty) {
      throw const NotPermittedException('submit this inspection');
    }
    return Inspection.fromRow(rows.first);
  }

  /// One query shape for both, so history and search can never drift apart in
  /// ordering or in which columns they return.
  Future<List<Inspection>> _query(String? tsQuery) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) throw const NotSignedInException();

    // RLS already restricts this to the caller's rows; the explicit eq() is
    // defence in depth and lets the planner use the inspector_id index rather
    // than filtering after the fact.
    var builder =
        _client.from('inspections').select(_columns).eq('inspector_id', userId);

    if (tsQuery != null) {
      // Matched against the stored generated column and its GIN index, in the
      // database. The 'simple' config must match the one the column was built
      // with, or the query silently matches nothing.
      builder = builder.textSearch('search_tsv', tsQuery, config: 'simple');
    }

    final rows = await builder
        .order('inspection_date', ascending: false)
        .order('created_at', ascending: false)
        .order('id', ascending: false);

    return rows.map(Inspection.fromRow).toList(growable: false);
  }
}

class SupabaseInspectionItemsRepository implements InspectionItemsRepository {
  SupabaseInspectionItemsRepository(this._client);

  final SupabaseClient _client;

  static const String _columns =
      'id, inspection_id, sort_order, title, description, area, '
      'severity, status, created_at';

  @override
  Future<List<InspectionItem>> listFor(String inspectionId) async {
    if (_client.auth.currentUser == null) throw const NotSignedInException();

    // RLS already restricts this to inspections the caller owns; the explicit
    // filter is what selects *this* inspection, and it matches the
    // (inspection_id, sort_order) index.
    final rows = await _client
        .from('inspection_items')
        .select(_columns)
        .eq('inspection_id', inspectionId)
        .order('sort_order')
        .order('created_at');

    return rows.map(InspectionItem.fromRow).toList(growable: false);
  }

  @override
  Future<InspectionItem> create(
    String inspectionId,
    NewInspectionItem draft,
  ) async {
    if (_client.auth.currentUser == null) throw const NotSignedInException();

    // Append at the end. sort_order is non-unique by design (D7), so a race
    // producing two items with the same value is harmless — created_at breaks
    // the tie — and needs no locking.
    final existing = await listFor(inspectionId);
    final nextOrder = existing.isEmpty ? 0 : existing.last.sortOrder + 1;

    final row = await _client
        .from('inspection_items')
        .insert(
            draft.toInsert(inspectionId: inspectionId, sortOrder: nextOrder))
        .select(_columns)
        .single();

    return InspectionItem.fromRow(row);
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
    if (_client.auth.currentUser == null) throw const NotSignedInException();

    // inspection_id is deliberately absent: an item cannot be moved to another
    // inspection, which is also how it cannot be moved to another owner.
    final rows = await _client
        .from('inspection_items')
        .update({
          'title': title.trim(),
          'description': NewInspectionItem.nullIfBlank(description),
          'area': NewInspectionItem.nullIfBlank(area),
          'severity': severity.wire,
          'status': status.wire,
        })
        .eq('id', itemId)
        .select(_columns);

    // RLS denies a non-owner's UPDATE silently, by matching zero rows rather
    // than raising. Reporting success here would be a lie.
    if (rows.isEmpty) {
      throw const NotPermittedException('update this item');
    }
    return InspectionItem.fromRow(rows.first);
  }

  @override
  Future<void> delete(String itemId) async {
    if (_client.auth.currentUser == null) throw const NotSignedInException();

    final rows = await _client
        .from('inspection_items')
        .delete()
        .eq('id', itemId)
        .select('id');

    // Same silent-denial shape as update.
    if (rows.isEmpty) {
      throw const NotPermittedException('delete this item');
    }
  }
}

/// The bucket half of the photo workflow.
class SupabaseObjectStore implements PhotoObjectStore {
  SupabaseObjectStore(this._client);

  final SupabaseClient _client;

  static const String bucket = 'inspection-photos';

  @override
  Future<void> put(String path, List<int> bytes, String contentType) async {
    await _client.storage.from(bucket).uploadBinary(
          path,
          Uint8List.fromList(bytes),
          fileOptions: FileOptions(contentType: contentType),
        );
  }

  @override
  Future<void> remove(String path) async {
    await _client.storage.from(bucket).remove([path]);
  }

  @override
  Future<String> signedUrl(String path, Duration ttl) =>
      // The bucket is private; there is no public URL to fall back on.
      _client.storage.from(bucket).createSignedUrl(path, ttl.inSeconds);

  @override
  Future<List<int>> download(String path) async {
    // Authenticated read through the same policies; not a public fetch.
    final data = await _client.storage.from(bucket).download(path);
    return data;
  }
}

/// The metadata half.
class SupabasePhotoMetadataStore implements PhotoMetadataStore {
  SupabasePhotoMetadataStore(this._client);

  final SupabaseClient _client;

  static const String _columns =
      'id, item_id, inspection_id, storage_path, caption, '
      'content_type, byte_size, created_at';

  @override
  Future<List<ItemPhoto>> listFor(String itemId) async {
    if (_client.auth.currentUser == null) throw const NotSignedInException();
    final rows = await _client
        .from('item_photos')
        .select(_columns)
        .eq('item_id', itemId)
        .order('created_at');
    return rows.map(ItemPhoto.fromRow).toList(growable: false);
  }

  @override
  Future<ItemPhoto> insert({
    required String photoId,
    required String itemId,
    required String inspectionId,
    required String storagePath,
    required String contentType,
    required int byteSize,
  }) async {
    final row = await _client
        .from('item_photos')
        .insert({
          'id': photoId,
          'item_id': itemId,
          'inspection_id': inspectionId,
          'storage_path': storagePath,
          'content_type': contentType,
          'byte_size': byteSize,
        })
        .select(_columns)
        .single();
    return ItemPhoto.fromRow(row);
  }

  @override
  Future<bool> deleteById(String photoId) async {
    // RLS refuses a non-owner's delete by matching zero rows, silently, so an
    // empty result means refused rather than already-absent.
    final rows = await _client
        .from('item_photos')
        .delete()
        .eq('id', photoId)
        .select('id');
    return rows.isNotEmpty;
  }
}
