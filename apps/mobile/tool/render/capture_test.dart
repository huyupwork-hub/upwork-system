import 'dart:async';
import 'dart:io';

import 'package:fieldproof/src/data/models.dart';
import 'package:fieldproof/src/data/photo_workflow.dart';
import 'package:fieldproof/src/offline/offline_status.dart';
import 'package:fieldproof/src/report/report_loader.dart';
import 'package:fieldproof/src/report/report_service.dart';
import 'package:fieldproof/src/ui/home_shell.dart';
import 'package:fieldproof/src/ui/inspection_detail_screen.dart';
import 'package:fieldproof/src/ui/inspections_screen.dart';
import 'package:fieldproof/src/ui/item_editor_sheet.dart';
import 'package:fieldproof/src/ui/reports_screen.dart';
import 'package:fieldproof/src/ui/settings_screen.dart';
import 'package:fieldproof/src/ui/theme.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../test/fakes.dart';

/// The family the harness registers the SDK's Roboto under.
const String _renderFont = 'RenderHarnessText';

/// Renders every screen this pass touched to a PNG, so the work can be looked
/// at rather than only asserted about.
///
/// This is not a gate and it is not run by CI. `flutter test` with no path runs
/// `test/` only, and this file lives under `tool/` deliberately: a golden that
/// fails a build on an antialiasing difference teaches a team to delete
/// goldens. Run it on purpose:
///
///     flutter test --update-goldens tool/render/capture_test.dart
///
/// and the PNGs land in `tool/render/goldens/`.
///
/// Why it exists: this machine has no Flutter toolchain (D1) and no attached
/// handset, and a parity pass judged only by green tests is a parity pass
/// nobody looked at. These are the real widget trees, at a real handset size,
/// with a real font — the same pipeline that paints the device, minus the
/// device. It does not replace on-device QA (touch targets, keyboard insets,
/// scroll physics, platform fonts) and is not offered as a substitute.
///
/// Every value below is fixture data for a screenshot. None of it is written
/// anywhere: the repositories are the in-memory fakes the test suite uses.
void main() {
  // A 6.1" handset in logical pixels. Deliberately not oversized — the point is
  // to see what a real screen cuts off, so an overflow shows up as Flutter's
  // yellow-and-black stripe instead of being papered over by a tall viewport.
  const size = Size(390, 844);
  const dpr = 2.0;

  setUpAll(_loadRealFonts);

  late FakeAuthRepository auth;
  late FakeProfileRepository profiles;
  late FakeInspectionsRepository inspections;
  late FakeInspectionItemsRepository items;
  late FakePhotoMetadataStore photoMeta;
  late PhotoWorkflow photos;
  late FakePhotoSource source;
  late ReportService reports;

  final unsynced = Inspection(
    id: 'insp-4',
    inspectorId: 'user-1',
    siteName: 'Northgate Logistics Park',
    siteAddress: 'Unit 7, Northgate Way',
    clientName: 'Bramwell Estates',
    inspectionDate: DateTime(2026, 8, 30),
    status: InspectionStatus.draft,
  );
  final rows = [
    Inspection(
      id: 'insp-1',
      inspectorId: 'user-1',
      siteName: 'Harbour View Apartments',
      siteAddress: '12 Dock Road, Block C',
      clientName: 'Meridian Property Group',
      inspectionDate: DateTime(2026, 8, 20),
      status: InspectionStatus.draft,
    ),
    Inspection(
      id: 'insp-2',
      inspectorId: 'user-1',
      siteName: 'Ravenscourt Primary School',
      siteAddress: '4 Ravenscourt Lane',
      clientName: 'Ashfield Borough Council',
      inspectionDate: DateTime(2026, 8, 18),
      status: InspectionStatus.submitted,
    ),
    Inspection(
      id: 'insp-3',
      inspectorId: 'user-1',
      siteName: 'Calder Street Warehouse',
      siteAddress: '88 Calder Street',
      clientName: 'Pennine Industrial',
      inspectionDate: DateTime(2026, 8, 12),
      status: InspectionStatus.submitted,
    ),
    unsynced,
  ];

  InspectionItem itemOf(
    String id,
    int order,
    String title,
    String area,
    ItemSeverity severity, {
    ItemStatus status = ItemStatus.open,
    String? description,
  }) =>
      InspectionItem(
        id: id,
        inspectionId: 'insp-1',
        sortOrder: order,
        title: title,
        area: area,
        description: description,
        severity: severity,
        status: status,
      );

  final punchList = [
    itemOf(
      'item-1',
      0,
      'Fire door does not latch',
      'Stair core, level 3',
      ItemSeverity.critical,
      description:
          'Closer is over-adjusted and the latch bolt does not engage the '
          'keep. Door stands off by roughly 8mm when released.',
    ),
    itemOf(
      'item-2',
      1,
      'Balcony balustrade loose at fixing',
      'Flat 3B balcony',
      ItemSeverity.high,
      description: 'Two of four base fixings turn by hand.',
    ),
    itemOf(
      'item-3',
      2,
      'Extract fan not running on humidistat',
      'Flat 2A bathroom',
      ItemSeverity.medium,
      description: 'Runs on the light switch only.',
    ),
    itemOf(
      'item-4',
      3,
      'Skirting scuffed along corridor',
      'Level 1 corridor',
      ItemSeverity.low,
      status: ItemStatus.resolved,
      description: 'Made good and repainted 28 Aug.',
    ),
    itemOf(
      'item-5',
      4,
      'Handrail bracket missing',
      'Stair core, level 1',
      ItemSeverity.high,
      status: ItemStatus.resolved,
    ),
  ];

  setUp(() {
    auth = FakeAuthRepository();
    profiles = FakeProfileRepository(
      profile: const Profile(
        id: 'user-1',
        fullName: 'Dana Whitlock',
        role: 'inspector',
      ),
    );
    inspections = FakeInspectionsRepository(initial: [...rows]);
    items = FakeInspectionItemsRepository(initial: [...punchList]);
    photoMeta = FakePhotoMetadataStore();
    photos = PhotoWorkflow(
      objects: FakeObjectStore(),
      metadata: photoMeta,
      currentUserId: () => 'user-1',
    );
    // Photo counts are read per item by the detail screen; these give the
    // camera badges something true to count.
    photoMeta.rows.addAll([
      for (final id in ['item-1', 'item-1', 'item-1', 'item-2'])
        ItemPhoto(
          id: 'photo-${photoMeta.rows.length}-$id',
          itemId: id,
          inspectionId: 'insp-1',
          storagePath: 'user-1/insp-1/$id.jpg',
          contentType: 'image/jpeg',
          byteSize: 812345,
        ),
    ]);
    source = FakePhotoSource();
    reports = ReportService(
      loader: ReportLoader(items: items, photos: photos, profiles: profiles),
      renderer: FakeReportRenderer(),
      sharer: FakeReportSharer(),
      store: FakeReportStore(),
      currentUserId: () => 'user-1',
    );
  });

  tearDown(() => auth.dispose());

  Future<void> shoot(
    WidgetTester tester,
    Widget screen,
    String name, {
    bool settle = true,
  }) async {
    tester.view.physicalSize = size * dpr;
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      CupertinoApp(
        debugShowCheckedModeBanner: false,
        // The app's own theme, with the text family pinned to the face
        // registered above. Every style in this app is declared with
        // inherit: true, so naming the family once here reaches all of them
        // without restating a single size or weight.
        theme: appTheme.copyWith(
          textTheme: const CupertinoTextThemeData(
            textStyle: TextStyle(
              fontFamily: _renderFont,
              fontSize: 17,
              color: AppColors.label,
              decoration: TextDecoration.none,
            ),
          ),
        ),
        home: screen,
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      // A CupertinoActivityIndicator animates forever, so pumpAndSettle would
      // time out. Pump the pending futures, then advance a fixed distance into
      // the animation so the frame is reproducible.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
    }
    await expectLater(
      find.byType(CupertinoApp),
      matchesGoldenFile('goldens/$name.png'),
    );
  }

  OfflineStatusNotifier notifierWith(OfflineStatus status) =>
      OfflineStatusNotifier()..value = status;

  Widget home({OfflineStatusNotifier? offline}) => InspectionsScreen(
        profiles: profiles,
        inspections: inspections,
        items: items,
        photos: photos,
        source: source,
        reports: reports,
        offline: offline,
        onSync: offline == null ? null : () async {},
      );

  testWidgets('01 inspections populated', (tester) async {
    await shoot(tester, home(), '01-inspections-populated');
  });

  testWidgets('02 inspections empty', (tester) async {
    inspections.rows.clear();
    await shoot(tester, home(), '02-inspections-empty');
  });

  testWidgets('03 inspections offline with a pending draft', (tester) async {
    // Offline, the list holds what this device holds. Leaving the server rows
    // in would put four inspections under a banner saying one — a screenshot
    // that argues with itself.
    inspections.rows
      ..clear()
      ..add(unsynced);
    await shoot(
      tester,
      home(
        offline: notifierWith(
          const OfflineStatus(
            remoteUnavailable: true,
            pendingIds: {'insp-4'},
          ),
        ),
      ),
      '03-inspections-offline-pending',
    );
  });

  testWidgets('04 inspections syncing', (tester) async {
    await shoot(
      tester,
      home(
        offline: notifierWith(
          const OfflineStatus(syncing: true, pendingIds: {'insp-4'}),
        ),
      ),
      '04-inspections-syncing',
      settle: false,
    );
  });

  testWidgets('05 inspections error', (tester) async {
    inspections.readFailsWith =
        Exception('Failed host lookup: fieldproof.supabase.co');
    await shoot(tester, home(), '05-inspections-error');
  });

  testWidgets('15 inspections loading', (tester) async {
    await shoot(
      tester,
      InspectionsScreen(
        profiles: profiles,
        inspections: _NeverAnswers(),
        items: items,
        photos: photos,
        source: source,
        reports: reports,
      ),
      '15-inspections-loading',
      settle: false,
    );
  });

  testWidgets('16 search with no matches', (tester) async {
    tester.view.physicalSize = size * dpr;
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      CupertinoApp(
        debugShowCheckedModeBanner: false,
        theme: appTheme.copyWith(
          textTheme: const CupertinoTextThemeData(
            textStyle: TextStyle(
              fontFamily: _renderFont,
              fontSize: 17,
              color: AppColors.label,
              decoration: TextDecoration.none,
            ),
          ),
        ),
        home: home(),
      ),
    );
    await tester.pumpAndSettle();
    // Typed, not injected: the empty-result copy has to quote the query the
    // user actually entered, and the only way to prove that is to enter one.
    await tester.enterText(
      find.byKey(const Key('inspections-search')),
      'quarry lane',
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(CupertinoApp),
      matchesGoldenFile('goldens/16-search-no-matches.png'),
    );
  });

  testWidgets('17 search with matches', (tester) async {
    tester.view.physicalSize = size * dpr;
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      CupertinoApp(
        debugShowCheckedModeBanner: false,
        theme: appTheme.copyWith(
          textTheme: const CupertinoTextThemeData(
            textStyle: TextStyle(
              fontFamily: _renderFont,
              fontSize: 17,
              color: AppColors.label,
              decoration: TextDecoration.none,
            ),
          ),
        ),
        home: home(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('inspections-search')),
      'ravenscourt',
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(CupertinoApp),
      matchesGoldenFile('goldens/17-search-results.png'),
    );
  });

  testWidgets('07 inspection detail hero', (tester) async {
    await shoot(
      tester,
      InspectionDetailScreen(
        inspection: rows.first,
        inspections: inspections,
        items: items,
        photos: photos,
        source: source,
        reports: reports,
      ),
      '07-detail-hero',
    );
  });

  testWidgets('08 inspection detail with no findings', (tester) async {
    items.rows.clear();
    await shoot(
      tester,
      InspectionDetailScreen(
        inspection: rows.first,
        inspections: inspections,
        items: items,
        photos: photos,
        source: source,
        reports: reports,
      ),
      '08-detail-no-findings',
    );
  });

  testWidgets('09 inspection detail submitted', (tester) async {
    await shoot(
      tester,
      InspectionDetailScreen(
        inspection: rows[1],
        inspections: inspections,
        items: items,
        photos: photos,
        source: source,
        reports: reports,
      ),
      '09-detail-submitted',
    );
  });

  testWidgets('10 finding editor, new', (tester) async {
    await shoot(
      tester,
      CupertinoPageScaffold(
        backgroundColor: AppColors.label3,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: ItemEditorSheet(
            items: items,
            photos: photos,
            source: source,
            inspectionId: 'insp-1',
          ),
        ),
      ),
      '10-editor-new',
    );
  });

  testWidgets('11 finding editor, existing', (tester) async {
    await shoot(
      tester,
      CupertinoPageScaffold(
        backgroundColor: AppColors.label3,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: ItemEditorSheet(
            items: items,
            photos: photos,
            source: source,
            inspectionId: 'insp-1',
            existing: punchList.first,
          ),
        ),
      ),
      '11-editor-existing',
    );
  });

  testWidgets('12 reports', (tester) async {
    await shoot(
      tester,
      ReportsScreen(inspections: inspections, reports: reports),
      '12-reports',
    );
  });

  testWidgets('13 settings', (tester) async {
    await shoot(
      tester,
      SettingsScreen(
        auth: auth,
        profiles: profiles,
        offline: notifierWith(
          const OfflineStatus(remoteUnavailable: true, pendingIds: {'insp-4'}),
        ),
        onSync: () async {},
      ),
      '13-settings',
    );
  });

  testWidgets('14 tab shell', (tester) async {
    await shoot(
      tester,
      HomeShell(
        auth: auth,
        profiles: profiles,
        inspections: inspections,
        items: items,
        photos: photos,
        source: source,
        reports: reports,
        offline: notifierWith(const OfflineStatus(pendingIds: {'insp-4'})),
        onSync: () async {},
      ),
      '14-tab-shell',
    );
  });
}

/// A repository whose read never answers, so the loading state can be held
/// still long enough to photograph.
///
/// The ordinary fake resolves on the next microtask, which is correct for tests
/// and useless for a screenshot: the spinner is gone before the frame is taken.
class _NeverAnswers extends FakeInspectionsRepository {
  @override
  Future<List<Inspection>> listMine() => Completer<List<Inspection>>().future;

  @override
  Future<List<Inspection>> searchMine(String query) =>
      Completer<List<Inspection>>().future;
}

/// Registers a real typeface under the families Cupertino asks for.
///
/// `flutter test` ships one font — Ahem, which draws every glyph as a filled
/// box. That is the right default for layout assertions and useless for looking
/// at a screen, so the SDK's bundled Roboto is registered under the system
/// family names the Cupertino text theme resolves to.
/// Registers the Cupertino glyph font from the pub cache.
///
/// `flutter_test` loads no package fonts, so without this every CupertinoIcon
/// paints as an empty square and a screenshot cannot show whether the right
/// glyph was chosen. Located by walking up from the package's own resolved
/// config rather than hard-coding a version.
Future<void> _loadCupertinoIcons() async {
  final config = File('.dart_tool/package_config.json');
  if (!config.existsSync()) return;
  final text = config.readAsStringSync();
  // dotAll, because package_config.json is pretty-printed and the two keys
  // sit on different lines.
  final match = RegExp(
    r'"name"\s*:\s*"cupertino_icons".*?"rootUri"\s*:\s*"([^"]+)"',
    dotAll: true,
  ).firstMatch(text);
  if (match == null) return;
  var root = match.group(1)!;
  if (root.startsWith('file://')) root = root.substring('file://'.length);
  final font = File('$root/assets/CupertinoIcons.ttf');
  if (!font.existsSync()) {
    // ignore: avoid_print
    print('NOTE: no CupertinoIcons.ttf at $font — icons will be empty boxes.');
    return;
  }
  // CupertinoIcons declares a fontPackage, so Flutter resolves the family as
  // 'packages/<package>/<family>'. Registering the bare name alone leaves every
  // glyph as a notdef box.
  final bytes = font.readAsBytesSync().buffer.asByteData();
  for (final family in const [
    'packages/cupertino_icons/CupertinoIcons',
    'CupertinoIcons',
  ]) {
    final loader = FontLoader(family)..addFont(Future.value(bytes));
    await loader.load();
  }
  // ignore: avoid_print
  print('render harness: icons from $font');
}

Future<void> _loadRealFonts() async {
  // A widget test runs inside flutter_tester, which lives under
  // <sdk>/bin/cache/artifacts/engine/<platform>/ — not under bin/cache/dart-sdk
  // like the Dart VM does. Cut at bin/cache and both layouts resolve.
  final exe = Platform.resolvedExecutable;
  const marker = '/bin/cache/';
  final cut = exe.indexOf(marker);
  if (cut < 0) {
    // ignore: avoid_print
    print('NOTE: could not locate the Flutter SDK from $exe — text will '
        'render as Ahem boxes.');
    return;
  }
  final fonts = '${exe.substring(0, cut)}/bin/cache/artifacts/material_fonts';
  final regular = File('$fonts/Roboto-Regular.ttf');
  await _loadCupertinoIcons();
  final medium = File('$fonts/Roboto-Medium.ttf');
  if (!regular.existsSync()) {
    // ignore: avoid_print
    print('NOTE: no Roboto at $fonts — text will render as Ahem boxes.');
    return;
  }

  // ignore: avoid_print
  print('render harness: loading fonts from $fonts');
  final bytes = regular.readAsBytesSync().buffer.asByteData();
  final boldBytes = (medium.existsSync() ? medium : regular)
      .readAsBytesSync()
      .buffer
      .asByteData();

  for (final family in const [
    _renderFont,
    'Roboto',
    '.SF Pro Text',
    '.SF Pro Display',
    'CupertinoSystemText',
    'CupertinoSystemDisplay',
  ]) {
    final loader = FontLoader(family)
      ..addFont(Future.value(bytes))
      ..addFont(Future.value(boldBytes));
    await loader.load();
  }
}
