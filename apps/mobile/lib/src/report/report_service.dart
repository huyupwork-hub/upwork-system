/// Load -> render -> share, or load -> render -> upload, in that order, once.
///
/// `DB state -> ReportSnapshot -> PDF bytes`. Keeping the steps behind one
/// entry point is what lets the UI show honest progress, and what keeps the
/// renderer from ever reaching for the network. Sharing and publishing are
/// separate methods on purpose: the share sheet never touches the bucket, and
/// an upload never opens a share sheet (D21 amended, D31).
library;

import 'dart:typed_data';

import '../data/models.dart';
import '../offline/offline_status.dart';
import 'report_loader.dart';
import 'report_renderer.dart';
import 'report_sharer.dart';
import 'report_snapshot.dart';
import 'report_store.dart';

enum ReportStage { loading, rendering, sharing, publishing }

class ReportService {
  const ReportService({
    required ReportLoader loader,
    required ReportRenderer renderer,
    required ReportSharer sharer,
    required ReportStore store,
    required String Function() currentUserId,
  })  : _loader = loader,
        _renderer = renderer,
        _sharer = sharer,
        _store = store,
        _currentUserId = currentUserId;

  final ReportLoader _loader;
  final ReportRenderer _renderer;
  final ReportSharer _sharer;
  final ReportStore _store;
  final String Function() _currentUserId;

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

  /// Load -> render -> upload, once. Never submits (the loader refuses a draft
  /// before any work), never shares. The path's owner segment comes from the
  /// session, never the row.
  ///
  /// Throws [InspectionNotSubmittedException] for a draft,
  /// [ReportPhotoUnavailableException] when a photograph could not be fetched
  /// and [ReportTooLargeException] over the bucket's cap — each before a byte
  /// is uploaded — and [ReportPublishException] when the upload itself failed.
  Future<void> publish(
    Inspection inspection, {
    void Function(ReportStage)? onStage,
  }) async {
    onStage?.call(ReportStage.loading);
    final snapshot = await _loader.load(inspection);

    onStage?.call(ReportStage.rendering);
    final bytes = await _renderer.render(snapshot);

    // The bucket would refuse it anyway (413, after the bytes were sent).
    // Refusing here spends no bandwidth on a doomed upload and says why in
    // the app's own words.
    if (bytes.length > ReportLimits.maxBytes) {
      throw ReportTooLargeException(bytes.length);
    }

    onStage?.call(ReportStage.publishing);
    // The owner segment comes from the session, never from the row — the same
    // rule PhotoWorkflow follows. Storage policy pins the whole name, so a
    // forged one would be refused; this keeps the app from forming one at all.
    final path = reportStoragePath(
      inspectorId: _currentUserId(),
      inspectionId: inspection.id,
    );
    try {
      await _store.put(path, bytes);
    } catch (e) {
      throw ReportPublishException(
        inspection.id,
        e,
        transport: isTransportFailure(e),
      );
    }
  }

  /// Ids of the caller's inspections that hold a stored report.
  ///
  /// Throws when the bucket could not be read; callers show "could not check",
  /// never "not uploaded" (D28). The state is read from the bucket every time,
  /// never from a local flag (D27).
  Future<Set<String>> published() => _store.published(_currentUserId());

  /// Explicit, bounded catch-up: [submitted] in the order given, one at a time;
  /// stops at the first transport failure and reports the rest as skipped;
  /// continues past a refusal or a photo/size failure and reports it; never
  /// throws. Reachable only from a tap — nothing calls it on open or resume
  /// (D25's triggers push work the inspector already asked to save; this
  /// re-downloads photographs the inspector did not ask for).
  ///
  /// Reads the bucket first, so an id that already holds a report is neither
  /// re-rendered nor re-uploaded and a second run over the same state does
  /// nothing. When that read fails nothing is attempted — without it "missing"
  /// would be a guess — and every id is reported as skipped.
  Future<PublishReport> publishMissing(
    List<Inspection> submitted, {
    void Function(Inspection, ReportStage)? onStage,
  }) async {
    final Set<String> already;
    try {
      already = await published();
    } catch (e) {
      // The same words every other transport failure in this flow uses, so
      // the summary line never prints a raw SocketException for no signal.
      // A refusal stays verbatim, the repository's rule.
      return PublishReport(
        published: const [],
        failed: const [],
        skipped: List.unmodifiable([for (final i in submitted) i.id]),
        lastError: isTransportFailure(e)
            ? 'The server could not be reached. Try again when you have signal.'
            : '$e',
      );
    }

    final uploaded = <String>[];
    final failed = <String>[];
    final skipped = <String>[];
    String? lastError;
    var stopped = false;

    for (final inspection in submitted) {
      if (already.contains(inspection.id)) continue;
      if (stopped) {
        skipped.add(inspection.id);
        continue;
      }
      try {
        await publish(
          inspection,
          onStage: (stage) => onStage?.call(inspection, stage),
        );
        uploaded.add(inspection.id);
      } catch (e) {
        lastError = '$e';
        // Silence anywhere in load -> render -> upload means the next one
        // would meet the same silence, so the loop stops (D25). A refusal, a
        // photograph the bucket would not hand over, or an oversized document
        // is about this inspection only, so the next one still gets its turn.
        failed.add(inspection.id);
        if (_isTransport(e)) stopped = true;
      }
    }

    return PublishReport(
      published: List.unmodifiable(uploaded),
      failed: List.unmodifiable(failed),
      skipped: List.unmodifiable(skipped),
      lastError: lastError,
    );
  }

  /// The loader wraps a photograph's failure in its own exception, so the
  /// transport question has to be asked of the cause, not the wrapper.
  static bool _isTransport(Object error) => switch (error) {
        ReportPublishException(:final transport) => transport,
        ReportPhotoUnavailableException(:final cause) =>
          isTransportFailure(cause),
        _ => isTransportFailure(error),
      };
}

/// What one run of [ReportService.publishMissing] did, id by id.
///
/// [published] landed. [failed] were attempted and did not land — refused,
/// unrenderable, or the one that met the transport failure. [skipped] were
/// never attempted, because an earlier transport failure made trying pointless
/// or because the bucket could not be read at all. [lastError] is the copy of
/// the last failure, for the summary line. Ids that already held a report
/// appear in none of the three.
class PublishReport {
  const PublishReport({
    required this.published,
    required this.failed,
    required this.skipped,
    this.lastError,
  });

  final List<String> published;
  final List<String> failed;
  final List<String> skipped;
  final String? lastError;
}
