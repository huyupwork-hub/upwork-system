/// Presentation-only derivations, kept away from the data layer on purpose.
///
/// Everything here is computed from rows the app already has, or is openly
/// labelled as demonstration content. Nothing in this file writes, persists, or
/// implies a backend capability that does not exist — the Figma prototype shows
/// a richer product than the schema carries, and the honest way to close that
/// gap is to derive what can be derived and mark the rest as what it is.
///
/// Three categories, used consistently:
///   * **real** — a column that exists (`site_name`, `severity`, `status`, …);
///   * **derived** — arithmetic over real rows (counts, progress, breakdowns);
///   * **demo** — deterministic presentation content with no backing column.
///     It is stable for a given id so screenshots and reviews do not shift, and
///     it never travels back into Supabase.
library;

import 'package:flutter/cupertino.dart';

import '../data/models.dart';
import 'theme.dart';

/// Counts a reviewer actually reads, derived from the punch list.
///
/// The prototype leads with "3 open / 5 items" and a severity breakdown, and
/// both are just arithmetic over rows the detail screen already loaded — no new
/// query, no new column.
class InspectionStats {
  const InspectionStats({
    required this.total,
    required this.open,
    required this.resolved,
    required this.bySeverity,
    required this.photos,
  });

  factory InspectionStats.from(
    List<InspectionItem> items, {
    int photos = 0,
  }) {
    final counts = <ItemSeverity, int>{};
    var open = 0;
    for (final item in items) {
      counts[item.severity] = (counts[item.severity] ?? 0) + 1;
      if (item.status == ItemStatus.open) open++;
    }
    return InspectionStats(
      total: items.length,
      open: open,
      resolved: items.length - open,
      bySeverity: counts,
      photos: photos,
    );
  }

  final int total;
  final int open;
  final int resolved;
  final Map<ItemSeverity, int> bySeverity;
  final int photos;

  int count(ItemSeverity s) => bySeverity[s] ?? 0;

  bool get isEmpty => total == 0;

  /// Resolved share, 0–1. Null when there is nothing to be a share *of* —
  /// an inspection with no findings is not 0% done, it is not measurable, and
  /// drawing an empty bar for it would state something false.
  double? get progress => total == 0 ? null : resolved / total;

  /// Severities present, worst first. Used to order the grouped list so the
  /// thing that stops a handover is the first thing on screen.
  List<ItemSeverity> get severitiesWorstFirst => const [
        ItemSeverity.critical,
        ItemSeverity.high,
        ItemSeverity.medium,
        ItemSeverity.low,
      ].where((s) => count(s) > 0).toList(growable: false);
}

/// What the status pill says, and why.
///
/// The prototype's vocabulary is `draft · in-progress · complete · syncing ·
/// offline`. The schema persists two states and D14 settled that the schema
/// wins, so `Submitted` is not renamed to `Complete` here — the word appears in
/// the submission dialog, the immutability notice, the admin console and the
/// database, and one screen using a different one would be the start of two
/// vocabularies. What the prototype gets from `in-progress` is a sense of work
/// underway, and that is supplied instead by counts and progress, which are
/// real.
///
/// `Not synced` and `Syncing` are genuine transient states owned by the offline
/// queue, so they are shown — as a *second* pill, never replacing the first,
/// because an inspection is a draft and unsynced at the same time.
enum InspectionPhase {
  draft,
  submitted;

  static InspectionPhase of(Inspection i) =>
      i.status == InspectionStatus.submitted
          ? InspectionPhase.submitted
          : InspectionPhase.draft;

  String get label => switch (this) {
        InspectionPhase.draft => 'Draft',
        InspectionPhase.submitted => 'Submitted',
      };

  Color get foreground => switch (this) {
        InspectionPhase.draft => AppColors.label2,
        InspectionPhase.submitted => AppColors.green,
      };

  Color get tint => switch (this) {
        InspectionPhase.draft => AppColors.fill,
        InspectionPhase.submitted => AppColors.greenTint,
      };
}

/// Deterministic demonstration content, isolated here so it is obvious what is
/// invented and trivial to delete when a column arrives to replace it.
///
/// The prototype shows an inspection template ("Residential Pre-Handover",
/// "Commercial TI"). There is no template in the schema and D14 recorded that
/// templates are not in V1 — so this is presentation only. It is derived from
/// the inspection id rather than randomised, which matters twice: a reviewer
/// revisiting a record sees the same thing, and a screenshot taken today still
/// matches the app tomorrow.
class DemoContent {
  const DemoContent._();

  static const List<String> _templates = [
    'Residential Pre-Handover',
    'Commercial TI',
    'Multi-Family Turnover',
    'Industrial Facility',
  ];

  /// Stable across runs and processes: a plain sum over the id's code units,
  /// not `hashCode`, which Dart does not guarantee between runs.
  static int _seed(String id) {
    var h = 0;
    for (final unit in id.codeUnits) {
      h = (h + unit) % 100003;
    }
    return h;
  }

  static String templateFor(String inspectionId) =>
      _templates[_seed(inspectionId) % _templates.length];
}

/// A visible, honest statement that some capability is not wired up.
///
/// The brief for this pass asks that missing integrations be shown rather than
/// hidden or faked, and this is the one component that does it. It is styled as
/// product copy, not as a developer warning: a reviewer should read it as "this
/// product has a paid tier / an integration step", which is the truth, rather
/// than as a stack trace leaking into the UI.
///
/// Used sparingly. A note belongs only where the missing capability is visible
/// or would otherwise be actionable on that screen.
class DependencyNote extends StatelessWidget {
  const DependencyNote({
    super.key,
    required this.title,
    required this.requirement,
  });

  /// What the user would have expected to be able to do.
  final String title;

  /// What is missing, phrased as the product would phrase it.
  final String requirement;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('dependency-note'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.separator, width: 0.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(
              CupertinoIcons.info_circle,
              size: 15,
              color: AppColors.label3,
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: AppColors.label,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  requirement,
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
    );
  }
}

/// The status pill used everywhere an inspection is listed.
class PhasePill extends StatelessWidget {
  const PhasePill({super.key, required this.phase});

  final InspectionPhase phase;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: phase.tint,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        phase.label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: phase.foreground,
          letterSpacing: -0.1,
        ),
      ),
    );
  }
}

/// A compact "3 open · 5 findings · 2 photos" line.
///
/// Deliberately words rather than icons: "5" beside a dot means nothing to
/// someone seeing the screen for the first time.
class StatsLine extends StatelessWidget {
  const StatsLine({super.key, required this.stats, this.style});

  final InspectionStats stats;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final parts = <String>[
      if (stats.total == 0)
        'No findings'
      else ...[
        '${stats.open} open',
        '${stats.total} finding${stats.total == 1 ? '' : 's'}',
      ],
      if (stats.photos > 0)
        '${stats.photos} photo${stats.photos == 1 ? '' : 's'}',
    ];
    return Text(
      parts.join('  ·  '),
      style: style ?? const TextStyle(fontSize: 13, color: AppColors.label2),
    );
  }
}

/// The severity breakdown as coloured counts: `2 Critical  1 High  1 Low`.
///
/// Only severities that occur are shown. Printing four zeroes would be noise,
/// and would make an inspection with one minor scratch look as alarming as one
/// with three critical defects.
class SeverityBreakdown extends StatelessWidget {
  const SeverityBreakdown({super.key, required this.stats});

  final InspectionStats stats;

  @override
  Widget build(BuildContext context) {
    final present = stats.severitiesWorstFirst;
    if (present.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: 14,
      runSpacing: 6,
      children: [
        for (final s in present)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: SeverityPalette.foreground(s),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '${stats.count(s)} ${s.label}',
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.label,
                ),
              ),
            ],
          ),
      ],
    );
  }
}

/// A thin resolved/total bar. Absent when there is nothing to measure.
class ProgressBar extends StatelessWidget {
  const ProgressBar({super.key, required this.stats});

  final InspectionStats stats;

  @override
  Widget build(BuildContext context) {
    final value = stats.progress;
    if (value == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              'Resolved',
              style: TextStyle(fontSize: 13, color: AppColors.label2),
            ),
            const Spacer(),
            Text(
              '${stats.resolved} of ${stats.total}',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.label,
              ),
            ),
          ],
        ),
        const SizedBox(height: 7),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: SizedBox(
            height: 5,
            child: Stack(
              children: [
                Container(color: AppColors.fill),
                FractionallySizedBox(
                  widthFactor: value.clamp(0.0, 1.0),
                  child: Container(
                    color: value >= 1 ? AppColors.green : AppColors.blue,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// An iOS segmented control, used for the list and punch-list filters.
///
/// Written here rather than using `CupertinoSegmentedControl` because the
/// prototype's is a flat, full-width, hairline-bordered row and the framework's
/// is a rounded pill with different metrics; matching the design is the whole
/// point of this file.
class SegmentedFilter<T> extends StatelessWidget {
  const SegmentedFilter({
    super.key,
    required this.segments,
    required this.value,
    required this.onChanged,
  });

  final List<(T, String)> segments;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      child: Row(
        children: [
          for (var i = 0; i < segments.length; i++)
            Expanded(
              child: _Segment(
                label: segments[i].$2,
                selected: segments[i].$1 == value,
                first: i == 0,
                last: i == segments.length - 1,
                onTap: () => onChanged(segments[i].$1),
              ),
            ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.selected,
    required this.first,
    required this.last,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool first;
  final bool last;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.horizontal(
      left: Radius.circular(first ? 8 : 0),
      right: Radius.circular(last ? 8 : 0),
    );
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        decoration: BoxDecoration(
          color: selected ? AppColors.blue : AppColors.card,
          borderRadius: radius,
          border: Border.all(color: AppColors.separator, width: 0.5),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: selected ? AppColors.card : AppColors.label,
          ),
        ),
      ),
    );
  }
}
