import 'package:flutter/cupertino.dart';

import '../data/repositories.dart';
import '../offline/offline_status.dart';
import '../report/report_service.dart';
import 'home_shell.dart';
import 'sign_in_screen.dart';
import 'theme.dart';

/// Repositories are injected so widget tests can drive the whole app without a
/// network. There is one production wiring, in main.dart.
class FieldProofApp extends StatelessWidget {
  const FieldProofApp({
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

  /// The offline queue's observable state, and the push it triggers. Both null
  /// in a build with no local persistence wired; there is one production
  /// wiring, in main.dart.
  final OfflineStatusNotifier? offline;
  final Future<void> Function()? onSync;

  @override
  Widget build(BuildContext context) {
    return CupertinoApp(
      title: 'FieldProof',
      theme: appTheme,
      debugShowCheckedModeBanner: false,
      home: AuthGate(
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
    );
  }
}

/// Session state is the single source of routing truth. There is no local "is
/// logged in" flag to fall out of step with the client, and signing out cannot
/// leave a protected screen mounted.
class AuthGate extends StatelessWidget {
  const AuthGate({
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

  /// The offline queue's observable state, and the push it triggers. Both null
  /// in a build with no local persistence wired; there is one production
  /// wiring, in main.dart.
  final OfflineStatusNotifier? offline;
  final Future<void> Function()? onSync;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<String?>(
      stream: auth.userIdChanges,
      initialData: auth.currentUserId,
      builder: (context, snapshot) {
        final userId = snapshot.data;
        if (userId == null) return SignInScreen(auth: auth);
        return HomeShell(
          // Keyed by user so switching accounts rebuilds rather than reusing
          // another inspector's loaded state.
          key: ValueKey(userId),
          auth: auth,
          profiles: profiles,
          inspections: inspections,
          items: items,
          photos: photos,
          source: source,
          reports: reports,
          offline: offline,
          onSync: onSync,
        );
      },
    );
  }
}
