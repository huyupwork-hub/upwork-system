import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../data/models.dart';
import '../data/repositories.dart';
import '../offline/offline_status.dart';
import '../report/report_service.dart';
import 'inspection_detail_screen.dart';
import 'new_inspection_screen.dart';
import 'offline_banner.dart';
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
    this.offline,
    this.onSync,
  });

  final AuthRepository auth;
  final ProfileRepository profiles;
  final InspectionsRepository inspections;
  final InspectionItemsRepository items;
  final PhotosRepository photos;
  final PhotoSource source;
  final ReportService reports;

  /// Null when no offline queue is wired. Optional rather than required so the
  /// screen still works — and still reads correctly — in a build that has no
  /// local persistence, and so tests written before this slice construct it
  /// unchanged.
  final OfflineStatusNotifier? offline;

  /// Runs a sync and returns when it has finished. Drives both the automatic
  /// attempt after a load and the manual Retry in the banner.
  final Future<void> Function()? onSync;

  @override
  State<InspectionsScreen> createState() => _InspectionsScreenState();
}

class _InspectionsScreenState extends State<InspectionsScreen>
    with WidgetsBindingObserver {
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
    WidgetsBinding.instance.addObserver(this);
    unawaited(_openingLoad());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _search.dispose();
    super.dispose();
  }

  /// Resume is the trigger, and the only automatic one.
  ///
  /// Coming back to the foreground is when a device that was in a basement has
  /// most plausibly regained signal, and it costs nothing when it has not: the
  /// push either succeeds or leaves the queue exactly as it was. There is no
  /// background service, no scheduler and no polling loop, and correctness does
  /// not depend on this firing at all — the Retry in the banner reaches the same
  /// code path deterministically.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_sync());
  }

  Future<void> _openingLoad() async {
    await _load();
    // Anything left from a previous session is pushed on the way in, so an
    // inspector who reopens the app with signal does not have to know that a
    // queue exists.
    if (mounted && (widget.offline?.value.hasPending ?? false)) await _sync();
  }

  /// Pushes whatever is queued, then reloads so the drafts that synced appear as
  /// the server-backed rows they now are.
  ///
  /// This is the deterministic retry path §7 asks for. It is also all the
  /// triggering there is on this screen: no timer, no polling, and no
  /// connectivity listener deciding on the app's behalf whether Supabase is
  /// reachable — the push itself is the only thing that knows.
  Future<void> _sync() async {
    final run = widget.onSync;
    if (run == null) return;
    await run();
    if (mounted) await _load(query: _search.text);
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

  bool _isUnsynced(String id) =>
      widget.offline?.value.pendingIds.contains(id) ?? false;

  Future<void> _openDetail(Inspection inspection) async {
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => InspectionDetailScreen(
          inspection: inspection,
          inspections: widget.inspections,
          items: widget.items,
          photos: widget.photos,
          source: widget.source,
          reports: widget.reports,
          // Read at push time from the queue, not stored on the record: whether
          // an inspection has reached the server is connectivity state, and D14
          // keeps connectivity out of the two persisted statuses.
          isUnsynced: _isUnsynced(inspection.id),
        ),
      ),
    );
    // The detail screen can submit, which changes the row's status. Without
    // this the list would still show "Draft" for work that is now frozen —
    // stale in exactly the place the user looks to confirm what they just did.
    if (mounted) await _load(query: _search.text);
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
          if (widget.offline != null)
            SliverToBoxAdapter(
              child: OfflineBanner(
                status: widget.offline!,
                onRetry: widget.onSync == null ? null : _sync,
              ),
            ),
          // Rebuilt on queue changes as well as on load, so a row's "Not synced"
          // marker cannot outlive the sync that cleared it.
          SliverToBoxAdapter(
            child: widget.offline == null
                ? _body()
                : ValueListenableBuilder<OfflineStatus>(
                    valueListenable: widget.offline!,
                    builder: (context, _, __) => _body(),
                  ),
          ),
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
            _shownQuery.isEmpty
                ? 'inspections-empty'
                : 'inspections-no-matches',
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
              _InspectionRow(
                inspection: row,
                isUnsynced: _isUnsynced(row.id),
                onTap: () => _openDetail(row),
              ),
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
  const _InspectionRow({
    required this.inspection,
    required this.onTap,
    this.isUnsynced = false,
  });

  final Inspection inspection;
  final bool isUnsynced;
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
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            // Both, when both are true: it is a draft *and* it is not on the
            // server yet. One pill would lose whichever fact it dropped.
            if (isUnsynced) ...[
              const UnsyncedPill(),
              const SizedBox(width: 6),
            ],
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
