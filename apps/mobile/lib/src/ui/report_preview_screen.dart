import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';

import '../data/models.dart';
import '../report/report_service.dart';
import '../report/report_snapshot.dart';
import 'presentation.dart';
import 'theme.dart';

/// What the report says, before it becomes a document.
///
/// This is a preview, not a PDF viewer. It renders the same [ReportSnapshot]
/// the renderer is handed, so what an inspector reads here is what the file
/// will contain — a second description of the report, written separately, would
/// eventually disagree with it.
///
/// Sharing still goes through [ReportService.generateAndShare]: the PDF is
/// produced on the device and handed to the system share sheet (D6, D21).
/// Nothing is uploaded, and the note at the top says so where someone would
/// otherwise look for a download.
class ReportPreviewScreen extends StatefulWidget {
  const ReportPreviewScreen({
    super.key,
    required this.inspection,
    required this.reports,
  });

  final Inspection inspection;
  final ReportService reports;

  @override
  State<ReportPreviewScreen> createState() => _ReportPreviewScreenState();
}

class _ReportPreviewScreenState extends State<ReportPreviewScreen> {
  ReportSnapshot? _snapshot;
  String? _error;
  bool _sharing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final snapshot = await widget.reports.loadSnapshot(widget.inspection);
      if (mounted) setState(() => _snapshot = snapshot);
    } on InspectionNotSubmittedException {
      if (mounted) {
        setState(() => _error =
            'A report can only be produced once the inspection is submitted.');
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _share() async {
    if (_sharing) return;
    setState(() {
      _sharing = true;
      _error = null;
    });
    try {
      await widget.reports.generateAndShare(widget.inspection);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;

    return CupertinoPageScaffold(
      backgroundColor: AppColors.background,
      navigationBar: CupertinoNavigationBar(
        middle: const Text('Report Preview'),
        previousPageTitle: 'Reports',
        backgroundColor: AppColors.card,
        border: const Border(
          bottom: BorderSide(color: AppColors.separator, width: 0.5),
        ),
        // Absent until there is something to share, rather than disabled: a
        // control that cannot work yet is better not drawn.
        trailing: snapshot == null
            ? null
            : CupertinoButton(
                key: const Key('report-share-button'),
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                onPressed: _sharing ? null : _share,
                child: _sharing
                    ? const CupertinoActivityIndicator(radius: 9)
                    : const Text('Share', style: TextStyle(fontSize: 15)),
              ),
      ),
      child: SafeArea(child: _body(snapshot)),
    );
  }

  Widget _body(ReportSnapshot? snapshot) {
    if (_error != null && snapshot == null) {
      return ErrorState(
        title: 'This report could not be prepared',
        detail: _error!,
        detailKey: const Key('report-preview-error'),
        onRetry: _load,
      );
    }
    if (snapshot == null) {
      return const Center(child: CupertinoActivityIndicator());
    }

    return ListView(
      children: [
        // Where someone would otherwise look for a download.
        const Padding(
          padding:
              EdgeInsets.fromLTRB(AppMetrics.gutter, 12, AppMetrics.gutter, 0),
          child: _DeviceNote(),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(AppMetrics.gutter, 12, 16, 0),
            child: Text(
              _error!,
              key: const Key('report-share-error'),
              style: const TextStyle(fontSize: 13, color: AppColors.red),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppMetrics.gutter,
            12,
            AppMetrics.gutter,
            28,
          ),
          child: _Document(snapshot: snapshot),
        ),
      ],
    );
  }
}

class _DeviceNote extends StatelessWidget {
  const _DeviceNote();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
      decoration: const BoxDecoration(
        color: AppColors.blueTint,
        borderRadius: BorderRadius.all(Radius.circular(10)),
        border: Border(left: BorderSide(color: AppColors.blue, width: 3)),
      ),
      child: const Text(
        'Generated on this device. Cloud PDF storage is not connected.',
        key: Key('report-device-note'),
        style: TextStyle(fontSize: 12, color: AppColors.blue, height: 1.4),
      ),
    );
  }
}

/// The document itself, as a card.
class _Document extends StatelessWidget {
  const _Document({required this.snapshot});

  final ReportSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final i = snapshot.inspection;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppMetrics.cardRadius),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1A000000),
            blurRadius: 12,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppMetrics.cardRadius),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Masthead(siteName: i.siteName),
            _Facts(snapshot: snapshot),
            _SeverityTallies(summary: snapshot.summary),
            _Findings(items: snapshot.items),
          ],
        ),
      ),
    );
  }
}

class _Masthead extends StatelessWidget {
  const _Masthead({required this.siteName});

  final String siteName;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.blue,
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            CupertinoIcons.checkmark_shield_fill,
            size: 28,
            color: AppColors.card,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'FIELDPROOF INSPECTION REPORT',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                    color: Color(0xB3FFFFFF),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  siteName,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                    color: AppColors.card,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Facts extends StatelessWidget {
  const _Facts({required this.snapshot});

  final ReportSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final i = snapshot.inspection;
    final rows = <(String, String)>[
      if (i.siteAddress != null) ('Address', i.siteAddress!),
      if (i.clientName != null) ('Client', i.clientName!),
      ('Date', NewInspection.dateOnly(i.inspectionDate)),
      ('Inspector', snapshot.inspector.fullName),
      ('Status', InspectionPhase.of(i).label),
      (
        'Generated',
        '${NewInspection.dateOnly(snapshot.generatedAt)} (on device)'
      ),
    ];

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppColors.separator, width: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 96,
                    child: Text(
                      label,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.label2,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      value,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: AppColors.label,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// One column per severity, in the order the rest of the app uses.
class _SeverityTallies extends StatelessWidget {
  const _SeverityTallies({required this.summary});

  final ReportSummary summary;

  static const _order = [
    ItemSeverity.critical,
    ItemSeverity.high,
    ItemSeverity.medium,
    ItemSeverity.low,
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppColors.separator, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          for (var n = 0; n < _order.length; n++)
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 4),
                decoration: BoxDecoration(
                  border: n < _order.length - 1
                      ? const Border(
                          right: BorderSide(
                            color: AppColors.separator,
                            width: 0.5,
                          ),
                        )
                      : null,
                ),
                child: Column(
                  children: [
                    Text(
                      '${summary.bySeverity[_order[n]] ?? 0}',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: SeverityPalette.foreground(_order[n]),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _order[n].label,
                      style: const TextStyle(
                        fontSize: 10,
                        color: AppColors.label2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Findings extends StatelessWidget {
  const _Findings({required this.items});

  final List<ReportItem> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(20, 18, 20, 22),
        child: Text(
          'No findings were recorded.',
          key: Key('report-no-findings'),
          style: TextStyle(fontSize: 13, color: AppColors.label2),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var n = 0; n < items.length; n++)
          Container(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
            decoration: BoxDecoration(
              border: n < items.length - 1
                  ? const Border(
                      bottom: BorderSide(
                        color: AppColors.separator,
                        width: 0.5,
                      ),
                    )
                  : null,
            ),
            child: _FindingRow(entry: items[n]),
          ),
      ],
    );
  }
}

class _FindingRow extends StatelessWidget {
  const _FindingRow({required this.entry});

  final ReportItem entry;

  @override
  Widget build(BuildContext context) {
    final item = entry.item;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 5),
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: SeverityPalette.foreground(item.severity),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      item.title,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.label,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    item.status.isResolved ? 'Resolved' : 'Open',
                    style: TextStyle(
                      fontSize: 12,
                      color: item.status.isResolved
                          ? AppColors.green
                          : AppColors.label2,
                    ),
                  ),
                ],
              ),
              if (item.area != null && item.area!.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  item.area!,
                  style: const TextStyle(fontSize: 12, color: AppColors.label2),
                ),
              ],
              if (item.description != null && item.description!.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  item.description!,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.label2,
                    height: 1.4,
                  ),
                ),
              ],
              // The bytes are already loaded — the renderer embeds these exact
              // ones — so the preview shows the photographs rather than a count
              // of them.
              if (entry.photos.isNotEmpty) ...[
                const SizedBox(height: 8),
                SizedBox(
                  height: 56,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: entry.photos.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 6),
                    itemBuilder: (context, n) => ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.memory(
                        _bytes(entry.photos[n].bytes),
                        width: 56,
                        height: 56,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// `ReportPhoto.bytes` is a `List<int>`; `Image.memory` needs a `Uint8List`.
/// Converted here rather than in the snapshot, which should not know that
/// anything renders it. Already-`Uint8List` bytes pass through untouched — the
/// loader usually hands back exactly that, and copying megabytes per frame to
/// satisfy a type would be a real cost for no gain.
Uint8List _bytes(List<int> bytes) =>
    bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
