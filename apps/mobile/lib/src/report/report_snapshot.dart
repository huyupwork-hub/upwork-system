/// An immutable projection of one submitted inspection.
///
/// The report is a *view* of the database, never a second source of truth: no
/// report content is stored anywhere, and regenerating always reproduces the
/// current submitted record (D21).
///
/// Everything is loaded once, up front, and the whole document renders from this
/// object. Nothing queries Supabase while pages are being laid out — otherwise a
/// change or a dropped connection mid-render could produce a report whose header
/// and body disagree.
library;

import '../data/models.dart';

/// One photo, plus its bytes — or an explicit record of why they are missing.
///
/// A photo that cannot be fetched is represented, not skipped. Silently omitting
/// it would make the report claim there was no photo, which is a different and
/// worse statement than "this photo could not be read".
class ReportPhoto {
  const ReportPhoto.available(this.photo, this.bytes) : unavailableReason = null;

  const ReportPhoto.unavailable(this.photo, String reason)
    : bytes = null,
      unavailableReason = reason;

  final ItemPhoto photo;
  final List<int>? bytes;
  final String? unavailableReason;

  bool get isAvailable => bytes != null;
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

  /// True when at least one photo could not be read. The renderer says so on the
  /// document rather than leaving a silent gap.
  bool get hasUnavailablePhotos =>
      items.any((i) => i.photos.any((p) => !p.isAvailable));

  int get photoCount =>
      items.fold(0, (sum, i) => sum + i.photos.where((p) => p.isAvailable).length);
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
