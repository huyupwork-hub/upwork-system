import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../data/models.dart';
import '../data/repositories.dart';
import '../offline/offline_status.dart';
import 'presentation.dart';
import 'theme.dart';

/// Identity, sync state, and an honest list of what is not wired up.
///
/// Deliberately small. The prototype has a Settings tab and a portfolio needs
/// somewhere to show who is signed in and what the offline queue is holding —
/// but a settings *product* (notifications, units, themes, team management) is
/// not in scope and inventing one would be exactly the kind of hollow surface
/// this pass is meant to avoid. Everything here either reflects real state or
/// says plainly that it does not exist yet.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.auth,
    required this.profiles,
    this.offline,
    this.onSync,
  });

  final AuthRepository auth;
  final ProfileRepository profiles;
  final OfflineStatusNotifier? offline;
  final Future<void> Function()? onSync;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Profile? _profile;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final profile = await widget.profiles.loadCurrent();
      if (mounted) setState(() => _profile = profile);
    } catch (_) {
      // The same rule the history screen follows: not knowing the name is not
      // worth an error screen. The rows below simply read "Unavailable".
    }
  }

  Future<void> _syncNow() async {
    final run = widget.onSync;
    if (run == null || _syncing) return;
    setState(() => _syncing = true);
    try {
      await run();
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;

    return CupertinoPageScaffold(
      backgroundColor: AppColors.background,
      child: CustomScrollView(
        slivers: [
          const CupertinoSliverNavigationBar(
            largeTitle: Text('Settings'),
            backgroundColor: AppColors.card,
            border: Border(
              bottom: BorderSide(color: AppColors.separator, width: 0.5),
            ),
          ),
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SectionHeader(label: 'Account'),
                InsetCard(
                  children: [
                    ReadOnlyRow(
                      label: 'Name',
                      value: profile?.fullName ?? 'Unavailable',
                    ),
                    ReadOnlyRow(
                      label: 'Role',
                      value: profile == null
                          ? 'Unavailable'
                          : (profile.isAdmin ? 'Reviewer' : 'Inspector'),
                    ),
                  ],
                ),
                _syncSection(),
                const SectionHeader(label: 'Not yet available'),
                const Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: AppMetrics.gutter,
                  ),
                  child: Column(
                    children: [
                      // Each of these is implied by the design and genuinely
                      // absent. Naming the missing provider is more useful to a
                      // reviewer than a disabled toggle that explains nothing.
                      DependencyNote(
                        title: 'Assign findings to a contractor',
                        requirement: 'Requires a work-order integration',
                      ),
                      SizedBox(height: 8),
                      DependencyNote(
                        title: 'Map preview for a site address',
                        requirement: 'Requires a geocoding provider',
                      ),
                      SizedBox(height: 8),
                      DependencyNote(
                        title: 'Push notifications for review outcomes',
                        requirement: 'Requires a push messaging provider',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 26),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppMetrics.gutter,
                  ),
                  child: CupertinoButton(
                    key: const Key('settings-sign-out'),
                    color: AppColors.card,
                    borderRadius:
                        BorderRadius.circular(AppMetrics.buttonRadius),
                    onPressed: widget.auth.signOut,
                    child: const Text(
                      'Sign Out',
                      style: TextStyle(
                        fontSize: 17,
                        color: AppColors.red,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Real offline state, read from the same notifier the banner uses, so the
  /// two can never disagree.
  Widget _syncSection() {
    final offline = widget.offline;
    if (offline == null) return const SizedBox.shrink();

    return ValueListenableBuilder<OfflineStatus>(
      valueListenable: offline,
      builder: (context, status, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SectionHeader(label: 'Sync'),
            InsetCard(
              children: [
                ReadOnlyRow(
                  label: 'Server',
                  value: status.remoteUnavailable ? 'Unreachable' : 'Reachable',
                  valueKey: const Key('settings-server-state'),
                ),
                ReadOnlyRow(
                  label: 'Pending',
                  value: status.pending == 0
                      ? 'Nothing waiting'
                      : '${status.pending} draft'
                          '${status.pending == 1 ? '' : 's'} on this device',
                  valueKey: const Key('settings-pending'),
                ),
                if (status.lastError != null)
                  ReadOnlyRow(
                    label: 'Last error',
                    value: status.lastError!,
                  ),
              ],
            ),
            if (widget.onSync != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppMetrics.gutter,
                  10,
                  AppMetrics.gutter,
                  0,
                ),
                child: CupertinoButton(
                  key: const Key('settings-sync-now'),
                  color: AppColors.card,
                  borderRadius: BorderRadius.circular(AppMetrics.buttonRadius),
                  onPressed: _syncing || !status.hasPending ? null : _syncNow,
                  child: _syncing
                      ? const CupertinoActivityIndicator()
                      : Text(
                          status.hasPending ? 'Sync Now' : 'Nothing to Sync',
                          style: TextStyle(
                            fontSize: 17,
                            color: status.hasPending
                                ? AppColors.blue
                                : AppColors.label3,
                          ),
                        ),
                ),
              ),
          ],
        );
      },
    );
  }
}
