import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../data/models.dart';
import '../data/repositories.dart';
import 'inspection_detail_screen.dart';
import 'new_inspection_screen.dart';
import 'theme.dart';

/// History for the signed-in inspector, with the Figma large-title treatment.
///
/// RLS guarantees these can only ever be the caller's own rows; the screen does
/// no filtering of its own beyond the query. Search and the status segmented
/// control appear in the mockup but belong to the later search slice (SPEC W8),
/// so they are deliberately absent here.
class InspectionsScreen extends StatefulWidget {
  const InspectionsScreen({
    super.key,
    required this.auth,
    required this.profiles,
    required this.inspections,
    required this.items,
  });

  final AuthRepository auth;
  final ProfileRepository profiles;
  final InspectionsRepository inspections;
  final InspectionItemsRepository items;

  @override
  State<InspectionsScreen> createState() => _InspectionsScreenState();
}

class _InspectionsScreenState extends State<InspectionsScreen> {
  Profile? _profile;
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
      // The profile is the bootstrap check: it must exist for the schema to be
      // sound. A failure here is surfaced, never swallowed.
      final profile = await widget.profiles.loadCurrent();
      final rows = await widget.inspections.listMine();
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _rows = rows;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _newInspection() async {
    final profile = _profile;
    if (profile == null) return;

    final created = await showNewInspectionSheet(
      context,
      inspections: widget.inspections,
      inspectorName: profile.fullName,
    );
    if (created != null) await _load();
  }

  Future<void> _openDetail(Inspection inspection) async {
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => InspectionDetailScreen(
          inspection: inspection,
          items: widget.items,
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
          CupertinoSliverNavigationBar(
            largeTitle: const Text('Inspections'),
            backgroundColor: AppColors.card,
            border: const Border(
              bottom: BorderSide(color: AppColors.separator, width: 0.5),
            ),
            leading: CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: widget.auth.signOut,
              child: const Text(
                'Sign Out',
                style: TextStyle(fontSize: 17, color: AppColors.blue),
              ),
            ),
            trailing: CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: _profile == null ? null : _newInspection,
              child: const Icon(CupertinoIcons.add, color: AppColors.blue),
            ),
          ),
          SliverToBoxAdapter(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          children: [
            Text(
              _error!,
              key: const Key('inspections-error'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15, color: AppColors.red),
            ),
            const SizedBox(height: 16),
            CupertinoButton(onPressed: _load, child: const Text('Try Again')),
          ],
        ),
      );
    }

    final rows = _rows;
    if (rows == null) {
      return const Padding(
        padding: EdgeInsets.all(48),
        child: Center(child: CupertinoActivityIndicator()),
      );
    }

    if (rows.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(32, 64, 32, 32),
        child: Text(
          'No inspections yet.\nTap + to create one.',
          key: Key('inspections-empty'),
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 17, color: AppColors.label2),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(label: 'All Inspections'),
        InsetCard(
          children: [
            for (final row in rows)
              _InspectionRow(inspection: row, onTap: () => _openDetail(row)),
          ],
        ),
        if (_profile != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Text(
              'Signed in as ${_profile!.fullName}',
              style: const TextStyle(fontSize: 13, color: AppColors.label2),
            ),
          ),
        const SizedBox(height: 32),
      ],
    );
  }
}

class _InspectionRow extends StatelessWidget {
  const _InspectionRow({required this.inspection, required this.onTap});

  final Inspection inspection;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final subtitle = [
      NewInspection.dateOnly(inspection.inspectionDate),
      if (inspection.clientName != null) inspection.clientName!,
    ].join('  ·  ');

    return CupertinoButton(
      padding: EdgeInsets.zero,
      minimumSize: Size.zero,
      onPressed: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    inspection.siteName,
                    style:
                        const TextStyle(fontSize: 17, color: AppColors.label),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.label2,
                    ),
                  ),
                ],
              ),
            ),
            _StatusPill(status: inspection.status),
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

/// Only the two persisted lifecycle states exist. The mockup also shows
/// "syncing" and "offline" chips; those are transient connectivity states, not
/// inspection lifecycle, and are never stored (docs/DECISIONS.md D5).
class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});

  final InspectionStatus status;

  @override
  Widget build(BuildContext context) {
    final isDraft = status == InspectionStatus.draft;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: isDraft ? AppColors.fill : AppColors.greenTint,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        isDraft ? 'Draft' : 'Submitted',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: isDraft ? AppColors.label2 : AppColors.green,
        ),
      ),
    );
  }
}
