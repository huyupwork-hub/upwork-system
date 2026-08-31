import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../data/models.dart';
import '../data/repositories.dart';
import '../report/report_service.dart';
import 'inspection_detail_screen.dart';
import 'new_inspection_screen.dart';
import 'theme.dart';

/// History and search for the signed-in inspector.
///
/// RLS guarantees these can only ever be the caller's own rows; the screen sends
/// no inspector id and does no filtering of its own. Search runs in the database
/// against the stored `search_tsv` and its GIN index — not by fetching
/// everything and filtering here, which would neither scale nor respect what the
/// policies are for.
class InspectionsScreen extends StatefulWidget {
  const InspectionsScreen({
    super.key,
    required this.auth,
    required this.profiles,
    required this.inspections,
    required this.items,
    required this.photos,
    required this.source,
    required this.reports,
  });

  final AuthRepository auth;
  final ProfileRepository profiles;
  final InspectionsRepository inspections;
  final InspectionItemsRepository items;
  final PhotosRepository photos;
  final PhotoSource source;
  final ReportService reports;

  @override
  State<InspectionsScreen> createState() => _InspectionsScreenState();
}

class _InspectionsScreenState extends State<InspectionsScreen> {
  final _search = TextEditingController();

  Profile? _profile;
  List<Inspection>? _rows;
  String? _error;

  /// The query the displayed rows came from, so the empty state can tell "you
  /// have no inspections" from "nothing matched that".
  String _shownQuery = '';

  /// Monotonic request token. Every load takes the next value and applies its
  /// result only if it is still the newest — this is what stops a slow response
  /// for "a" landing after a fast one for "abc" and overwriting it.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load({String query = ''}) async {
    final generation = ++_generation;
    setState(() => _error = null);

    try {
      final profile = _profile ?? await widget.profiles.loadCurrent();
      final trimmed = query.trim();
      final rows = trimmed.isEmpty
          ? await widget.inspections.listMine()
          : await widget.inspections.searchMine(trimmed);

      // Superseded by a newer keystroke: drop this result on the floor. The
      // existing rows stay on screen throughout, so the list never flashes away
      // mid-typing.
      if (!mounted || generation != _generation) return;
      setState(() {
        _profile = profile;
        _rows = rows;
        _shownQuery = trimmed;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() => _error = e.toString());
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
    // A new inspection would probably not match the current query, so clearing
    // it is the only way the user sees what they just made.
    if (created != null) {
      _search.clear();
      await _load();
    }
  }

  Future<void> _openDetail(Inspection inspection) async {
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => InspectionDetailScreen(
          inspection: inspection,
          items: widget.items,
          photos: widget.photos,
          source: widget.source,
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
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppMetrics.gutter,
                8,
                AppMetrics.gutter,
                4,
              ),
              child: CupertinoSearchTextField(
                key: const Key('inspections-search'),
                controller: _search,
                placeholder: 'Site, address or client',
                // No debounce: the generation token already makes out-of-order
                // responses harmless, and at this dataset size a timer would add
                // latency and one more moving part for no gain.
                onChanged: (value) => unawaited(_load(query: value)),
                onSuffixTap: () {
                  _search.clear();
                  unawaited(_load());
                },
              ),
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
            CupertinoButton(
              onPressed: () => _load(query: _search.text),
              child: const Text('Try Again'),
            ),
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
      // Two different situations that must not read the same. "No inspections
      // yet" points at the + button; "nothing matched" points at the query.
      return Padding(
        padding: const EdgeInsets.fromLTRB(32, 48, 32, 32),
        child: Text(
          _shownQuery.isEmpty
              ? 'No inspections yet.\nTap + to create one.'
              : 'No inspections match "$_shownQuery".',
          key: Key(
            _shownQuery.isEmpty ? 'inspections-empty' : 'inspections-no-matches',
          ),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 17, color: AppColors.label2),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          label: _shownQuery.isEmpty ? 'All Inspections' : 'Results',
        ),
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
      if (inspection.siteAddress != null) inspection.siteAddress!,
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
                    style: const TextStyle(fontSize: 17, color: AppColors.label),
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
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
