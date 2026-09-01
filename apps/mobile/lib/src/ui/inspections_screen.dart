import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../data/models.dart';
import '../data/repositories.dart';
import '../offline/offline_status.dart';
import '../report/report_service.dart';
import 'presentation.dart';
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
    required this.profiles,
    required this.inspections,
    required this.items,
    required this.photos,
    required this.source,
    required this.reports,
    this.offline,
    this.onSync,
  });

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

  /// Which slice of the loaded list is on screen. Presentation only — it never
  /// reaches the repository, so search keeps being the one thing that queries.
  _ListFilter _filter = _ListFilter.all;

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
      // The list first, and the profile after — the order is the fix for a
      // defect real-device QA found. Loading the profile first meant one
      // network call the offline path does not own could fail the whole screen:
      // reopening the app in a basement showed a raw DNS error and no
      // inspections at all, so an inspector's saved work looked lost when it
      // was safely on disk. Nothing on this screen needs the profile to render
      // the history, so nothing on this screen waits for it.
      final trimmed = query.trim();
      final rows = trimmed.isEmpty
          ? await widget.inspections.listMine()
          : await widget.inspections.searchMine(trimmed);

      final profile = _profile ?? await _loadProfileOrNull();

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

  /// The signed-in inspector's name, or null when it could not be fetched.
  ///
  /// Only a transport failure is tolerated. A `ProfileMissingException` means
  /// the schema bootstrap failed (D13) and must stay visible, so it propagates
  /// and the screen shows it — the same rule the offline repositories follow
  /// for a refusal versus an outage.
  Future<Profile?> _loadProfileOrNull() async {
    try {
      return await widget.profiles.loadCurrent();
    } catch (e) {
      if (!isTransportFailure(e)) rethrow;
      return null;
    }
  }

  Future<void> _newInspection() async {
    // Deliberately not gated on the profile any more. The name is a read-only
    // courtesy on the sheet; ownership comes from the session and RLS (D14), so
    // not knowing what to print is no reason to refuse the one action this
    // slice exists to make possible offline.
    final created = await showNewInspectionSheet(
      context,
      inspections: widget.inspections,
      inspectorName: _profile?.fullName,
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
            trailing: CupertinoButton(
              padding: EdgeInsets.zero,
              // Enabled as soon as the screen has loaded, profile or not. It
              // used to wait for the profile, which meant the New Inspection
              // action was dead in exactly the situation the offline slice is
              // for: no signal, nothing cached, work to record.
              onPressed: _rows == null ? null : _newInspection,
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
                ? _listSection()
                : ValueListenableBuilder<OfflineStatus>(
                    valueListenable: widget.offline!,
                    builder: (context, _, __) => _listSection(),
                  ),
          ),
        ],
      ),
    );
  }

  /// Summary, filter and list. Split from [_body] so the summary can read the
  /// same loaded rows the list does — it is a view over them, never a
  /// second source.
  Widget _listSection() {
    final rows = _rows;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Nothing to summarise and nothing to filter when the list is empty.
        // Three zeroes and a dead segmented control are furniture, and they push
        // the one sentence that matters — how to start — down the screen.
        if (rows != null &&
            rows.isNotEmpty &&
            _error == null &&
            _shownQuery.isEmpty) ...[
          _summary(rows),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppMetrics.gutter,
              14,
              AppMetrics.gutter,
              2,
            ),
            child: SegmentedFilter<_ListFilter>(
              key: const Key('inspections-filter'),
              value: _filter,
              onChanged: (f) => setState(() => _filter = f),
              segments: const [
                (_ListFilter.all, 'All'),
                (_ListFilter.drafts, 'Drafts'),
                (_ListFilter.submitted, 'Submitted'),
              ],
            ),
          ),
        ],
        _body(),
      ],
    );
  }

  Widget _body() {
    if (_error != null) {
      return ErrorState(
        title: 'Your inspections could not be loaded',
        detail: _error!,
        detailKey: const Key('inspections-error'),
        onRetry: () => _load(query: _search.text),
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

    // Client-side narrowing of rows the server already returned. It is a view
    // over the loaded list, not a second query — search stays the one thing
    // that talks to Postgres, so its proven semantics are untouched.
    final shown = switch (_filter) {
      _ListFilter.all => rows,
      _ListFilter.drafts =>
        rows.where((r) => r.status == InspectionStatus.draft).toList(),
      _ListFilter.submitted =>
        rows.where((r) => r.status == InspectionStatus.submitted).toList(),
    };

    if (shown.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(32, 40, 32, 32),
        child: Text(
          'No ${_filter == _ListFilter.drafts ? 'drafts' : 'submitted '
              'inspections'} here.',
          key: const Key('inspections-filter-empty'),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 15, color: AppColors.label2),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          label: _shownQuery.isEmpty
              ? '${shown.length} Inspection${shown.length == 1 ? '' : 's'}'
              : 'Results',
        ),
        InsetCard(
          children: [
            for (final row in shown)
              _InspectionRow(
                inspection: row,
                isUnsynced: _isUnsynced(row.id),
                onTap: () => _openDetail(row),
              ),
          ],
        ),
        const SizedBox(height: 28),
      ],
    );
  }

  /// The portfolio's first impression: who is signed in, and what is on their
  /// plate. Every number here is counted from the rows already on screen, so it
  /// costs no query and cannot disagree with the list below it.
  Widget _summary(List<Inspection> rows) {
    final drafts = rows.where((r) => r.status == InspectionStatus.draft).length;
    final submitted = rows.length - drafts;
    final pending = widget.offline?.value.pending ?? 0;
    final profile = _profile;

    return Padding(
      padding: const EdgeInsets.fromLTRB(AppMetrics.gutter, 4, 16, 2),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(AppMetrics.cardRadius),
          border: Border.all(color: AppColors.separator, width: 0.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: const BoxDecoration(
                    color: AppColors.blueTint,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    _initials(profile?.fullName),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppColors.blue,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        profile?.fullName ?? 'Signed in',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: AppColors.label,
                        ),
                      ),
                      Text(
                        profile == null
                            ? 'Field inspector'
                            : _roleLabel(profile.role),
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppColors.label2,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                _Metric(value: '$drafts', label: 'In draft'),
                _Metric(value: '$submitted', label: 'Submitted'),
                _Metric(
                  value: '$pending',
                  label: 'Not synced',
                  emphasis: pending > 0 ? AppColors.orange : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _initials(String? name) {
    final parts = (name ?? '')
        .trim()
        .split(RegExp(r'[\s._-]+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '—';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts[1].substring(0, 1))
        .toUpperCase();
  }

  static String _roleLabel(String role) =>
      role == 'admin' ? 'Reviewer' : 'Inspector';
}

/// Which slice of the loaded list is shown. Presentation only.
enum _ListFilter { all, drafts, submitted }

/// One number and its caption, three across.
class _Metric extends StatelessWidget {
  const _Metric({required this.value, required this.label, this.emphasis});

  final String value;
  final String label;
  final Color? emphasis;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.5,
              color: emphasis ?? AppColors.label,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: AppColors.label2),
          ),
        ],
      ),
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
    // Address is the line a field inspector navigates by, so it gets its own
    // row rather than being crushed into a middle-dot list with the date.
    final address = inspection.siteAddress;
    final client = inspection.clientName;

    return CupertinoButton(
      padding: EdgeInsets.zero,
      minimumSize: Size.zero,
      onPressed: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 14, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          inspection.siteName,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            color: AppColors.label,
                            letterSpacing: -0.2,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      // The prototype's small amber dot beside a name that is
                      // still only on the device. Redundant with the pill
                      // below by design — the dot is what survives a glance.
                      if (isUnsynced) ...[
                        const SizedBox(width: 7),
                        Container(
                          width: 7,
                          height: 7,
                          decoration: const BoxDecoration(
                            color: AppColors.orange,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (address != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      address,
                      style: const TextStyle(
                        fontSize: 15,
                        color: AppColors.label2,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 7),
                  Row(
                    children: [
                      if (isUnsynced) ...[
                        const UnsyncedPill(),
                        const SizedBox(width: 6),
                      ],
                      PhasePill(phase: InspectionPhase.of(inspection)),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          [
                            NewInspection.dateOnly(inspection.inspectionDate),
                            if (client != null) client,
                          ].join('  ·  '),
                          style: const TextStyle(
                            fontSize: 13,
                            color: AppColors.label2,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(left: 8, top: 4),
              child: Icon(
                CupertinoIcons.chevron_forward,
                size: 16,
                color: AppColors.label3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
