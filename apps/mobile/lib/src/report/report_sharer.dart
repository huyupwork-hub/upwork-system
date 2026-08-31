/// The platform preview / share / save sheet.
///
/// Behind a port so the widget tests can drive the whole Generate Report flow
/// without loading `printing`'s platform channel. There is one production
/// implementation and one fake.
library;

import 'dart:typed_data';

import 'package:printing/printing.dart';

import 'report_snapshot.dart';

abstract interface class ReportSharer {
  /// Hands the bytes to the platform. Returns false if the user dismissed
  /// without sharing — dismissal is not an error.
  Future<bool> share(Uint8List bytes, {required String filename});
}

class PrintingReportSharer implements ReportSharer {
  const PrintingReportSharer();

  @override
  Future<bool> share(Uint8List bytes, {required String filename}) =>
      Printing.sharePdf(bytes: bytes, filename: filename);
}

/// A filename someone can find again later: site, date, and a short id.
///
/// Derived from the snapshot rather than stored, like everything else about the
/// report (D21).
String reportFilename(ReportSnapshot snapshot) {
  final site = snapshot.inspection.siteName
      .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '')
      .toLowerCase();
  final date = snapshot.inspection.inspectionDate;
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp = '${date.year}${two(date.month)}${two(date.day)}';
  final shortId = snapshot.inspection.id.replaceAll('-', '').substring(0, 8);
  return 'fieldproof-${site.isEmpty ? 'inspection' : site}-$stamp-$shortId.pdf';
}
