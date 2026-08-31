import 'package:flutter/cupertino.dart';

import '../data/models.dart';
import '../data/repositories.dart';
import 'theme.dart';

/// Presents the New Inspection sheet and returns the persisted inspection.
Future<Inspection?> showNewInspectionSheet(
  BuildContext context, {
  required InspectionsRepository inspections,
  required String inspectorName,
}) {
  return showCupertinoModalPopup<Inspection>(
    context: context,
    builder: (_) => NewInspectionSheet(
      inspections: inspections,
      inspectorName: inspectorName,
    ),
  );
}

/// Only the fields the accepted schema defines (SPEC W2, DATA_MODEL §3).
///
/// Two deliberate departures from the Figma mockup, both settled in favour of the
/// schema:
///   * The mockup's editable "Inspector" field is read-only here. `inspector_id`
///     comes from the session, and RLS forbids assigning an inspection to anyone
///     else — an editable field would promise something the database refuses.
///   * The mockup's "Template" picker is absent; templates are not in V1.
/// The mockup omits Client, which the schema has and search indexes, so it is
/// included.
class NewInspectionSheet extends StatefulWidget {
  const NewInspectionSheet({
    super.key,
    required this.inspections,
    required this.inspectorName,
  });

  final InspectionsRepository inspections;
  final String inspectorName;

  @override
  State<NewInspectionSheet> createState() => _NewInspectionSheetState();
}

class _NewInspectionSheetState extends State<NewInspectionSheet> {
  final _siteName = TextEditingController();
  final _siteAddress = TextEditingController();
  final _clientName = TextEditingController();

  DateTime _date = DateTime.now();
  bool _busy = false;
  String? _error;
  bool _showValidation = false;

  @override
  void dispose() {
    _siteName.dispose();
    _siteAddress.dispose();
    _clientName.dispose();
    super.dispose();
  }

  NewInspection get _draft => NewInspection(
        siteName: _siteName.text,
        siteAddress: _siteAddress.text,
        clientName: _clientName.text,
        inspectionDate: _date,
      );

  Future<void> _save() async {
    if (_busy) return;

    setState(() => _showValidation = true);
    if (!InspectionLimits.isValid(_draft)) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final created = await widget.inspections.create(_draft);
      if (mounted) Navigator.of(context).pop(created);
    } catch (e) {
      // Includes an RLS refusal. The user sees the real failure.
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickDate() async {
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (_) => Container(
        height: 260,
        color: AppColors.card,
        child: SafeArea(
          top: false,
          child: CupertinoDatePicker(
            mode: CupertinoDatePickerMode.date,
            initialDateTime: _date,
            maximumDate: DateTime.now().add(const Duration(days: 365)),
            onDateTimeChanged: (d) => setState(() => _date = d),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.92;

    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
        child: Container(
          color: AppColors.background,
          constraints: BoxConstraints(maxHeight: maxHeight),
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
                      const SectionHeader(label: 'Property'),
                      InsetCard(
                        children: [
                          FormRow(
                            label: 'Name',
                            controller: _siteName,
                            placeholder: 'Property or site name',
                            autofocus: true,
                            onChanged: (_) => setState(() {}),
                            errorText: _showValidation
                                ? InspectionLimits.validateSiteName(
                                    _siteName.text,
                                  )
                                : null,
                          ),
                          FormRow(
                            label: 'Address',
                            controller: _siteAddress,
                            placeholder: 'Street address',
                            errorText: _showValidation
                                ? InspectionLimits.validateSiteAddress(
                                    _siteAddress.text,
                                  )
                                : null,
                          ),
                          FormRow(
                            label: 'Client',
                            controller: _clientName,
                            placeholder: 'Optional',
                            errorText: _showValidation
                                ? InspectionLimits.validateClientName(
                                    _clientName.text,
                                  )
                                : null,
                          ),
                        ],
                      ),
                      const SectionHeader(label: 'Inspection'),
                      InsetCard(
                        children: [
                          _dateRow(),
                          // Read-only: the owner is the signed-in user (D3/RLS).
                          ReadOnlyRow(
                            label: 'Inspector',
                            value: widget.inspectorName,
                            valueKey: const Key('inspector-readonly'),
                          ),
                        ],
                      ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                          child: Text(
                            _error!,
                            key: const Key('new-inspection-error'),
                            style: const TextStyle(
                              fontSize: 13,
                              color: AppColors.red,
                            ),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
                        child: PrimaryButton(
                          key: const Key('create-inspection-button'),
                          label: 'Create Inspection',
                          busy: _busy,
                          onPressed: _save,
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
              onPressed: _busy ? null : () => Navigator.of(context).pop(),
              child: const Text(
                'Cancel',
                style: TextStyle(fontSize: 17, color: AppColors.blue),
              ),
            ),
            const Expanded(
              child: Text(
                'New Inspection',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
              ),
            ),
            CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              minimumSize: Size.zero,
              color: AppColors.blue,
              borderRadius: BorderRadius.circular(8),
              onPressed: _busy ? null : _save,
              child: const Text(
                'Create',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppColors.card,
                ),
              ),
            ),
          ],
        ),
      );

  Widget _dateRow() => CupertinoButton(
        padding: EdgeInsets.zero,
        minimumSize: Size.zero,
        onPressed: _pickDate,
        child: Container(
          constraints: const BoxConstraints(minHeight: AppMetrics.rowHeight),
          padding: const EdgeInsets.symmetric(horizontal: AppMetrics.gutter),
          child: Row(
            children: [
              const SizedBox(
                width: 100,
                child: Text(
                  'Date',
                  style: TextStyle(fontSize: 17, color: AppColors.label),
                ),
              ),
              Expanded(
                child: Text(
                  NewInspection.dateOnly(_date),
                  key: const Key('inspection-date'),
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 17, color: AppColors.label2),
                ),
              ),
            ],
          ),
        ),
      );
}
