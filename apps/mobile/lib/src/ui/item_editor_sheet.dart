import 'package:flutter/cupertino.dart';

import '../data/models.dart';
import '../data/repositories.dart';
import 'photo_strip.dart';
import 'theme.dart';

/// Presents the finding editor and returns true if anything was persisted.
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
        title: const Text('Delete this finding?'),
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
                      _severityHintLine(),
                      // Photos need a row to attach to, so the strip appears
                      // only once the finding exists. Creating then attaching is
                      // one extra tap; the alternative is holding bytes in
                      // memory against a row that may never be saved. The
                      // section header is shown either way so the capability is
                      // visible before it is reachable.
                      const SectionHeader(label: 'Photos'),
                      if (widget.isEditing)
                        PhotoStrip(
                          photos: widget.photos,
                          source: widget.source,
                          inspectionId: widget.inspectionId,
                          itemId: widget.existing!.id,
                          editable: true,
                        )
                      else
                        _photosAfterSaveNote(),
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
                          label:
                              widget.isEditing ? 'Save Changes' : 'Add Finding',
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
                              'Delete Finding',
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
                widget.isEditing ? 'Edit Finding' : 'New Finding',
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

  /// What each level is for, in the words a site report would use.
  ///
  /// Severity is the one field on this sheet that changes what happens next —
  /// it orders the findings list, drives the breakdown on the detail screen and
  /// feeds the counts a reviewer triages by. Four bare words leave the boundary
  /// between them to guesswork, and two inspectors guessing differently is how
  /// a severity column stops meaning anything.
  ///
  /// Static copy, not data: it describes the choice being made. Nothing here is
  /// stored, sent, or derived from a record.
  static String _severityHint(ItemSeverity s) => switch (s) {
        ItemSeverity.critical => 'Unsafe now. Stop work or make safe today.',
        ItemSeverity.high => 'Must be fixed before the site is handed over.',
        ItemSeverity.medium => 'Schedule a repair in the normal run of work.',
        ItemSeverity.low => 'Cosmetic or wear. Record it, fix when convenient.',
      };

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

  Widget _severityHintLine() => Padding(
        padding: const EdgeInsets.fromLTRB(AppMetrics.gutter, 8, 16, 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 5),
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: SeverityPalette.foreground(_severity),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                _severityHint(_severity),
                key: const Key('severity-hint'),
                style: const TextStyle(fontSize: 13, color: AppColors.label2),
              ),
            ),
          ],
        ),
      );

  /// Photos attach to a row, so before the row exists there is nothing to
  /// attach them to.
  ///
  /// Said plainly rather than left as an absence. An inspector who expects a
  /// camera here and finds nothing has to guess whether the feature is missing
  /// or the screen is broken, and one line removes the question. Deliberately
  /// not a DependencyNote: photo capture and upload are built and working, and
  /// dressing a sequencing rule up as a missing integration would be its own
  /// small untruth.
  Widget _photosAfterSaveNote() => const Padding(
        padding: EdgeInsets.fromLTRB(AppMetrics.gutter, 6, 16, 0),
        child: Text(
          'Photos can be attached once the finding is saved.',
          key: Key('photos-after-save'),
          style: TextStyle(fontSize: 13, color: AppColors.label2),
        ),
      );

  Widget _statusRow() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InsetCard(
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
                        () =>
                            _status = v ? ItemStatus.resolved : ItemStatus.open,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppMetrics.gutter, 6, 16, 0),
            child: Text(
              _status.isResolved
                  ? 'Resolved findings stay in the report as evidence of the '
                      'fix.'
                  : 'Open findings are counted in the summary and in the '
                      'reviewer queue.',
              key: const Key('status-hint'),
              style: const TextStyle(fontSize: 13, color: AppColors.label2),
            ),
          ),
        ],
      );
}
