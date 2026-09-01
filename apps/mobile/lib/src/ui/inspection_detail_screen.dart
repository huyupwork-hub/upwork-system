import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../data/models.dart';
import '../data/repositories.dart';
import '../report/report_service.dart';
import '../report/report_snapshot.dart';
import 'item_editor_sheet.dart';
import 'theme.dart';

/// One inspection and its punch list.
///
/// A submitted inspection is read-only (D17): no add, no edit, no delete. The
/// database enforces this — the write policies require the parent to be `draft`
/// — so what follows is presentation, not protection. It exists so the app does
/// not offer an action the server will refuse.
///
/// There is no unsubmit. Changing submitted work will eventually mean creating a
/// new draft revision (D18), which is not implemented in V1.
class InspectionDetailScreen extends StatefulWidget {
  const InspectionDetailScreen({
    super.key,
    required this.inspection,
    required this.inspections,
    required this.items,
    required this.photos,
    required this.source,
    required this.reports,
    this.isUnsynced = false,
  });

  final Inspection inspection;
  final InspectionsRepository inspections;
  final InspectionItemsRepository items;
  final PhotosRepository photos;
  final PhotoSource source;
  final ReportService reports;

  /// The inspection is held only on this device and has never been pushed.
  ///
  /// It is still fully editable — that is the point of the offline slice — but
  /// it cannot be submitted, because submission stamps `submitted_at` on the
  /// server and freezes the record there (D10, D17). The repository refuses it
  /// regardless; this only stops the app offering an action that cannot succeed,
  /// which is the same rule the add and report affordances already follow.
  final bool isUnsynced;

  @override
  State<InspectionDetailScreen> createState() => _InspectionDetailScreenState();
}

class _InspectionDetailScreenState extends State<InspectionDetailScreen> {
  /// Held in state rather than read from the widget, because submitting changes
  /// it. The screen then re-renders as the frozen record it now is, which is
  /// also the clearest possible confirmation that the submit took effect.
  late Inspection _inspection;

  List<InspectionItem>? _rows;
  String? _error;

  ReportStage? _stage;
  String? _reportError;

  bool _submitting = false;
  String? _submitError;

  @override
  void initState() {
    super.initState();
    _inspection = widget.inspection;
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final rows = await widget.items.listFor(_inspection.id);
      if (!mounted) return;
      setState(() => _rows = rows);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// Submitted work is frozen (D17). The database refuses the write regardless;
  /// this only stops the app offering it.
  bool get _isEditable => _inspection.status == InspectionStatus.draft;

  Future<void> _edit([InspectionItem? existing]) async {
    if (!_isEditable) return;
    final changed = await showItemEditorSheet(
      context,
      items: widget.items,
      photos: widget.photos,
      source: widget.source,
      inspectionId: _inspection.id,
      existing: existing,
    );
    if (changed == true) await _load();
  }

  /// Submitting is irreversible (D10) and it is what exposes the work to a
  /// reviewer (D3), so it asks first. The confirmation names both consequences
  /// rather than asking a bare "are you sure?", which teaches people to tap
  /// through without reading.
  Future<void> _confirmAndSubmit() async {
    if (!_isEditable || _submitting) return;

    final confirmed = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        key: const Key('submit-confirm-sheet'),
        title: const Text('Submit this inspection?'),
        message: const Text(
          'It becomes a permanent record: you will not be able to change it, '
          'add items or photos, or return it to draft. Reviewers can see it '
          'once submitted.',
        ),
        actions: [
          CupertinoActionSheetAction(
            key: const Key('submit-confirm-button'),
            isDestructiveAction: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Submit'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _submitting = true;
      _submitError = null;
    });

    try {
      final submitted = await widget.inspections.submit(_inspection.id);
      if (!mounted) return;
      // The server's row, not a locally patched copy: submitted_at is stamped
      // by a trigger, so only the returned row knows when this happened.
      setState(() => _inspection = submitted);
    } catch (e) {
      if (mounted) setState(() => _submitError = e.toString());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _generateReport() async {
    if (_stage != null) return;
    setState(() => _reportError = null);
    try {
      await widget.reports.generateAndShare(
        _inspection,
        onStage: (stage) {
          if (mounted) setState(() => _stage = stage);
        },
      );
    } on InspectionNotSubmittedException catch (e) {
      // Should be unreachable — the action is absent on a draft — but the
      // loader is the authority, so its refusal is surfaced rather than assumed
      // impossible.
      if (mounted) setState(() => _reportError = e.toString());
    } catch (e) {
      if (mounted) setState(() => _reportError = e.toString());
    } finally {
      if (mounted) setState(() => _stage = null);
    }
  }

  static String _stageLabel(ReportStage stage) => switch (stage) {
        ReportStage.loading => 'Collecting the inspection…',
        ReportStage.rendering => 'Building the PDF…',
        ReportStage.sharing => 'Opening share sheet…',
      };

  @override
  Widget build(BuildContext context) {
    final i = _inspection;
    return CupertinoPageScaffold(
      backgroundColor: AppColors.background,
      navigationBar: CupertinoNavigationBar(
        middle: const Text('Inspection'),
        previousPageTitle: 'Inspections',
        // Absent, not disabled: a greyed-out button invites a tap that can never
        // work. Submitted inspections simply have no add affordance.
        // Draft gets the add action; submitted gets the report action. A draft
        // has no report action at all rather than a disabled one — an
        // affordance that can never succeed is worse than its absence (D21).
        trailing: _isEditable
            ? CupertinoButton(
                key: const Key('add-item-button'),
                padding: EdgeInsets.zero,
                onPressed: () => _edit(),
                child: const Icon(CupertinoIcons.add, color: AppColors.blue),
              )
            : CupertinoButton(
                key: const Key('generate-report-button'),
                padding: EdgeInsets.zero,
                onPressed: _stage != null ? null : _generateReport,
                child: _stage != null
                    ? const CupertinoActivityIndicator()
                    : const Icon(
                        CupertinoIcons.doc_text,
                        color: AppColors.blue,
                      ),
              ),
      ),
      child: SafeArea(
        child: ListView(
          children: [
            const SectionHeader(label: 'Site'),
            InsetCard(
              children: [
                ReadOnlyRow(label: 'Name', value: i.siteName),
                if (i.siteAddress != null)
                  ReadOnlyRow(label: 'Address', value: i.siteAddress!),
                if (i.clientName != null)
                  ReadOnlyRow(label: 'Client', value: i.clientName!),
                ReadOnlyRow(
                  label: 'Date',
                  value: NewInspection.dateOnly(i.inspectionDate),
                ),
                ReadOnlyRow(
                  label: 'Status',
                  value: i.status == InspectionStatus.draft
                      ? 'Draft'
                      : 'Submitted',
                  valueKey: const Key('detail-status'),
                ),
              ],
            ),
            if (!_isEditable) _readOnlyNotice,
            if (_stage != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Row(
                  children: [
                    const CupertinoActivityIndicator(radius: 8),
                    const SizedBox(width: 8),
                    Text(
                      _stageLabel(_stage!),
                      key: const Key('report-progress'),
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppColors.label2,
                      ),
                    ),
                  ],
                ),
              ),
            if (_reportError != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Text(
                  _reportError!,
                  key: const Key('report-error'),
                  style: const TextStyle(fontSize: 13, color: AppColors.red),
                ),
              ),
            const SectionHeader(label: 'Punch list'),
            _items(),
            if (_isEditable && widget.isUnsynced) _unsyncedFooter,
            if (_isEditable && !widget.isUnsynced) _submitFooter(),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  /// Shown instead of the Submit button while the draft is still local.
  ///
  /// It explains rather than disables, for the reason the rest of this screen
  /// follows: a greyed-out Submit invites a tap that can never work, and says
  /// nothing about why. This says exactly what has to happen first.
  static const Widget _unsyncedFooter = Padding(
    padding: EdgeInsets.fromLTRB(20, 24, 20, 0),
    child: Text(
      'Saved on this device. It can be submitted once it has synced to the '
      'server.',
      key: Key('detail-unsynced-notice'),
      textAlign: TextAlign.center,
      style: TextStyle(fontSize: 13, color: AppColors.label2),
    ),
  );

  /// Present only on a draft. A submitted inspection has no submit control at
  /// all rather than a disabled one — the same rule the add and report actions
  /// follow, since an affordance that can never succeed is worse than none.
  ///
  /// An inspection with no punch items can still be submitted: a site with
  /// nothing wrong is a real result, and refusing to record it would push
  /// people into inventing a defect.
  Widget _submitFooter() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_submitError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                _submitError!,
                key: const Key('submit-error'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: AppColors.red),
              ),
            ),
          CupertinoButton.filled(
            key: const Key('submit-inspection-button'),
            onPressed: _submitting ? null : _confirmAndSubmit,
            child: _submitting
                ? const CupertinoActivityIndicator(color: AppColors.card)
                : const Text('Submit Inspection'),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Submitting is permanent and makes this inspection visible to '
              'reviewers.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: AppColors.label2),
            ),
          ),
        ],
      ),
    );
  }

  /// Says why the screen is inert, rather than leaving the user to discover it
  /// by tapping things that do nothing.
  static const Widget _readOnlyNotice = Padding(
    padding: EdgeInsets.fromLTRB(20, 16, 20, 0),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(top: 1, right: 6),
          child: Icon(
            CupertinoIcons.lock_fill,
            size: 13,
            color: AppColors.label2,
          ),
        ),
        Expanded(
          child: Text(
            'Submitted — this inspection is a permanent record and can no '
            'longer be changed.',
            key: Key('read-only-notice'),
            style: TextStyle(fontSize: 13, color: AppColors.label2),
          ),
        ),
      ],
    ),
  );

  Widget _items() {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Text(
              _error!,
              key: const Key('items-error'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15, color: AppColors.red),
            ),
            const SizedBox(height: 12),
            CupertinoButton(onPressed: _load, child: const Text('Try Again')),
          ],
        ),
      );
    }

    final rows = _rows;
    if (rows == null) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CupertinoActivityIndicator()),
      );
    }

    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(32, 24, 32, 24),
        child: Text(
          // Don't invite a tap the screen cannot honour.
          _isEditable
              ? 'No items yet.\nTap + to add the first defect.'
              : 'No items were recorded.',
          key: const Key('items-empty'),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 17, color: AppColors.label2),
        ),
      );
    }

    return InsetCard(
      children: [
        for (final row in rows)
          _ItemRow(item: row, onTap: _isEditable ? () => _edit(row) : null),
      ],
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item, this.onTap});

  final InspectionItem item;

  /// Null on a submitted inspection: the row is a record, not a control.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final resolved = item.status.isResolved;
    final subtitle = [
      if (item.area != null) item.area!,
      if (item.description != null) item.description!,
    ].join('  ·  ');

    return CupertinoButton(
      padding: EdgeInsets.zero,
      minimumSize: Size.zero,
      onPressed: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppMetrics.gutter,
          vertical: 10,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    style: TextStyle(
                      fontSize: 17,
                      color: resolved ? AppColors.label2 : AppColors.label,
                      // Resolved items stay legible rather than being struck
                      // through: the text is still the record of what was wrong.
                      fontWeight: FontWeight.w400,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppColors.label2,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            if (resolved)
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: Icon(
                  CupertinoIcons.checkmark_circle_fill,
                  size: 18,
                  color: AppColors.green,
                ),
              ),
            SeverityChip(severity: item.severity),
            // No chevron when the row is not tappable — it would promise an
            // interaction that does not exist.
            if (onTap != null) ...[
              const SizedBox(width: 6),
              const Icon(
                CupertinoIcons.chevron_forward,
                size: 16,
                color: AppColors.label3,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
