import 'dart:typed_data';

import 'package:fieldproof/src/data/models.dart';
import 'package:fieldproof/src/report/report_renderer.dart';
import 'package:fieldproof/src/report/report_sharer.dart';
import 'package:fieldproof/src/report/report_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

/// The renderer is pure — snapshot in, bytes out — so these assert on real PDF
/// output rather than on a mock.
void main() {
  const renderer = PdfReportRenderer();

  /// A 1x1 PNG, so the image path is exercised with something a decoder accepts
  /// rather than arbitrary bytes.
  const tinyPng = <int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
    0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
    0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82,
  ];

  Inspection inspection({String? address, String? client}) => Inspection(
    id: 'a0000000-0000-4000-8000-000000000002',
    inspectorId: 'user-1',
    siteName: 'Northgate Retail Park',
    siteAddress: address,
    clientName: client,
    inspectionDate: DateTime(2026, 8, 22),
    status: InspectionStatus.submitted,
    submittedAt: DateTime.utc(2026, 8, 22, 14),
  );

  ReportItem reportItem(
    int n, {
    List<ReportPhoto> photos = const [],
    String? area,
    String? description,
    ItemSeverity severity = ItemSeverity.medium,
    ItemStatus status = ItemStatus.open,
  }) => ReportItem(
    item: InspectionItem(
      id: 'item-$n',
      inspectionId: 'a0000000-0000-4000-8000-000000000002',
      sortOrder: n,
      title: 'Defect number $n',
      area: area,
      description: description,
      severity: severity,
      status: status,
    ),
    photos: photos,
  );

  ReportSnapshot snapshot({
    List<ReportItem> items = const [],
    String? address = '4 Northgate Way, Leeds',
    String? client = 'Cavendish Estates',
  }) => ReportSnapshot(
    inspection: inspection(address: address, client: client),
    inspector: const Profile(
      id: 'user-1',
      fullName: 'Inspector Alpha',
      role: 'inspector',
    ),
    items: items,
    generatedAt: DateTime.utc(2026, 9, 1, 9, 30),
  );

  String head(Uint8List bytes) =>
      String.fromCharCodes(bytes.take(8)); // '%PDF-1.x'

  String tail(Uint8List bytes) =>
      String.fromCharCodes(bytes.skip(bytes.length - 32));

  group('produces a valid PDF', () {
    test('an empty punch list still renders a complete document', () async {
      final bytes = await renderer.render(snapshot());

      expect(head(bytes), startsWith('%PDF-'));
      expect(tail(bytes), contains('%%EOF'));
      expect(bytes.length, greaterThan(1000));
    });

    test('a populated report renders', () async {
      final bytes = await renderer.render(
        snapshot(
          items: [
            reportItem(1, area: 'Plant room', description: 'Cover missing.'),
            reportItem(2, severity: ItemSeverity.critical),
            reportItem(3, status: ItemStatus.resolved),
          ],
        ),
      );

      expect(head(bytes), startsWith('%PDF-'));
      expect(tail(bytes), contains('%%EOF'));
    });

    test('absent optional fields do not break rendering', () async {
      // No address, no client, and items with neither area nor description.
      final bytes = await renderer.render(
        snapshot(address: null, client: null, items: [reportItem(1)]),
      );
      expect(head(bytes), startsWith('%PDF-'));
      expect(tail(bytes), contains('%%EOF'));
    });
  });

  group('photos', () {
    test('embeds an available photo', () async {
      final withPhoto = await renderer.render(
        snapshot(
          items: [
            reportItem(
              1,
              photos: [
                ReportPhoto.available(
                  const ItemPhoto(
                    id: 'p1',
                    itemId: 'item-1',
                    inspectionId: 'a0000000-0000-4000-8000-000000000002',
                    storagePath: 'u/i/it/p1.png',
                    contentType: 'image/png',
                    byteSize: 68,
                  ),
                  tinyPng,
                ),
              ],
            ),
          ],
        ),
      );
      final withoutPhoto = await renderer.render(
        snapshot(items: [reportItem(1)]),
      );

      expect(head(withPhoto), startsWith('%PDF-'));
      // The image has to land in the document, so it must be materially bigger.
      expect(withPhoto.length, greaterThan(withoutPhoto.length));
    });

    test('an unavailable photo renders a placeholder rather than failing',
        () async {
      final bytes = await renderer.render(
        snapshot(
          items: [
            reportItem(
              1,
              photos: [
                const ReportPhoto.unavailable(
                  ItemPhoto(
                    id: 'p1',
                    itemId: 'item-1',
                    inspectionId: 'a0000000-0000-4000-8000-000000000002',
                    storagePath: 'u/i/it/p1.png',
                    contentType: 'image/png',
                    byteSize: 68,
                  ),
                  'object gone',
                ),
              ],
            ),
          ],
        ),
      );

      expect(head(bytes), startsWith('%PDF-'));
      expect(tail(bytes), contains('%%EOF'));
    });
  });

  group('multipage', () {
    test('many items produce a longer document without failing', () async {
      final small = await renderer.render(
        snapshot(items: [for (var i = 0; i < 3; i++) reportItem(i)]),
      );
      final large = await renderer.render(
        snapshot(
          items: [
            for (var i = 0; i < 60; i++)
              reportItem(
                i,
                area: 'Zone $i',
                description: 'A description long enough to occupy a line or '
                    'two of the page so the document is forced to break.',
              ),
          ],
        ),
      );

      expect(head(large), startsWith('%PDF-'));
      expect(tail(large), contains('%%EOF'));
      expect(large.length, greaterThan(small.length));
      // 60 items cannot fit on one A4 page, so MultiPage must have broken it.
      expect(_countPages(large), greaterThan(1));
    });
  });

  group('determinism', () {
    test('the same snapshot renders to the same length twice', () async {
      final snap = snapshot(items: [reportItem(1), reportItem(2)]);
      final a = await renderer.render(snap);
      final b = await renderer.render(snap);

      // Byte-identical is not guaranteed — PDF carries a creation date — but the
      // structure must not vary between runs over the same data.
      expect(a.length, b.length);
      expect(_countPages(a), _countPages(b));
    });
  });

  group('filename', () {
    test('is derived from the site, date and id', () {
      final name = reportFilename(snapshot());
      expect(name, startsWith('fieldproof-northgate-retail-park-20260822-'));
      expect(name, endsWith('.pdf'));
    });

    test('a site name of only punctuation still yields a usable name', () {
      final snap = ReportSnapshot(
        inspection: Inspection(
          id: 'a0000000-0000-4000-8000-000000000002',
          inspectorId: 'u',
          siteName: '///',
          inspectionDate: DateTime(2026, 1, 2),
          status: InspectionStatus.submitted,
        ),
        inspector: const Profile(id: 'u', fullName: 'A', role: 'inspector'),
        items: const [],
        generatedAt: DateTime.utc(2026, 1, 2),
      );
      expect(reportFilename(snap), startsWith('fieldproof-inspection-20260102-'));
    });
  });
}

/// Counts page objects in the raw PDF. Crude, but enough to tell one page from
/// several without pulling in a parser.
int _countPages(Uint8List bytes) =>
    RegExp(r'/Type\s*/Page[^s]').allMatches(String.fromCharCodes(bytes)).length;
