import 'package:fieldproof/src/data/models.dart';
import 'package:fieldproof/src/data/photo_workflow.dart';
import 'package:fieldproof/src/report/report_loader.dart';
import 'package:fieldproof/src/report/report_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// The snapshot is the whole contract between the database and the document:
/// everything is read once, here, and the renderer sees nothing else.
void main() {
  late FakeInspectionItemsRepository items;
  late FakeObjectStore objectStore;
  late FakePhotoMetadataStore photoMeta;
  late PhotoWorkflow photos;
  late FakeProfileRepository profiles;
  late ReportLoader loader;

  final submitted = Inspection(
    id: 'a0000000-0000-4000-8000-000000000002',
    inspectorId: 'user-1',
    siteName: 'Northgate Retail Park',
    siteAddress: '4 Northgate Way, Leeds',
    clientName: 'Cavendish Estates',
    inspectionDate: DateTime(2026, 8, 22),
    status: InspectionStatus.submitted,
    submittedAt: DateTime.utc(2026, 8, 22, 14),
  );

  final draft = Inspection(
    id: 'a0000000-0000-4000-8000-000000000001',
    inspectorId: 'user-1',
    siteName: 'Harbour View',
    inspectionDate: DateTime(2026, 8, 20),
    status: InspectionStatus.draft,
  );

  InspectionItem item(
    String id, {
    int sortOrder = 0,
    ItemSeverity severity = ItemSeverity.medium,
    ItemStatus status = ItemStatus.open,
    String? area,
    String? description,
    DateTime? createdAt,
  }) =>
      InspectionItem(
        id: id,
        inspectionId: submitted.id,
        sortOrder: sortOrder,
        title: 'Item $id',
        area: area,
        description: description,
        severity: severity,
        status: status,
        createdAt: createdAt,
      );

  setUp(() {
    items = FakeInspectionItemsRepository();
    objectStore = FakeObjectStore();
    photoMeta = FakePhotoMetadataStore();
    photos = PhotoWorkflow(
      objects: objectStore,
      metadata: photoMeta,
      currentUserId: () => 'user-1',
    );
    profiles = FakeProfileRepository();
    loader = ReportLoader(
      items: items,
      photos: photos,
      profiles: profiles,
      now: () => DateTime.utc(2026, 9, 1, 9, 30),
    );
  });

  group('eligibility', () {
    test('a draft cannot produce a report', () async {
      await expectLater(
        loader.load(draft),
        throwsA(isA<InspectionNotSubmittedException>()),
      );
    });

    test('refusing a draft does not submit it as a side effect', () async {
      await expectLater(loader.load(draft), throwsA(anything));
      // Asking to see a report must never be the act that makes an inspection
      // permanent (D21).
      expect(draft.status, InspectionStatus.draft);
    });

    test('a submitted inspection loads', () async {
      final snap = await loader.load(submitted);
      expect(snap.inspection.id, submitted.id);
    });
  });

  group('inspection fields', () {
    test('carries the fields the report prints', () async {
      final snap = await loader.load(submitted);
      expect(snap.inspection.siteName, 'Northgate Retail Park');
      expect(snap.inspection.siteAddress, '4 Northgate Way, Leeds');
      expect(snap.inspection.clientName, 'Cavendish Estates');
      expect(snap.inspection.submittedAt, isNotNull);
      expect(snap.inspector.fullName, 'Inspector Alpha');
      expect(snap.generatedAt, DateTime.utc(2026, 9, 1, 9, 30));
    });

    test('optional fields may be absent without failing', () async {
      final bare = Inspection(
        id: 'b1',
        inspectorId: 'user-1',
        siteName: 'Bare Site',
        inspectionDate: DateTime(2026, 8, 1),
        status: InspectionStatus.submitted,
        submittedAt: DateTime.utc(2026, 8, 1),
      );
      final snap = await loader.load(bare);
      expect(snap.inspection.siteAddress, isNull);
      expect(snap.inspection.clientName, isNull);
      expect(snap.items, isEmpty);
      expect(snap.summary.total, 0);
    });
  });

  group('items', () {
    test('every item is included', () async {
      items.rows.addAll(
          [item('a'), item('b', sortOrder: 1), item('c', sortOrder: 2)]);
      final snap = await loader.load(submitted);
      expect(snap.items, hasLength(3));
    });

    test('ordering is sort_order, then created_at, then id', () async {
      items.rows.addAll([
        item('z', sortOrder: 1),
        item('m', sortOrder: 0, createdAt: DateTime.utc(2026, 8, 2)),
        item('a', sortOrder: 0, createdAt: DateTime.utc(2026, 8, 1)),
      ]);
      final snap = await loader.load(submitted);
      expect(snap.items.map((i) => i.item.id).toList(), ['a', 'm', 'z']);
    });

    test('id breaks a total tie, so ordering is deterministic', () async {
      // Same sort_order, same (null) timestamp: without the id tiebreak two
      // runs over identical data could disagree.
      items.rows.addAll([item('c'), item('a'), item('b')]);
      final first = await loader.load(submitted);
      final second = await loader.load(submitted);
      expect(first.items.map((i) => i.item.id).toList(), ['a', 'b', 'c']);
      expect(
        second.items.map((i) => i.item.id).toList(),
        first.items.map((i) => i.item.id).toList(),
      );
    });
  });

  group('summary counts', () {
    test('counts open and resolved', () async {
      items.rows.addAll([
        item('a'),
        item('b', sortOrder: 1, status: ItemStatus.resolved),
        item('c', sortOrder: 2, status: ItemStatus.resolved),
      ]);
      final snap = await loader.load(submitted);
      expect(snap.summary.total, 3);
      expect(snap.summary.open, 1);
      expect(snap.summary.resolved, 2);
    });

    test('counts every severity, including the ones with none', () async {
      items.rows.addAll([
        item('a', severity: ItemSeverity.critical),
        item('b', sortOrder: 1, severity: ItemSeverity.critical),
        item('c', sortOrder: 2, severity: ItemSeverity.low),
      ]);
      final snap = await loader.load(submitted);
      expect(snap.summary.bySeverity[ItemSeverity.critical], 2);
      expect(snap.summary.bySeverity[ItemSeverity.low], 1);
      // Present as an explicit zero: a report that omits "High" reads as though
      // the question was never asked.
      expect(snap.summary.bySeverity[ItemSeverity.high], 0);
      expect(snap.summary.bySeverity[ItemSeverity.medium], 0);
    });

    test('an empty punch list summarises as zeroes, not as an error', () async {
      final snap = await loader.load(submitted);
      expect(snap.summary.total, 0);
      expect(snap.summary.open, 0);
      expect(snap.summary.bySeverity.values.every((v) => v == 0), isTrue);
    });
  });

  group('photos', () {
    Future<ItemPhoto> attach(String itemId, {DateTime? createdAt}) async {
      final p = await photos.upload(
        inspectionId: submitted.id,
        itemId: itemId,
        photo: const CapturedPhoto(bytes: [1, 2, 3], contentType: 'image/png'),
      );
      if (createdAt != null) {
        final i = photoMeta.rows.indexWhere((r) => r.id == p.id);
        photoMeta.rows[i] = ItemPhoto(
          id: p.id,
          itemId: p.itemId,
          inspectionId: p.inspectionId,
          storagePath: p.storagePath,
          contentType: p.contentType,
          byteSize: p.byteSize,
          createdAt: createdAt,
        );
      }
      return p;
    }

    test('photos attach to the right item, not to all of them', () async {
      items.rows.addAll([item('a'), item('b', sortOrder: 1)]);
      await attach('a');
      await attach('a');
      await attach('b');

      final snap = await loader.load(submitted);
      expect(snap.items[0].photos, hasLength(2));
      expect(snap.items[1].photos, hasLength(1));
      expect(snap.photoCount, 3);
    });

    test('bytes are loaded once, up front', () async {
      items.rows.add(item('a'));
      await attach('a');
      final snap = await loader.load(submitted);
      expect(snap.items.single.photos.single.isAvailable, isTrue);
      expect(snap.items.single.photos.single.bytes, [1, 2, 3]);
    });

    test('an unreadable photo is recorded, not silently dropped', () async {
      items.rows.add(item('a'));
      await attach('a');
      objectStore.failDownload = StateError('object gone');

      final snap = await loader.load(submitted);
      final photo = snap.items.single.photos.single;

      // The photo is still present in the report, marked unavailable. Dropping
      // it would make the document claim there was never a photograph.
      expect(snap.items.single.photos, hasLength(1));
      expect(photo.isAvailable, isFalse);
      expect(photo.unavailableReason, contains('object gone'));
      expect(snap.hasUnavailablePhotos, isTrue);
      expect(snap.photoCount, 0);
    });

    test('photo order is created_at then id', () async {
      items.rows.add(item('a'));
      await attach('a', createdAt: DateTime.utc(2026, 8, 3));
      await attach('a', createdAt: DateTime.utc(2026, 8, 1));
      await attach('a', createdAt: DateTime.utc(2026, 8, 2));

      final snap = await loader.load(submitted);
      final dates =
          snap.items.single.photos.map((p) => p.photo.createdAt!).toList();
      expect(dates, [
        DateTime.utc(2026, 8, 1),
        DateTime.utc(2026, 8, 2),
        DateTime.utc(2026, 8, 3),
      ]);
    });
  });
}
