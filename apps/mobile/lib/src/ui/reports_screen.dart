import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../data/models.dart';
import '../data/repositories.dart';
import '../offline/offline_status.dart';
import '../report/report_service.dart';
import 'presentation.dart';
import 'report_preview_screen.dart';
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

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final rows = await widget.inspections.listMine();
      if (!mounted) return;
      setState(() => _rows = rows);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// Opens the preview. Sharing happens there, from the same snapshot the
  /// reader is looking at, rather than from a button that produces a document
  /// nobody has seen.
  Future<void> _preview(Inspection inspection) async {
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => ReportPreviewScreen(
          inspection: inspection,
          reports: widget.reports,
        ),
      ),
    );
  }

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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
                _ReportRow(inspection: row, onOpen: () => _preview(row)),
            ],
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
        // the document is real and on-device; sending it to a client is not
        // built, and D21 recorded that no PDF is ever stored server-side.
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
  const _ReportRow({required this.inspection, required this.onOpen});

  final Inspection inspection;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      key: Key('report-open-${inspection.id}'),
      padding: const EdgeInsets.fromLTRB(AppMetrics.gutter, 12, 14, 12),
      minimumSize: Size.zero,
      borderRadius: BorderRadius.zero,
      onPressed: onOpen,
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
                  [
                    NewInspection.dateOnly(inspection.inspectionDate),
                    if (inspection.clientName != null) inspection.clientName!,
                  ].join('  ·  '),
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.label2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          const Icon(
            CupertinoIcons.chevron_forward,
            size: 16,
            color: AppColors.label3,
          ),
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
