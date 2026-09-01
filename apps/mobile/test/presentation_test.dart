import 'package:fieldproof/src/data/models.dart';
import 'package:fieldproof/src/ui/presentation.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

/// The presentation layer added by the Figma parity pass.
///
/// What is worth pinning here is not that a widget renders, but that the
/// derivations are honest: counts match the rows they came from, an
/// unmeasurable thing reports as unmeasurable rather than as zero, and the demo
/// content is genuinely deterministic — a portfolio screenshot that stops
/// matching the app a week later is worse than no screenshot.
void main() {
  InspectionItem item(
    String id, {
    ItemSeverity severity = ItemSeverity.medium,
    ItemStatus status = ItemStatus.open,
  }) =>
      InspectionItem(
        id: id,
        inspectionId: 'insp-1',
        sortOrder: 0,
        title: 'Finding $id',
        severity: severity,
        status: status,
      );

  group('InspectionStats', () {
    test('counts opens, resolved and severities from the rows given', () {
      final stats = InspectionStats.from([
        item('1', severity: ItemSeverity.critical),
        item('2', severity: ItemSeverity.high),
        item('3', severity: ItemSeverity.high, status: ItemStatus.resolved),
        item('4', severity: ItemSeverity.low, status: ItemStatus.resolved),
      ], photos: 3);

      expect(stats.total, 4);
      expect(stats.open, 2);
      expect(stats.resolved, 2);
      expect(stats.count(ItemSeverity.critical), 1);
      expect(stats.count(ItemSeverity.high), 2);
      expect(stats.count(ItemSeverity.low), 1);
      expect(stats.count(ItemSeverity.medium), 0);
      expect(stats.photos, 3);
    });

    test('progress is null with no findings, not zero', () {
      // An inspection with nothing recorded is not 0% resolved — it is not
      // measurable. Drawing an empty bar for it would state something false.
      expect(InspectionStats.from(const []).progress, isNull);
      expect(InspectionStats.from([item('1')]).progress, 0.0);
      expect(
        InspectionStats.from([item('1', status: ItemStatus.resolved)]).progress,
        1.0,
      );
    });

    test('severities come back worst first, and only the ones present', () {
      final stats = InspectionStats.from([
        item('1', severity: ItemSeverity.low),
        item('2', severity: ItemSeverity.critical),
      ]);
      expect(stats.severitiesWorstFirst, [
        ItemSeverity.critical,
        ItemSeverity.low,
      ]);
    });
  });

  group('InspectionPhase', () {
    Inspection made(InspectionStatus status) => Inspection(
          id: 'i',
          inspectorId: 'u',
          siteName: 'Site',
          inspectionDate: DateTime(2026, 8, 20),
          status: status,
        );

    test('keeps the schema vocabulary rather than the prototype figures', () {
      // The Figma prototype says "Complete". The database, the submit dialog,
      // the immutability notice and the admin console all say "Submitted", and
      // D14 settled that the schema wins. One screen using the other word is
      // how a product ends up with two vocabularies.
      expect(InspectionPhase.of(made(InspectionStatus.submitted)).label,
          'Submitted');
      expect(InspectionPhase.of(made(InspectionStatus.draft)).label, 'Draft');
    });
  });

  group('widgets', () {
    Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
          CupertinoApp(
              home: CupertinoPageScaffold(child: Center(child: child))),
        );

    testWidgets('a dependency note states the requirement, not an error',
        (tester) async {
      await pump(
        tester,
        const DependencyNote(
          title: 'Send to client',
          requirement: 'Requires an email delivery provider',
        ),
      );

      expect(find.byKey(const Key('dependency-note')), findsOneWidget);
      expect(find.text('Send to client'), findsOneWidget);
      expect(find.text('Requires an email delivery provider'), findsOneWidget);
      // It must not read as a failure. No red, no "error", no stack trace.
      expect(find.textContaining('Error'), findsNothing);
      expect(find.textContaining('failed'), findsNothing);
    });

    testWidgets('the stats line says "No findings" rather than "0 open"',
        (tester) async {
      await pump(tester, StatsLine(stats: InspectionStats.from(const [])));
      expect(find.text('No findings'), findsOneWidget);
    });

    testWidgets('the severity breakdown names each level beside its colour',
        (tester) async {
      await pump(
        tester,
        SeverityBreakdown(
          stats: InspectionStats.from([
            item('1', severity: ItemSeverity.critical),
            item('2', severity: ItemSeverity.critical),
            item('3', severity: ItemSeverity.low),
          ]),
        ),
      );

      // Words, not colour alone — the whole point of spelling the level out.
      expect(find.text('2 Critical'), findsOneWidget);
      expect(find.text('1 Low'), findsOneWidget);
      expect(find.textContaining('High'), findsNothing);
    });

    testWidgets('the progress bar is absent when there is nothing to measure',
        (tester) async {
      await pump(tester, ProgressBar(stats: InspectionStats.from(const [])));
      expect(find.textContaining('of'), findsNothing);

      await pump(
        tester,
        ProgressBar(
          stats: InspectionStats.from([
            item('1', status: ItemStatus.resolved),
            item('2'),
          ]),
        ),
      );
      expect(find.text('1 of 2'), findsOneWidget);
    });

    testWidgets('the segmented filter reports the segment that was tapped',
        (tester) async {
      var picked = 'all';
      await pump(
        tester,
        StatefulBuilder(
          builder: (context, setState) => SegmentedFilter<String>(
            value: picked,
            onChanged: (v) => setState(() => picked = v),
            segments: const [('all', 'All'), ('open', 'Open')],
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(picked, 'open');
    });
  });
}
