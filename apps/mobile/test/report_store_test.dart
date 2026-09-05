import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fieldproof/src/data/models.dart';
import 'package:fieldproof/src/data/photo_workflow.dart';
import 'package:fieldproof/src/report/report_loader.dart';
import 'package:fieldproof/src/report/report_service.dart';
import 'package:fieldproof/src/report/report_sharer.dart';
import 'package:fieldproof/src/report/report_snapshot.dart';
import 'package:fieldproof/src/report/report_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'fakes.dart';

/// The upload half of the report (D21 amended, D31), against the fakes.
///
/// Nothing here is evidence about the bucket's policies — pgTAP `110` and the
/// hosted smoke own those. What these tests own is the client contract: the
/// one name the app forms, whose session it is formed from, what is and is not
/// touched when each step fails, and that the share path never reaches the
/// bucket.
void main() {
  late FakeInspectionsRepository inspections;
  late FakeInspectionItemsRepository items;
  late FakeObjectStore objectStore;
  late FakePhotoMetadataStore photoMeta;
  late FakeProfileRepository profiles;
  late FakeReportRenderer renderer;
  late FakeReportSharer sharer;
  late FakeReportStore store;
  late ReportService service;

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

  Inspection submittedWith(String id) => Inspection(
        id: id,
        inspectorId: 'user-1',
        siteName: 'Site $id',
        inspectionDate: DateTime(2026, 8, 22),
        status: InspectionStatus.submitted,
        submittedAt: DateTime.utc(2026, 8, 22, 14),
      );

  String pathOf(String inspectionId) =>
      reportStoragePath(inspectorId: 'user-1', inspectionId: inspectionId);

  setUp(() {
    inspections = FakeInspectionsRepository();
    items = FakeInspectionItemsRepository();
    objectStore = FakeObjectStore();
    photoMeta = FakePhotoMetadataStore();
    profiles = FakeProfileRepository();
    renderer = FakeReportRenderer();
    sharer = FakeReportSharer();
    store = FakeReportStore();
    service = ReportService(
      loader: ReportLoader(
        items: items,
        photos: PhotoWorkflow(
          objects: objectStore,
          metadata: photoMeta,
          currentUserId: () => 'user-1',
        ),
        profiles: profiles,
      ),
      renderer: renderer,
      sharer: sharer,
      store: store,
      currentUserId: () => 'user-1',
    );
  });

  group('reportStoragePath', () {
    test('is the exact literal the INSERT policy pins', () {
      // The SQL side builds inspector_id || '/' || id || '/report.pdf' and
      // admits nothing else; pgTAP 110 pins that half, this pins ours.
      expect(
        reportStoragePath(inspectorId: 'u', inspectionId: 'i'),
        'u/i/report.pdf',
      );
    });
  });

  group('publish', () {
    test('runs loader, renderer and store in that order and stores the bytes',
        () async {
      final stages = <ReportStage>[];
      await service.publish(submitted, onStage: (stage) {
        stages.add(stage);
        // Observed at the moment each stage is announced, so the order is a
        // fact about interleaving, not about which lists ended up non-empty.
        if (stage == ReportStage.rendering) {
          expect(renderer.rendered, isEmpty);
          expect(store.puts, isEmpty);
        }
        if (stage == ReportStage.publishing) {
          expect(renderer.rendered, hasLength(1));
          expect(store.puts, isEmpty);
        }
      });

      expect(stages, [
        ReportStage.loading,
        ReportStage.rendering,
        ReportStage.publishing,
      ]);
      expect(renderer.rendered.single.inspection.id, submitted.id);
      expect(store.puts, [pathOf(submitted.id)]);
      expect(store.objects[pathOf(submitted.id)], '%PDF-1.7 fake'.codeUnits);
      expect(sharer.shared, isEmpty);
    });

    test('takes the owner segment from the session, never from the row',
        () async {
      final foreign = Inspection(
        id: submitted.id,
        inspectorId: 'someone-else',
        siteName: submitted.siteName,
        inspectionDate: submitted.inspectionDate,
        status: InspectionStatus.submitted,
        submittedAt: submitted.submittedAt,
      );

      await service.publish(foreign);

      // The policy would refuse a forged owner segment; the app never forms
      // one, so a row that lies about its owner cannot make it try.
      expect(store.puts, ['user-1/${submitted.id}/report.pdf']);
      expect(
        store.objects.keys.where((k) => k.startsWith('someone-else/')),
        isEmpty,
      );
    });

    test(
        'refuses a draft before anything is rendered or put, and submits '
        'nothing', () async {
      inspections.rows.add(draft);
      final stages = <ReportStage>[];

      await expectLater(
        service.publish(draft, onStage: stages.add),
        throwsA(isA<InspectionNotSubmittedException>()),
      );

      expect(stages, [ReportStage.loading]);
      expect(renderer.rendered, isEmpty);
      expect(store.puts, isEmpty);
      // Asking to publish must never be the act that makes an inspection
      // permanent (D21); the record is untouched.
      expect(inspections.submitted, isEmpty);
      expect(draft.status, InspectionStatus.draft);
    });

    test('a renderer failure puts nothing', () async {
      renderer.failWith = StateError('font missing');

      await expectLater(
        service.publish(submitted),
        throwsA(isA<StateError>()),
      );

      expect(store.puts, isEmpty);
    });

    test(
        'a rendering over the cap raises ReportTooLargeException and puts '
        'nothing', () async {
      renderer.output = Uint8List(ReportLimits.maxBytes + 1);
      final stages = <ReportStage>[];

      await expectLater(
        service.publish(submitted, onStage: stages.add),
        throwsA(
          isA<ReportTooLargeException>()
              .having((e) => e.bytes, 'bytes', ReportLimits.maxBytes + 1)
              .having((e) => '$e', 'copy', contains('over the 50 MB limit'))
              .having(
                (e) => '$e',
                'copy',
                contains('Sharing it from this device still works'),
              ),
        ),
      );

      // Refused before the upload stage is even announced.
      expect(stages, [ReportStage.loading, ReportStage.rendering]);
      expect(store.puts, isEmpty);
    });

    test('exactly the cap is not over it', () async {
      renderer.output = Uint8List(ReportLimits.maxBytes);
      await service.publish(submitted);
      expect(store.puts, hasLength(1));
    });

    test(
        'a store failure with no signal raises ReportPublishException with '
        'transport true', () async {
      const cause = SocketException('no route to host');
      store.failPut = cause;

      await expectLater(
        service.publish(submitted),
        throwsA(
          isA<ReportPublishException>()
              .having((e) => e.inspectionId, 'inspectionId', submitted.id)
              .having((e) => e.cause, 'cause', same(cause))
              .having((e) => e.transport, 'transport', isTrue)
              // The submission is permanent; the copy says so before anything
              // else, so a failed upload never reads as a failed submit.
              .having(
                (e) => '$e',
                'copy',
                startsWith('The inspection was submitted.'),
              )
              .having((e) => '$e', 'copy', contains('could not be reached')),
        ),
      );

      // The attempt is recorded and nothing landed.
      expect(store.puts, [pathOf(submitted.id)]);
      expect(store.objects, isEmpty);
    });

    test(
        'a store refusal raises ReportPublishException with transport false '
        'and the cause verbatim', () async {
      const cause = StorageException(
        'new row violates row-level security policy',
        statusCode: '403',
        error: 'Unauthorized',
      );
      store.failPut = cause;

      await expectLater(
        service.publish(submitted),
        throwsA(
          isA<ReportPublishException>()
              .having((e) => e.cause, 'cause', same(cause))
              .having((e) => e.transport, 'transport', isFalse)
              .having(
                (e) => '$e',
                'copy',
                startsWith('The inspection was submitted.'),
              )
              // A refusal is shown verbatim, the repository's rule — never
              // dressed up as "no signal" (D25).
              .having((e) => '$e', 'copy', contains('$cause'))
              .having(
                (e) => '$e',
                'copy',
                isNot(contains('could not be reached')),
              ),
        ),
      );
    });

    test('a store timeout is a transport failure', () async {
      store.failPut = TimeoutException('upload', const Duration(seconds: 120));

      await expectLater(
        service.publish(submitted),
        throwsA(
          isA<ReportPublishException>()
              .having((e) => e.transport, 'transport', isTrue),
        ),
      );
    });
  });

  group('published', () {
    test('mirrors the store for the session user', () async {
      store.objects[pathOf('insp-a')] = Uint8List(1);
      store.objects[pathOf('insp-b')] = Uint8List(1);
      store.objects['someone-else/insp-c/report.pdf'] = Uint8List(1);

      expect(await service.published(), {'insp-a', 'insp-b'});
    });

    test('is empty when nothing has been uploaded', () async {
      expect(await service.published(), isEmpty);
    });

    test('rethrows when the bucket could not be read', () async {
      // "Could not check" is not "not uploaded" (D28): the caller has to see
      // the failure to say so, rather than an empty set it would read as none.
      store.failPublished = const SocketException('no route to host');
      await expectLater(
        service.published(),
        throwsA(isA<SocketException>()),
      );
    });
  });

  group('generateAndShare', () {
    test('never touches the store', () async {
      await service.generateAndShare(submitted);

      expect(sharer.shared, hasLength(1));
      expect(store.puts, isEmpty);
      expect(store.objects, isEmpty);
    });

    test('shares under the same name the stored rendering is downloaded as',
        () async {
      await service.generateAndShare(submitted);
      expect(
        sharer.filenames.single,
        'fieldproof-northgate-retail-park-20260822-a0000000.pdf',
      );
    });
  });

  group('publishMissing', () {
    final a = submittedWith('insp-a');
    final b = submittedWith('insp-b');
    final c = submittedWith('insp-c');

    test('publishes only the ids absent from the store, in the order given',
        () async {
      store.objects[pathOf(b.id)] = Uint8List(1);
      final seen = <String>[];

      final report = await service.publishMissing(
        [c, b, a],
        onStage: (inspection, stage) {
          if (stage == ReportStage.publishing) seen.add(inspection.id);
        },
      );

      expect(report.published, ['insp-c', 'insp-a']);
      expect(report.failed, isEmpty);
      expect(report.skipped, isEmpty);
      expect(report.lastError, isNull);
      expect(seen, ['insp-c', 'insp-a']);
      // The one already there was neither re-rendered nor re-uploaded.
      expect(store.puts, [pathOf(c.id), pathOf(a.id)]);
      expect(
          renderer.rendered.map((s) => s.inspection.id), ['insp-c', 'insp-a']);
    });

    test('stops at the first transport failure and reports the rest as skipped',
        () async {
      store.objects[pathOf(a.id)] = Uint8List(1);
      store.failPut = const SocketException('no route to host');

      final report = await service.publishMissing([a, b, c]);

      expect(report.published, isEmpty);
      expect(report.failed, ['insp-b']);
      expect(report.skipped, ['insp-c']);
      expect(report.lastError, contains('could not be reached'));
      // One attempt: the third was never tried, and nothing was re-rendered
      // for it either (D25 — no wasted work once the server is silent).
      expect(store.puts, [pathOf(b.id)]);
      expect(renderer.rendered, hasLength(1));
    });

    test('continues past a refusal and reports it', () async {
      const refusal = StorageException(
        'new row violates row-level security policy',
        statusCode: '403',
        error: 'Unauthorized',
      );
      store.failPut = refusal;

      final report = await service.publishMissing([a, b]);

      expect(report.published, isEmpty);
      expect(report.failed, ['insp-a', 'insp-b']);
      expect(report.skipped, isEmpty);
      expect(report.lastError, contains('$refusal'));
      // Both were attempted: a refusal is about this inspection only.
      expect(store.puts, [pathOf(a.id), pathOf(b.id)]);
    });

    test('continues past a photograph the bucket would not hand over',
        () async {
      // Only b carries a photograph, and that photograph cannot be read: b is
      // reported and c still gets its turn.
      final item =
          await items.create(b.id, const NewInspectionItem(title: 'x'));
      await photoMeta.insert(
        photoId: 'photo-1',
        itemId: item.id,
        inspectionId: b.id,
        storagePath: 'user-1/${b.id}/${item.id}/photo-1.jpg',
        contentType: 'image/jpeg',
        byteSize: 4,
      );
      objectStore.failDownload = const StorageException(
        'Object not found',
        statusCode: '404',
        error: 'not_found',
      );

      final report = await service.publishMissing([a, b, c]);

      expect(report.published, ['insp-a', 'insp-c']);
      expect(report.failed, ['insp-b']);
      expect(report.skipped, isEmpty);
      expect(report.lastError, contains('a photograph could not be retrieved'));
      expect(store.puts, [pathOf(a.id), pathOf(c.id)]);
    });

    test('a photograph unreachable for want of signal stops the loop',
        () async {
      final item =
          await items.create(b.id, const NewInspectionItem(title: 'x'));
      await photoMeta.insert(
        photoId: 'photo-1',
        itemId: item.id,
        inspectionId: b.id,
        storagePath: 'user-1/${b.id}/${item.id}/photo-1.jpg',
        contentType: 'image/jpeg',
        byteSize: 4,
      );
      objectStore.failDownload = const SocketException('no route to host');

      final report = await service.publishMissing([a, b, c]);

      expect(report.published, ['insp-a']);
      expect(report.failed, ['insp-b']);
      expect(report.skipped, ['insp-c']);
    });

    test(
        'never throws when the bucket could not be read, and attempts '
        'nothing', () async {
      store.failPublished = const SocketException('no route to host');

      final report = await service.publishMissing([a, b]);

      // Without the listing "missing" is a guess, and a guess would re-render
      // every report the inspector already has.
      expect(report.published, isEmpty);
      expect(report.failed, isEmpty);
      expect(report.skipped, ['insp-a', 'insp-b']);
      // No signal is worded as no signal, not as the socket's own message —
      // the same copy the upload's transport failure carries.
      expect(report.lastError, contains('could not be reached'));
      expect(report.lastError, isNot(contains('no route to host')));
      expect(store.puts, isEmpty);
      expect(renderer.rendered, isEmpty);
    });

    test('a listing refused by the server is reported verbatim', () async {
      store.failPublished = const StorageException(
        'new row violates row-level security policy',
        statusCode: '403',
      );

      final report = await service.publishMissing([a]);

      expect(report.skipped, ['insp-a']);
      expect(report.lastError, contains('row-level security'));
    });

    test('a second run over the same fakes publishes nothing', () async {
      final first = await service.publishMissing([a, b, c]);
      expect(first.published, ['insp-a', 'insp-b', 'insp-c']);
      final putsAfterFirst = [...store.puts];

      final second = await service.publishMissing([a, b, c]);

      expect(second.published, isEmpty);
      expect(second.failed, isEmpty);
      expect(second.skipped, isEmpty);
      expect(second.lastError, isNull);
      expect(store.puts, putsAfterFirst);
    });

    test('an empty list is a no-op with an empty report', () async {
      final report = await service.publishMissing(const []);
      expect(report.published, isEmpty);
      expect(report.failed, isEmpty);
      expect(report.skipped, isEmpty);
      expect(store.puts, isEmpty);
    });
  });

  group('reportFilenameFor', () {
    // The console derives the same name (apps/admin/src/lib/report_filename.ts)
    // and its test pins these two strings; change one, change both.
    test('pins site slug, date and the first eight hex of the id', () {
      expect(
        reportFilenameFor(submitted),
        'fieldproof-northgate-retail-park-20260822-a0000000.pdf',
      );
    });

    test('falls back to "inspection" when the site name has nothing to slug',
        () {
      final unnamed = Inspection(
        id: 'f0e1d2c3-0000-4000-8000-000000000009',
        inspectorId: 'user-1',
        siteName: '???',
        inspectionDate: DateTime(2026, 1, 2),
        status: InspectionStatus.submitted,
      );
      expect(
        reportFilenameFor(unnamed),
        'fieldproof-inspection-20260102-f0e1d2c3.pdf',
      );
    });

    test('the snapshot name is the record name', () {
      final snapshot = ReportSnapshot(
        inspection: submitted,
        inspector: const Profile(
          id: 'user-1',
          fullName: 'Inspector Alpha',
          role: 'inspector',
        ),
        items: const [],
        generatedAt: DateTime.utc(2026, 9, 5),
      );
      expect(reportFilename(snapshot), reportFilenameFor(submitted));
    });
  });
}
