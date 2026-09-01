import 'package:flutter/cupertino.dart';

import '../data/repositories.dart';
import '../offline/offline_status.dart';
import '../report/report_service.dart';
import 'inspections_screen.dart';
import 'reports_screen.dart';
import 'settings_screen.dart';
import 'theme.dart';

/// The signed-in shell: Inspections, Reports, Settings.
///
/// The prototype has four tabs — Inspections, Search, Reports, Settings — and
/// this has three. Search is not a destination here because it is not a
/// separate capability: the history screen's field queries the same stored
/// `search_tsv` the prototype's Search tab would, and giving it a tab of its
/// own would mean either duplicating that screen or splitting one behaviour
/// across two. A tab that navigates to a search box the user already has is
/// furniture, and D22 made search part of history deliberately.
///
/// `CupertinoTabScaffold` keeps each tab's navigator alive, so returning to
/// Inspections restores its scroll position and loaded rows rather than
/// refetching — which also means the offline queue is not re-read on every tab
/// switch.
class HomeShell extends StatelessWidget {
  const HomeShell({
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
  final OfflineStatusNotifier? offline;
  final Future<void> Function()? onSync;

  @override
  Widget build(BuildContext context) {
    return CupertinoTabScaffold(
      tabBar: CupertinoTabBar(
        backgroundColor: AppColors.card,
        activeColor: AppColors.blue,
        inactiveColor: AppColors.label2,
        border: const Border(
          top: BorderSide(color: AppColors.separator, width: 0.5),
        ),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(CupertinoIcons.list_bullet_below_rectangle),
            label: 'Inspections',
          ),
          BottomNavigationBarItem(
            icon: Icon(CupertinoIcons.doc_text),
            label: 'Reports',
          ),
          BottomNavigationBarItem(
            icon: Icon(CupertinoIcons.gear),
            label: 'Settings',
          ),
        ],
      ),
      tabBuilder: (context, index) {
        return CupertinoTabView(
          builder: (context) => switch (index) {
            0 => InspectionsScreen(
                auth: auth,
                profiles: profiles,
                inspections: inspections,
                items: items,
                photos: photos,
                source: source,
                reports: reports,
                offline: offline,
                onSync: onSync,
              ),
            1 => ReportsScreen(
                inspections: inspections,
                reports: reports,
                offline: offline,
              ),
            _ => SettingsScreen(
                auth: auth,
                profiles: profiles,
                offline: offline,
                onSync: onSync,
              ),
          },
        );
      },
    );
  }
}
