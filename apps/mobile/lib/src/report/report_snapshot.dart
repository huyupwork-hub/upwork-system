/// An immutable projection of one submitted inspection.
///
/// The report is a *view* of the database, never a second source of truth:
/// the document is rendered from the submitted record, and regenerating
/// always reproduces the current submitted record (D21). One rendering — the
/// one made at submission — is stored write-once for reviewers (D21 amended,
/// D31); it is content-equivalent to a fresh one, and the record stays the
/// authority.
///
/// Everything is loaded once, up front, and the whole document renders from this
/// object. Nothing queries Supabase while pages are being laid out — otherwise a
/// change or a dropped connection mid-render could produce a report whose header
/// and body disagree.
library;

import '../data/models.dart';

/// One photo and its bytes.
///
/// There is no "unavailable" variant: a photo the snapshot cannot fetch aborts
/// generation with [ReportPhotoUnavailableException] rather than producing a
/// report with a gap in it. A document that silently stands in for missing
/// evidence is worse than no document, because the reader cannot tell.
class ReportPhoto {
  const ReportPhoto(this.photo, this.bytes);

  final ItemPhoto photo;
  final List<int> bytes;
}

class ReportItem {
  const ReportItem({required this.item, required this.photos});

  final InspectionItem item;
  final List<ReportPhoto> photos;
}

/// Counts shown in the summary block. Derived, never stored.
class ReportSummary {
  const ReportSummary({
    required this.total,
    required this.open,
    required this.resolved,
    required this.bySeverity,
  });

  final int total;
  final int open;
  final int resolved;
  final Map<ItemSeverity, int> bySeverity;

  factory ReportSummary.from(List<ReportItem> items) {
    final bySeverity = <ItemSeverity, int>{
      // Every severity is present, including zeroes: a report that omits
      // "Critical: 0" reads as though the question was never asked.
      for (final s in ItemSeverity.values) s: 0,
    };
    var open = 0;
    var resolved = 0;

    for (final entry in items) {
      bySeverity[entry.item.severity] = bySeverity[entry.item.severity]! + 1;
      if (entry.item.status.isResolved) {
        resolved++;
      } else {
        open++;
      }
    }

    return ReportSummary(
      total: items.length,
      open: open,
      resolved: resolved,
      bySeverity: Map.unmodifiable(bySeverity),
    );
  }
}

class ReportSnapshot {
  ReportSnapshot({
    required this.inspection,
    required this.inspector,
    required this.items,
    required this.generatedAt,
  }) : summary = ReportSummary.from(items);

  final Inspection inspection;
  final Profile inspector;
  final List<ReportItem> items;
  final ReportSummary summary;
  final DateTime generatedAt;

  int get photoCount => items.fold(0, (sum, i) => sum + i.photos.length);
}

/// Raised when a report is requested for an inspection that is not submitted.
///
/// A draft has no official report: it is still changing, so a document produced
/// from it would claim a permanence it does not have (D21). Generation never
/// submits as a side effect — that would turn "let me see the report" into an
/// irreversible act.
class InspectionNotSubmittedException implements Exception {
  const InspectionNotSubmittedException();

  @override
  String toString() =>
      'Only a submitted inspection can produce a report. Submit it first.';
}

/// A photo the report needs could not be fetched.
///
/// Generation stops. The alternative — rendering a placeholder — produces a
/// document that looks complete while quietly omitting evidence, and the person
/// reading it has no way to know.
class ReportPhotoUnavailableException implements Exception {
  const ReportPhotoUnavailableException(this.storagePath, this.cause);

  final String storagePath;
  final Object cause;

  @override
  String toString() =>
      'The report could not be generated: a photograph could not be '
      'retrieved ($storagePath). Check your connection and try again.';
}

/// The report was rendered but could not be uploaded for reviewers.
///
/// Raised only once the submission is permanent (D10), and the copy says so
/// first: an upload failure is not a submit failure, and must never read as
/// one. [transport] separates "the server could not be reached" from "the
/// server answered, and the answer was no" — `isTransportFailure`'s rule. The
/// first is offered again on the inspector's say-so; the second is shown
/// verbatim, the repository's rule for refusals.
class ReportPublishException implements Exception {
  const ReportPublishException(
    this.inspectionId,
    this.cause, {
    required this.transport,
  });

  final String inspectionId;
  final Object cause;
  final bool transport;

  @override
  String toString() => transport
      ? 'The inspection was submitted. Its PDF report could not be uploaded '
          'for reviewers because the server could not be reached. Try again '
          'when you have signal.'
      : 'The inspection was submitted. Its PDF report could not be uploaded '
          'for reviewers: $cause';
}

/// The rendered report is over the bucket's cap and was not uploaded.
///
/// Refused before any byte leaves the device: the bucket would answer 413,
/// after the inspector's bandwidth had been spent. Not a transport failure and
/// not retried — the document will be the same size next time. Sharing from
/// the device is untouched (D21).
class ReportTooLargeException implements Exception {
  const ReportTooLargeException(this.bytes);

  final int bytes;

  @override
  String toString() {
    final size = (bytes / (1024 * 1024)).toStringAsFixed(1);
    const cap = ReportLimits.maxBytes ~/ (1024 * 1024);
    return 'The PDF report is $size MB, over the $cap MB limit, and cannot be '
        'uploaded for reviewers. Sharing it from this device still works.';
  }
}
