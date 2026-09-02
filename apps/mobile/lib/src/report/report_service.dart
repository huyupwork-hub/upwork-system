/// Load -> render -> share, in that order, once.
///
/// `DB state -> ReportSnapshot -> PDF bytes`. Keeping the three steps behind one
/// entry point is what lets the UI show honest progress, and what keeps the
/// renderer from ever reaching for the network.
library;

import 'dart:typed_data';

import '../data/models.dart';
import 'report_loader.dart';
import 'report_renderer.dart';
import 'report_sharer.dart';
import 'report_snapshot.dart';

enum ReportStage { loading, rendering, sharing }

class ReportService {
  const ReportService({
    required ReportLoader loader,
    required ReportRenderer renderer,
    required ReportSharer sharer,
  })  : _loader = loader,
        _renderer = renderer,
        _sharer = sharer;

  final ReportLoader _loader;
  final ReportRenderer _renderer;
  final ReportSharer _sharer;

  /// Loads what the report will contain, without rendering or sharing it.
  ///
  /// The preview screen shows this. Sharing then goes through
  /// [generateAndShare], which loads again — so the preview and the document
  /// are built from the same loader rather than from two descriptions of it
  /// that could drift apart.
  ///
  /// Throws [InspectionNotSubmittedException] for a draft, for the same reason
  /// and at the same point as generating would.
  Future<ReportSnapshot> loadSnapshot(Inspection inspection) =>
      _loader.load(inspection);

  /// Generates and hands off the report.
  ///
  /// Throws [InspectionNotSubmittedException] for a draft — checked by the
  /// loader, before any work is done and without submitting anything.
  Future<Uint8List> generateAndShare(
    Inspection inspection, {
    void Function(ReportStage)? onStage,
  }) async {
    onStage?.call(ReportStage.loading);
    final snapshot = await _loader.load(inspection);

    onStage?.call(ReportStage.rendering);
    final bytes = await _renderer.render(snapshot);

    onStage?.call(ReportStage.sharing);
    await _sharer.share(bytes, filename: reportFilename(snapshot));

    return bytes;
  }
}
