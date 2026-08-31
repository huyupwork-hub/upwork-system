import 'package:flutter/cupertino.dart';

import '../data/models.dart';
import '../data/repositories.dart';
import 'photo_strip.dart';
import 'theme.dart';

/// Presents the punch-item editor and returns true if anything was persisted.
///
/// One sheet for both create and edit: the fields are identical, and a second
/// near-copy would be two places to keep in step.
Future<bool?> showItemEditorSheet(
  BuildContext context, {
  required InspectionItemsRepository items,
  required PhotosRepository photos,
  required PhotoSource source,
  required String inspectionId,
  InspectionItem? existing,
}) {
  return showCupertinoModalPopup<bool>(
    context: context,
    builder: (_) => ItemEditorSheet(
      items: items,
      photos: photos,
      source: source,
      inspectionId: inspectionId,
      existing: existing,
    ),
  );
}

/// Only the fields the accepted schema defines (DATA_MODEL §3).
///
/// Deliberately absent, all Figma-only: assignee, template, organisation, and
/// the `in-review` status. Severity offers the schema's four values, not the
/// mockup's three (D14).
class ItemEditorSheet extends StatefulWidget {
  const ItemEditorSheet({
    super.key,
    required this.items,
    required this.photos,
    required this.source,
    required this.inspectionId,
    this.existing,
  });

  final InspectionItemsRepository items;
  final PhotosRepository photos;
  final PhotoSource source;
  final String inspectionId;
  final InspectionItem? existing;

  bool get isEditing => existing != null;

  @override
  State<ItemEditorSheet> createState() => _ItemEditorSheetState();
}

class _ItemEditorSheetState extends State<ItemEditorSheet> {
  late final TextEditingController _title;
  late final TextEditingController _description;
  late final TextEditingController _area;
  late ItemSeverity _severity;
  late ItemStatus _status;

  bool _busy = false;
  String? _error;
  bool _showValidation = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _title = TextEditingController(text: e?.title ?? '');
    _description = TextEditingController(text: e?.description ?? '');
    _area = TextEditingController(text: e?.area ?? '');
    _severity = e?.severity ?? ItemSeverity.medium;
    _status = e?.status ?? ItemStatus.open;
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _area.dispose();
    super.dispose();
  }

  NewInspectionItem get _draft => NewInspectionItem(
        title: _title.text,
        description: _description.text,
        area: _area.text,
        severity: _severity,
      );

  Future<void> _save() async {
    if (_busy) return;

    setState(() => _showValidation = true);
    if (!ItemLimits.isValid(_draft)) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      if (widget.isEditing) {
        await widget.items.update(
          widget.existing!.id,
          title: _title.text,
          description: _description.text,
          area: _area.text,
          severity: _severity,
          status: _status,
        );
      } else {
        await widget.items.create(widget.inspectionId, _draft);
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      // Includes an RLS refusal, which the repository turns into
      // NotPermittedException rather than reporting a silent denial as success.
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final confirmed = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: const Text('Delete this item?'),
        message: const Text('This cannot be undone.'),
        actions: [
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(sheetContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheetContext).pop(false),
          child: const Text('Cancel'),
        ),
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.items.delete(widget.existing!.id);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
        child: Container(
          color: AppColors.background,
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.92,
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _grabHandle(),
                _header(),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      const SectionHeader(label: 'Defect'),
                      InsetCard(
                        children: [
                          FormRow(
                            label: 'Title',
                            controller: _title,
                            placeholder: 'What is wrong',
                            autofocus: !widget.isEditing,
                            onChanged: (_) => setState(() {}),
                            errorText: _showValidation
                                ? ItemLimits.validateTitle(_title.text)
                                : null,
                          ),
                          FormRow(
                            label: 'Area',
                            controller: _area,
                            placeholder: 'Room or zone',
                            errorText: _showValidation
                                ? ItemLimits.validateArea(_area.text)
                                : null,
                          ),
                          FormRow(
                            label: 'Detail',
                            controller: _description,
                            placeholder: 'Optional',
                            errorText: _showValidation
                                ? ItemLimits.validateDescription(
                                    _description.text,
                                  )
                                : null,
                          ),
                        ],
                      ),
                      const SectionHeader(label: 'Severity'),
                      _severityPicker(),
                      // Photos need an item to attach to, so they appear only once the
                      // item exists. Creating then attaching is one extra tap; the
                      // alternative is holding bytes in memory against a row that may
                      // never be saved.
                      if (widget.isEditing) ...[
                        const SectionHeader(label: 'Photos'),
                        PhotoStrip(
                          photos: widget.photos,
                          source: widget.source,
                          inspectionId: widget.inspectionId,
                          itemId: widget.existing!.id,
                          editable: true,
                        ),
                      ],
                      const SectionHeader(label: 'Status'),
                      _statusRow(),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                          child: Text(
                            _error!,
                            key: const Key('item-editor-error'),
                            style: const TextStyle(
                              fontSize: 13,
                              color: AppColors.red,
                            ),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
                        child: PrimaryButton(
                          key: const Key('save-item-button'),
                          label: widget.isEditing ? 'Save Changes' : 'Add Item',
                          busy: _busy,
                          onPressed: _save,
                        ),
                      ),
                      if (widget.isEditing)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                          child: CupertinoButton(
                            key: const Key('delete-item-button'),
                            onPressed: _busy ? null : _delete,
                            child: const Text(
                              'Delete Item',
                              style: TextStyle(color: AppColors.red),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _grabHandle() => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Container(
          width: 36,
          height: 5,
          decoration: BoxDecoration(
            color: AppColors.label3,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      );

  Widget _header() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              onPressed: _busy ? null : () => Navigator.of(context).pop(false),
              child: const Text(
                'Cancel',
                style: TextStyle(fontSize: 17, color: AppColors.blue),
              ),
            ),
            Expanded(
              child: Text(
                widget.isEditing ? 'Edit Item' : 'New Item',
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
              ),
            ),
            // Balances the Cancel button so the title stays centred.
            const SizedBox(width: 60),
          ],
        ),
      );

  Widget _severityPicker() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppMetrics.gutter),
        child: CupertinoSlidingSegmentedControl<ItemSeverity>(
          groupValue: _severity,
          onValueChanged: (v) {
            if (v != null) setState(() => _severity = v);
          },
          children: {
            for (final s in ItemSeverity.values)
              s: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  s.label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: SeverityPalette.foreground(s),
                  ),
                ),
              ),
          },
        ),
      );

  Widget _statusRow() => InsetCard(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppMetrics.gutter,
              vertical: 10,
            ),
            child: Row(
              children: [
                const Expanded(
                  child: Text('Resolved', style: TextStyle(fontSize: 17)),
                ),
                CupertinoSwitch(
                  key: const Key('item-resolved-switch'),
                  value: _status.isResolved,
                  onChanged: (v) => setState(
                    () => _status = v ? ItemStatus.resolved : ItemStatus.open,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
}
