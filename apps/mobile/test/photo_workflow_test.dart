import 'package:fieldproof/src/data/models.dart';
import 'package:fieldproof/src/data/photo_workflow.dart';
import 'package:fieldproof/src/data/repositories.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// Ordering and compensation for photo upload and delete.
///
/// This is the part most likely to be wrong, and the part a widget test cannot
/// reach: it needs to force "the metadata insert failed" and observe what
/// happens to the object. Hence the two ports.
void main() {
  late FakeObjectStore objects;
  late FakePhotoMetadataStore metadata;
  late PhotoWorkflow workflow;

  const jpeg = CapturedPhoto(bytes: [1, 2, 3], contentType: 'image/jpeg');

  setUp(() {
    objects = FakeObjectStore();
    metadata = FakePhotoMetadataStore();
    workflow = PhotoWorkflow(
      objects: objects,
      metadata: metadata,
      currentUserId: () => 'user-a',
    );
  });

  group('upload ordering', () {
    test('writes the object, then the metadata row', () async {
      final photo = await workflow.upload(
        inspectionId: 'insp-1',
        itemId: 'item-1',
        photo: jpeg,
      );

      expect(objects.objects, hasLength(1));
      expect(metadata.rows, hasLength(1));
      expect(photo.storagePath, objects.objects.keys.single);
      expect(photo.byteSize, 3);
    });

    test('the path derives from the session, not from any caller input',
        () async {
      final photo = await workflow.upload(
        inspectionId: 'insp-1',
        itemId: 'item-1',
        photo: jpeg,
      );

      // {inspector}/{inspection}/{item}/{photo}.{ext}
      final parts = photo.storagePath.split('/');
      expect(parts, hasLength(4));
      expect(parts[0], 'user-a',
          reason: 'owner segment comes from the session');
      expect(parts[1], 'insp-1');
      expect(parts[2], 'item-1');
      expect(parts[3], endsWith('.jpg'));
    });

    test('the extension follows the content type, not a filename', () async {
      const png = CapturedPhoto(bytes: [1], contentType: 'image/png');
      final photo = await workflow.upload(
        inspectionId: 'i',
        itemId: 'it',
        photo: png,
      );
      expect(photo.storagePath, endsWith('.png'));
    });

    test('two uploads of the same bytes get distinct paths', () async {
      final a = await workflow.upload(
        inspectionId: 'i',
        itemId: 'it',
        photo: jpeg,
      );
      final b = await workflow.upload(
        inspectionId: 'i',
        itemId: 'it',
        photo: jpeg,
      );
      expect(a.storagePath, isNot(b.storagePath));
      expect(objects.objects, hasLength(2));
    });
  });

  group('upload compensation', () {
    test('a failed metadata insert deletes the uploaded object', () async {
      metadata.failInsert = Exception('insert refused');

      await expectLater(
        workflow.upload(inspectionId: 'i', itemId: 'it', photo: jpeg),
        throwsA(isA<Exception>()),
      );

      // The bucket must not be left holding something nothing references.
      expect(objects.objects, isEmpty);
      expect(objects.removed, hasLength(1));
      expect(metadata.rows, isEmpty);
    });

    test('the original error survives a failing compensation', () async {
      metadata.failInsert = const PhotoRejectedException('the real cause');
      objects.failRemove = Exception('cleanup also failed');

      // The caller needs to know why the upload failed, not why the tidy-up did.
      await expectLater(
        workflow.upload(inspectionId: 'i', itemId: 'it', photo: jpeg),
        throwsA(isA<PhotoRejectedException>()),
      );
    });

    test('a failed object upload writes no metadata', () async {
      objects.failPut = Exception('bucket refused');

      await expectLater(
        workflow.upload(inspectionId: 'i', itemId: 'it', photo: jpeg),
        throwsA(isA<Exception>()),
      );
      expect(metadata.rows, isEmpty);
    });
  });

  group('guards', () {
    test('rejects an oversized image before uploading anything', () async {
      final big = CapturedPhoto(
        bytes: List.filled(PhotoLimits.maxBytes + 1, 0),
        contentType: 'image/jpeg',
      );

      await expectLater(
        workflow.upload(inspectionId: 'i', itemId: 'it', photo: big),
        throwsA(isA<PhotoRejectedException>()),
      );
      expect(objects.objects, isEmpty);
      expect(metadata.rows, isEmpty);
    });

    test('rejects a content type the schema does not accept', () async {
      const pdf = CapturedPhoto(bytes: [1], contentType: 'application/pdf');

      await expectLater(
        workflow.upload(inspectionId: 'i', itemId: 'it', photo: pdf),
        throwsA(isA<PhotoRejectedException>()),
      );
      expect(objects.objects, isEmpty);
    });

    test('rejects empty bytes', () async {
      const empty = CapturedPhoto(bytes: [], contentType: 'image/jpeg');
      await expectLater(
        workflow.upload(inspectionId: 'i', itemId: 'it', photo: empty),
        throwsA(isA<PhotoRejectedException>()),
      );
    });
  });

  group('delete ordering (D19)', () {
    late ItemPhoto photo;

    setUp(() async {
      photo = await workflow.upload(
        inspectionId: 'i',
        itemId: 'it',
        photo: jpeg,
      );
    });

    test('removes the metadata row first, then the object', () async {
      await workflow.delete(photo);

      expect(metadata.rows, isEmpty);
      expect(objects.removed, contains(photo.storagePath));
      expect(objects.objects, isEmpty);
    });

    test('a refused metadata delete leaves the object alone', () async {
      // RLS refuses by matching zero rows. Deleting the object anyway would
      // destroy a photo the caller was not allowed to touch.
      metadata.denyDelete = true;

      await expectLater(
        workflow.delete(photo),
        throwsA(isA<NotPermittedException>()),
      );
      expect(objects.objects, hasLength(1));
      expect(objects.removed, isEmpty);
    });

    test('a failed object delete surfaces, and does not resurrect the row',
        () async {
      objects.failRemove = Exception('bucket unavailable');

      await expectLater(
        workflow.delete(photo),
        throwsA(isA<PhotoCleanupException>()),
      );

      // The row stays deleted: recreating it would bring back a photo the user
      // asked to remove. The object is orphaned but invisible, and its path is
      // recomputable, so it can be reclaimed without a queue.
      expect(metadata.rows, isEmpty);
      expect(objects.objects, hasLength(1));
    });

    test('the cleanup failure names the path it could not remove', () async {
      objects.failRemove = Exception('bucket unavailable');
      try {
        await workflow.delete(photo);
        fail('expected PhotoCleanupException');
      } on PhotoCleanupException catch (e) {
        expect(e.storagePath, photo.storagePath);
        expect(e.toString(), contains(photo.storagePath));
      }
    });
  });

  group('signed urls', () {
    test('reads go through a signed url, never a public one', () async {
      final photo = await workflow.upload(
        inspectionId: 'i',
        itemId: 'it',
        photo: jpeg,
      );
      final url = await workflow.signedUrl(photo);
      expect(url, contains('/signed/'));
      expect(url, contains(photo.storagePath));
    });
  });
}
