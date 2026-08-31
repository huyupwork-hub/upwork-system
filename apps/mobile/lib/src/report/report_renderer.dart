/// Turns a [ReportSnapshot] into PDF bytes.
///
/// Pure: it takes a snapshot and returns bytes. No network, no platform channel,
/// no Supabase — which is what lets `report_renderer_test.dart` assert on real
/// output instead of on a mock.
library;

import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../data/models.dart';
import 'report_snapshot.dart';

abstract interface class ReportRenderer {
  Future<Uint8List> render(ReportSnapshot snapshot);
}

class PdfReportRenderer implements ReportRenderer {
  const PdfReportRenderer();

  static const PdfColor _ink = PdfColor.fromInt(0xFF000000);
  static const PdfColor _muted = PdfColor.fromInt(0xFF6B6B70);
  static const PdfColor _rule = PdfColor.fromInt(0xFFD8D8DC);
  static const PdfColor _brand = PdfColor.fromInt(0xFF007AFF);

  /// Photos are drawn at a bounded size rather than resampled. `image_picker`
  /// already caps capture at 2048px/q85 (D20), so bounding the drawn box is
  /// enough to keep reports reasonable without an image-processing pipeline.
  static const double _photoWidth = 150;
  static const double _photoHeight = 110;

  @override
  Future<Uint8List> render(ReportSnapshot snapshot) async {
    final doc = pw.Document(
      title: 'FieldProof Inspection Report',
      author: snapshot.inspector.fullName,
    );

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(36, 36, 36, 44),
        header: (context) =>
            context.pageNumber == 1 ? pw.SizedBox() : _runningHeader(snapshot),
        footer: (context) => _footer(context, snapshot),
        build: (context) => [
          _title(snapshot),
          pw.SizedBox(height: 18),
          _facts(snapshot),
          pw.SizedBox(height: 18),
          _summary(snapshot),
          pw.SizedBox(height: 22),
          pw.Text(
            'Punch list',
            style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 8),
          if (snapshot.items.isEmpty)
            pw.Text(
              'No punch-list items were recorded.',
              style: const pw.TextStyle(fontSize: 11, color: _muted),
            )
          else
            // Each item is its own block so MultiPage can break between them
            // rather than splitting an item across a page boundary.
            for (var i = 0; i < snapshot.items.length; i++)
              _item(snapshot.items[i], i + 1),
        ],
      ),
    );

    return doc.save();
  }

  pw.Widget _title(ReportSnapshot s) => pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            'FieldProof',
            style: pw.TextStyle(
              fontSize: 22,
              fontWeight: pw.FontWeight.bold,
              color: _brand,
            ),
          ),
          pw.Text(
            'Inspection Report',
            style: const pw.TextStyle(fontSize: 12, color: _muted),
          ),
        ],
      ),
      pw.SizedBox(height: 4),
      pw.Container(height: 1, color: _rule),
      pw.SizedBox(height: 14),
      pw.Text(
        s.inspection.siteName,
        style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold),
      ),
    ],
  );

  pw.Widget _facts(ReportSnapshot s) {
    final i = s.inspection;
    final rows = <List<String>>[
      if (i.siteAddress != null) ['Address', i.siteAddress!],
      if (i.clientName != null) ['Client', i.clientName!],
      ['Inspection date', NewInspection.dateOnly(i.inspectionDate)],
      ['Inspector', s.inspector.fullName],
      // Submitted is what makes this an official record, so it is stated to the
      // minute rather than the day.
      if (i.submittedAt != null) ['Submitted', _timestamp(i.submittedAt!)],
      ['Inspection ID', i.id],
      ['Report generated', _timestamp(s.generatedAt)],
    ];

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        for (final row in rows)
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 4),
            child: pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.SizedBox(
                  width: 110,
                  child: pw.Text(
                    row[0],
                    style: const pw.TextStyle(fontSize: 10, color: _muted),
                  ),
                ),
                pw.Expanded(
                  child: pw.Text(
                    row[1],
                    style: const pw.TextStyle(fontSize: 10, color: _ink),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  pw.Widget _summary(ReportSnapshot s) {
    final sum = s.summary;
    return pw.Container(
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: _rule),
        borderRadius: pw.BorderRadius.circular(4),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            'Summary',
            style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 6),
          pw.Row(
            children: [
              _stat('Items', '${sum.total}'),
              _stat('Open', '${sum.open}'),
              _stat('Resolved', '${sum.resolved}'),
              _stat('Photos', '${s.photoCount}'),
            ],
          ),
          pw.SizedBox(height: 8),
          pw.Row(
            children: [
              for (final severity in ItemSeverity.values)
                _stat(severity.label, '${sum.bySeverity[severity] ?? 0}'),
            ],
          ),
          if (s.hasUnavailablePhotos) ...[
            pw.SizedBox(height: 8),
            pw.Text(
              'Some photographs could not be retrieved and are marked in place.',
              style: const pw.TextStyle(fontSize: 9, color: _muted),
            ),
          ],
        ],
      ),
    );
  }

  pw.Widget _stat(String label, String value) => pw.Expanded(
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          value,
          style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold),
        ),
        pw.Text(label, style: const pw.TextStyle(fontSize: 9, color: _muted)),
      ],
    ),
  );

  pw.Widget _item(ReportItem entry, int number) {
    final item = entry.item;
    return pw.Container(
      margin: const pw.EdgeInsets.only(bottom: 14),
      padding: const pw.EdgeInsets.only(bottom: 10),
      decoration: const pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: _rule)),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.SizedBox(
                width: 22,
                child: pw.Text(
                  '$number.',
                  style: pw.TextStyle(
                    fontSize: 11,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
              pw.Expanded(
                child: pw.Text(
                  item.title,
                  style: pw.TextStyle(
                    fontSize: 11,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
              // Severity and status are words, not colours: this document is
              // routinely printed in black and white.
              pw.Text(
                '${item.severity.label}  ·  '
                '${item.status.isResolved ? 'Resolved' : 'Open'}',
                style: const pw.TextStyle(fontSize: 10, color: _muted),
              ),
            ],
          ),
          if (item.area != null || item.description != null)
            pw.Padding(
              padding: const pw.EdgeInsets.only(left: 22, top: 3),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  if (item.area != null)
                    pw.Text(
                      item.area!,
                      style: const pw.TextStyle(fontSize: 10, color: _muted),
                    ),
                  if (item.description != null)
                    pw.Text(
                      item.description!,
                      style: const pw.TextStyle(fontSize: 10),
                    ),
                ],
              ),
            ),
          if (entry.photos.isNotEmpty)
            pw.Padding(
              padding: const pw.EdgeInsets.only(left: 22, top: 8),
              child: pw.Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [for (final p in entry.photos) _photo(p)],
              ),
            ),
        ],
      ),
    );
  }

  pw.Widget _photo(ReportPhoto p) {
    if (!p.isAvailable) {
      // Stated, not omitted. The reader learns a photo exists and could not be
      // read, which is not the same as there being no photo.
      return pw.Container(
        width: _photoWidth,
        height: _photoHeight,
        alignment: pw.Alignment.center,
        decoration: pw.BoxDecoration(border: pw.Border.all(color: _rule)),
        child: pw.Text(
          'Photograph unavailable',
          style: const pw.TextStyle(fontSize: 9, color: _muted),
        ),
      );
    }

    return pw.Container(
      width: _photoWidth,
      height: _photoHeight,
      decoration: pw.BoxDecoration(border: pw.Border.all(color: _rule)),
      child: pw.Image(
        pw.MemoryImage(Uint8List.fromList(p.bytes!)),
        fit: pw.BoxFit.cover,
      ),
    );
  }

  pw.Widget _runningHeader(ReportSnapshot s) => pw.Container(
    margin: const pw.EdgeInsets.only(bottom: 10),
    padding: const pw.EdgeInsets.only(bottom: 4),
    decoration: const pw.BoxDecoration(
      border: pw.Border(bottom: pw.BorderSide(color: _rule)),
    ),
    child: pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text(
          s.inspection.siteName,
          style: const pw.TextStyle(fontSize: 9, color: _muted),
        ),
        pw.Text(
          'FieldProof',
          style: const pw.TextStyle(fontSize: 9, color: _muted),
        ),
      ],
    ),
  );

  pw.Widget _footer(pw.Context context, ReportSnapshot s) => pw.Row(
    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
    children: [
      pw.Text(
        'Inspection ${s.inspection.id}',
        style: const pw.TextStyle(fontSize: 8, color: _muted),
      ),
      pw.Text(
        'Page ${context.pageNumber} of ${context.pagesCount}',
        style: const pw.TextStyle(fontSize: 8, color: _muted),
      ),
    ],
  );

  static String _timestamp(DateTime d) {
    final u = d.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${u.year}-${two(u.month)}-${two(u.day)} '
        '${two(u.hour)}:${two(u.minute)} UTC';
  }
}
