import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../data/models.dart';
import '../data/repositories.dart';
import 'item_editor_sheet.dart';
import 'theme.dart';

/// One inspection and its punch list.
///
/// Items are editable regardless of the inspection's status. That is the accepted
/// contract, not an oversight: `inspection_items_update_own` gates on ownership
/// only, and D10 records that locking a submitted inspection's content was
/// considered and not adopted. A UI-only lock would be theatre — the database
/// would still accept the write.
class InspectionDetailScreen extends StatefulWidget {
  const InspectionDetailScreen({
    super.key,
    required this.inspection,
    required this.items,
  });

  final Inspection inspection;
  final InspectionItemsRepository items;

  @override
  State<InspectionDetailScreen> createState() => _InspectionDetailScreenState();
}

class _InspectionDetailScreenState extends State<InspectionDetailScreen> {
  List<InspectionItem>? _rows;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final rows = await widget.items.listFor(widget.inspection.id);
      if (!mounted) return;
      setState(() => _rows = rows);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _edit([InspectionItem? existing]) async {
    final changed = await showItemEditorSheet(
      context,
      items: widget.items,
      inspectionId: widget.inspection.id,
      existing: existing,
    );
    if (changed == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.inspection;
    return CupertinoPageScaffold(
      backgroundColor: AppColors.background,
      navigationBar: CupertinoNavigationBar(
        middle: const Text('Inspection'),
        previousPageTitle: 'Inspections',
        trailing: CupertinoButton(
          key: const Key('add-item-button'),
          padding: EdgeInsets.zero,
          onPressed: () => _edit(),
          child: const Icon(CupertinoIcons.add, color: AppColors.blue),
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
            const SectionHeader(label: 'Punch list'),
            _items(),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

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
      return const Padding(
        padding: EdgeInsets.fromLTRB(32, 24, 32, 24),
        child: Text(
          'No items yet.\nTap + to add the first defect.',
          key: Key('items-empty'),
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 17, color: AppColors.label2),
        ),
      );
    }

    return InsetCard(
      children: [
        for (final row in rows) _ItemRow(item: row, onTap: () => _edit(row)),
      ],
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item, required this.onTap});

  final InspectionItem item;
  final VoidCallback onTap;

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
            const SizedBox(width: 6),
            const Icon(
              CupertinoIcons.chevron_forward,
              size: 16,
              color: AppColors.label3,
            ),
          ],
        ),
      ),
    );
  }
}
