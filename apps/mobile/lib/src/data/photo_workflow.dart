/// Photo upload and delete ordering, separated from Supabase.
///
/// Two narrow ports exist so the ordering and its compensation can be tested
/// without a network — that ordering is the part most likely to be wrong, and a
/// test that cannot force "metadata insert failed" proves nothing about it.
/// There is one production implementation of each port (in
/// supabase_repositories.dart) and one fake.
library;

import 'package:uuid/uuid.dart';

import 'models.dart';
import 'repositories.dart';

/// The bucket.
abstract interface class PhotoObjectStore {
  Future<void> put(String path, List<int> bytes, String contentType);

  Future<void> remove(String path);

  Future<String> signedUrl(String path, Duration ttl);
}

/// The `item_photos` table.
abstract interface class PhotoMetadataStore {
  Future<List<ItemPhoto>> listFor(String itemId);

  Future<ItemPhoto> insert({
    required String photoId,
    required String itemId,
    required String inspectionId,
    required String storagePath,
    required String contentType,
    required int byteSize,
  });

  /// False when the delete matched no row — which is how RLS refuses, silently.
  Future<bool> deleteById(String photoId);
}

class PhotoWorkflow implements PhotosRepository {
  PhotoWorkflow({
    required PhotoObjectStore objects,
    required PhotoMetadataStore metadata,
    required String Function() currentUserId,
    Uuid? uuid,
  })  : _objects = objects,
        _metadata = metadata,
        _currentUserId = currentUserId,
        _uuid = uuid ?? const Uuid();

  final PhotoObjectStore _objects;
  final PhotoMetadataStore _metadata;
  final String Function() _currentUserId;
  final Uuid _uuid;

  @override
  Future<List<ItemPhoto>> listFor(String itemId) => _metadata.listFor(itemId);

  /// Object first, then metadata; compensate by deleting the object if the
  /// metadata insert fails.
  ///
  /// The reverse order would briefly expose a row pointing at nothing, which
  /// renders as a broken image. This way the only failure residue is an object
  /// no query can see.
  @override
  Future<ItemPhoto> upload({
    required String inspectionId,
    required String itemId,
    required CapturedPhoto photo,
  }) async {
    final problem = PhotoLimits.validate(photo);
    if (problem != null) throw PhotoRejectedException(problem);

    // The owner segment comes from the session, never from a caller. Storage
    // policy compares segment [1] to auth.uid(), so a forged one would be
    // refused — this keeps the app from forming one at all.
    final inspectorId = _currentUserId();

    // Minted before anything is written, so the path is known up front and
    // stays recomputable from the metadata row afterwards.
    final photoId = _uuid.v4();
    final path = PhotoLimits.storagePath(
      inspectorId: inspectorId,
      inspectionId: inspectionId,
      itemId: itemId,
      photoId: photoId,
      extension: photo.extension,
    );

    await _objects.put(path, photo.bytes, photo.contentType);

    try {
      return await _metadata.insert(
        photoId: photoId,
        itemId: itemId,
        inspectionId: inspectionId,
        storagePath: path,
        contentType: photo.contentType,
        byteSize: photo.byteSize,
      );
    } catch (_) {
      // Compensate. Best effort: if this also fails, the caller still needs the
      // original error, not this one.
      try {
        await _objects.remove(path);
      } catch (_) {
        // Deliberately swallowed — see above.
      }
      rethrow;
    }
  }

  /// Metadata first, then the object (D19).
  ///
  /// An orphaned object is invisible and reclaimable; an orphaned metadata row
  /// is a broken image in the UI. If the object delete fails the row stays
  /// deleted — recreating it would resurrect a photo the user removed — and
  /// [PhotoCleanupException] is thrown so the failure is surfaced, not hidden.
  @override
  Future<void> delete(ItemPhoto photo) async {
    final removed = await _metadata.deleteById(photo.id);
    if (!removed) throw const NotPermittedException('delete this photo');

    try {
      await _objects.remove(photo.storagePath);
    } catch (e) {
      throw PhotoCleanupException(photo.storagePath, e);
    }
  }

  @override
  Future<String> signedUrl(
    ItemPhoto photo, {
    Duration ttl = const Duration(minutes: 10),
  }) =>
      _objects.signedUrl(photo.storagePath, ttl);
}
