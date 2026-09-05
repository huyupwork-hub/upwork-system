import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../data/models.dart';
import '../data/repositories.dart';
import '../offline/offline_status.dart';
import '../report/report_service.dart';
import '../report/report_snapshot.dart';
import 'presentation.dart';
import 'theme.dart';

/// Reports: which inspections can produce a document, and which cannot yet.
///
/// This surfaces a capability that already exists rather than adding one. The
/// PDF is generated on-device from a submitted inspection (D6, D21) — this
/// screen simply gathers the records that are eligible instead of making a
/// reviewer open each one to find out.
///
/// The eligibility rule is the product's, not this screen's: a draft is still
/// changing, so a document made from it would claim a permanence it does not
/// have. Drafts are therefore listed as *not yet* reportable, with the reason,
/// rather than hidden — hiding them would leave an inspector wondering where
/// their work went.
///
/// It is also where the stored rendering's state lives (D21 amended, D31):
/// which submitted inspections have their report in the bucket, read from the
/// bucket every time rather than from a local flag (D27), and the one place a
/// catch-up is offered — behind a tap, never on open or resume, because it
/// re-downloads photographs the inspector did not ask for (D25).
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({
    super.key,
    required this.inspections,
    required this.reports,
    this.offline,
  });

  final InspectionsRepository inspections;
  final ReportService reports;
  final OfflineStatusNotifier? offline;

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  List<Inspection>? _rows;
  String? _error;

  /// Ids whose report the bucket holds. Null until the bucket has answered, or
  /// when it could not — an unknown is never rendered as "not uploaded" (D28).
  Set<String>? _published;
  bool _checkFailed = false;

  /// The inspection currently being rendered, so only its row shows a spinner.
  /// A catch-up reports its progress through the same pair, row by row.
  String? _busyId;
  ReportStage? _stage;
  String? _reportError;

  /// A catch-up is in flight. Separate from [_busyId], which is null between
  /// the bucket listing the catch-up starts with and its first render.
  bool _uploading = false;

  /// What the last catch-up did, for the summary line. Cleared by the next.
  PublishReport? _summary;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _error = null);
    final List<Inspection> rows;
    try {
      rows = await widget.inspections.listMine();
      if (!mounted) return;
      setState(() => _rows = rows);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
      return;
    }
    // After the list is on screen, never before (D24), and only when there is
    // something to ask about: offline, listMine() returns local drafts only,
    // so no submitted row is shown and no upload state is invented for one.
    if (rows.any((r) => r.status == InspectionStatus.submitted)) {
      await _checkPublished();
    }
  }

  /// Which reports the bucket holds, from the bucket (D27). A failed read is
  /// its own state, shown above the list, and no row claims anything (D28).
  Future<void> _checkPublished() async {
    setState(() => _checkFailed = false);
    try {
      final published = await widget.reports.published();
      if (!mounted) return;
      setState(() => _published = published);
    } catch (_) {
      if (mounted) {
        setState(() {
          _published = null;
          _checkFailed = true;
        });
      }
    }
  }

  /// The explicit, bounded catch-up: [missing] in the order shown, one at a
  /// time, stopping at the first sign of no signal. Reachable only from a tap
  /// (D25). Afterwards the state is re-read from the bucket, never inferred
  /// from the report — what landed is what the listing says landed (D27).
  Future<void> _uploadMissing(List<Inspection> missing) async {
    if (_uploading || _busyId != null) return;
    setState(() {
      _uploading = true;
      _summary = null;
      _reportError = null;
    });
    try {
      final report = await widget.reports.publishMissing(
        missing,
        onStage: (inspection, stage) {
          if (mounted) {
            setState(() {
              _busyId = inspection.id;
              _stage = stage;
            });
          }
        },
      );
      if (mounted) setState(() => _summary = report);
    } finally {
      if (mounted) {
        setState(() {
          _uploading = false;
          _busyId = null;
          _stage = null;
        });
      }
    }
    if (mounted) await _checkPublished();
  }

  /// One line from the [PublishReport], naming each inspection by its site.
  ///
  /// The reason is the failure's own copy, verbatim — the repository's rule.
  /// Skipped rows are named without a reason only when a failed row carries
  /// it; when the bucket listing itself failed nothing was attempted, and the
  /// listing's error is the reason for every skip.
  ///
  /// Every list empty is reachable: the rows are read once, so a report
  /// uploaded meanwhile — from the detail screen, another device, or the
  /// backfill — still shows as missing until the catch-up re-reads the bucket
  /// and finds nothing to do. Said so, rather than a blank line.
  String _summaryLine(PublishReport report) {
    String names(List<String> ids) => ids.map(_siteName).join(', ');
    if (report.published.isEmpty &&
        report.failed.isEmpty &&
        report.skipped.isEmpty) {
      return 'Nothing to upload: every report is already there.';
    }
    return [
      if (report.published.isNotEmpty) 'Uploaded ${names(report.published)}',
      if (report.skipped.isNotEmpty)
        report.failed.isEmpty
            ? 'Skipped ${names(report.skipped)}: ${report.lastError}'
            : 'Skipped ${names(report.skipped)} (no signal)',
      if (report.failed.isNotEmpty)
        'Failed ${names(report.failed)}: ${report.lastError}',
    ].join(' · ');
  }

  String _siteName(String id) {
    for (final row in _rows ?? const <Inspection>[]) {
      if (row.id == id) return row.siteName;
    }
    return id;
  }

  Future<void> _generate(Inspection inspection) async {
    if (_busyId != null || _uploading) return;
    setState(() {
      _busyId = inspection.id;
      _reportError = null;
    });
    try {
      await widget.reports.generateAndShare(
        inspection,
        onStage: (stage) {
          if (mounted) setState(() => _stage = stage);
        },
      );
    } on InspectionNotSubmittedException catch (e) {
      if (mounted) setState(() => _reportError = e.toString());
    } catch (e) {
      if (mounted) setState(() => _reportError = e.toString());
    } finally {
      if (mounted) {
        setState(() {
          _busyId = null;
          _stage = null;
        });
      }
    }
  }

  static String _stageLabel(ReportStage stage) => switch (stage) {
        ReportStage.loading => 'Collecting the inspection…',
        ReportStage.rendering => 'Building the PDF…',
        ReportStage.sharing => 'Opening share sheet…',
        ReportStage.publishing => 'Uploading the report for reviewers…',
      };

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: AppColors.background,
      child: CustomScrollView(
        slivers: [
          const CupertinoSliverNavigationBar(
            largeTitle: Text('Reports'),
            backgroundColor: AppColors.card,
            border: Border(
              bottom: BorderSide(color: AppColors.separator, width: 0.5),
            ),
          ),
          SliverToBoxAdapter(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_error != null) {
      return ErrorState(
        title: 'Your reports could not be loaded',
        detail: _error!,
        detailKey: const Key('reports-error'),
        onRetry: _load,
      );
    }

    final rows = _rows;
    if (rows == null) {
      return const Padding(
        padding: EdgeInsets.all(48),
        child: Center(child: CupertinoActivityIndicator()),
      );
    }

    final ready = rows
        .where((r) => r.status == InspectionStatus.submitted)
        .toList(growable: false);
    final pending = rows
        .where((r) => r.status == InspectionStatus.draft)
        .toList(growable: false);

    if (rows.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(32, 56, 32, 32),
        child: Text(
          'No reports yet.\nSubmit an inspection to produce one.',
          key: Key('reports-empty'),
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 17, color: AppColors.label2),
        ),
      );
    }

    // Only when the bucket answered: a failed listing must not turn into a
    // count of "missing" reports and a button to upload them (D28).
    final published = _published;
    final missing = published == null
        ? const <Inspection>[]
        : ready.where((r) => !published.contains(r.id)).toList(growable: false);
    final summary = _summary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_reportError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Text(
              _reportError!,
              key: const Key('reports-generate-error'),
              style: const TextStyle(fontSize: 13, color: AppColors.red),
            ),
          ),
        if (_checkFailed)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    "Couldn't check which reports have been uploaded.",
                    key: Key('report-state-unknown'),
                    style: TextStyle(fontSize: 13, color: AppColors.label2),
                  ),
                ),
                CupertinoButton(
                  key: const Key('report-check-retry'),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  minimumSize: Size.zero,
                  onPressed: _checkPublished,
                  child: const Text('Retry', style: TextStyle(fontSize: 13)),
                ),
              ],
            ),
          ),
        SectionHeader(label: 'Ready to issue (${ready.length})'),
        if (ready.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(32, 8, 32, 8),
            child: Text(
              'Nothing submitted yet.',
              style: TextStyle(fontSize: 15, color: AppColors.label2),
            ),
          )
        else
          InsetCard(
            children: [
              for (final row in ready)
                _ReportRow(
                  inspection: row,
                  busy: _busyId == row.id,
                  stageLabel: _busyId == row.id && _stage != null
                      ? _stageLabel(_stage!)
                      : null,
                  uploaded: published?.contains(row.id),
                  onGenerate: () => _generate(row),
                  onUpload: _uploading ? null : () => _uploadMissing([row]),
                ),
            ],
          ),
        if (missing.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: CupertinoButton.filled(
              key: const Key('upload-missing-reports-button'),
              onPressed: _uploading ? null : () => _uploadMissing(missing),
              child: _uploading
                  ? const CupertinoActivityIndicator(color: AppColors.card)
                  : Text(
                      'Upload ${missing.length} missing '
                      'report${missing.length == 1 ? '' : 's'}',
                    ),
            ),
          ),
        if (summary != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
            child: Text(
              _summaryLine(summary),
              key: const Key('reports-publish-summary'),
              style: const TextStyle(fontSize: 13, color: AppColors.label2),
            ),
          ),
        if (pending.isNotEmpty) ...[
          SectionHeader(label: 'Not yet reportable (${pending.length})'),
          InsetCard(
            children: [
              for (final row in pending) _PendingRow(inspection: row),
            ],
          ),
        ],
        // The one capability this screen implies but does not have. Generating
        // the document is real and on-device, and one rendering is stored for
        // reviewers at submission (D21 amended, D31); sending it to a client
        // is not built.
        const Padding(
          padding: EdgeInsets.fromLTRB(AppMetrics.gutter, 22, 16, 0),
          child: DependencyNote(
            title: 'Send to client',
            requirement: 'Requires an email delivery provider',
          ),
        ),
        const SizedBox(height: 32),
      ],
    );
  }
}

class _ReportRow extends StatelessWidget {
  const _ReportRow({
    required this.inspection,
    required this.busy,
    required this.onGenerate,
    required this.onUpload,
    this.uploaded,
    this.stageLabel,
  });

  final Inspection inspection;
  final bool busy;
  final String? stageLabel;
  final VoidCallback onGenerate;

  /// Whether the bucket holds this inspection's report. Null when the screen
  /// could not find out, and then the row claims nothing either way (D28).
  final bool? uploaded;

  /// Null while a catch-up is running, so two uploads never race on one name.
  final VoidCallback? onUpload;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(AppMetrics.gutter, 12, 14, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  inspection.siteName,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppColors.label,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Text(
                  stageLabel ??
                      [
                        NewInspection.dateOnly(inspection.inspectionDate),
                        if (inspection.clientName != null)
                          inspection.clientName!,
                      ].join('  ·  '),
                  style: TextStyle(
                    fontSize: 13,
                    color:
                        stageLabel != null ? AppColors.blue : AppColors.label2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                // Its own line rather than a suffix on the one above, which
                // is already the first thing a long client name truncates.
                if (uploaded == true) ...[
                  const SizedBox(height: 3),
                  Text(
                    'Uploaded for reviewers',
                    key: Key('report-uploaded-${inspection.id}'),
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: AppColors.green,
                    ),
                  ),
                ] else if (uploaded == false) ...[
                  const SizedBox(height: 3),
                  const Text(
                    'Not uploaded for reviewers',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: AppColors.orange,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (busy)
            const CupertinoActivityIndicator(radius: 10)
          else ...[
            if (uploaded == false) ...[
              CupertinoButton(
                key: Key('report-upload-${inspection.id}'),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                minimumSize: Size.zero,
                borderRadius: BorderRadius.circular(8),
                color: AppColors.orangeTint,
                onPressed: onUpload,
                child: const Text(
                  'Upload',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.orange,
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
            CupertinoButton(
              key: Key('report-pdf-${inspection.id}'),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
              minimumSize: Size.zero,
              borderRadius: BorderRadius.circular(8),
              color: AppColors.blueTint,
              onPressed: onGenerate,
              child: const Text(
                'PDF',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.blue,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A draft, listed with the reason it cannot produce a document.
///
/// Shown rather than filtered out: an inspector looking for a report they
/// expected should find the record and the explanation together.
class _PendingRow extends StatelessWidget {
  const _PendingRow({required this.inspection});

  final Inspection inspection;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(AppMetrics.gutter, 12, 14, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  inspection.siteName,
                  style: const TextStyle(
                    fontSize: 16,
                    color: AppColors.label2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                const Text(
                  'Submit the inspection to issue a report',
                  style: TextStyle(fontSize: 13, color: AppColors.label3),
                ),
              ],
            ),
          ),
          const PhasePill(phase: InspectionPhase.draft),
        ],
      ),
    );
  }
}
