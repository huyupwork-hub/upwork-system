import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../offline/offline_status.dart';
import 'theme.dart';

/// The whole of the offline UI.
///
/// One strip above the list, with at most a sentence and a retry. There is no
/// sync dashboard, no per-record progress, no activity feed and no conflict
/// centre, because there are no conflicts and the user's only available action
/// is "try again" — everything else would be decoration over a two-state
/// machine.
///
/// It says nothing at all when there is nothing to say: no pending work and a
/// reachable server renders zero height, so the ordinary online app looks
/// exactly as it did before this slice.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key, required this.status, this.onRetry});

  final OfflineStatusNotifier status;

  /// Null when no sync engine is wired — the widget tests that predate this
  /// slice construct the app without one.
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<OfflineStatus>(
      valueListenable: status,
      builder: (context, value, _) {
        if (!value.hasPending && !value.remoteUnavailable) {
          return const SizedBox.shrink();
        }
        return _Strip(status: value, onRetry: onRetry);
      },
    );
  }
}

class _Strip extends StatelessWidget {
  const _Strip({required this.status, this.onRetry});

  final OfflineStatus status;
  final Future<void> Function()? onRetry;

  /// Truthful about which of the three situations this is.
  ///
  /// "Syncing" is never shown for work that is merely queued, and "Synced" is
  /// never shown at all — a synced draft has left the queue and this strip has
  /// nothing to say about it. The only claim made here is one the app can
  /// support.
  String get _message {
    final n = status.pending;
    final s = n == 1 ? '' : 's';
    if (status.syncing) return 'Syncing $n draft$s…';
    if (status.remoteUnavailable && status.hasPending) {
      return 'Offline. $n draft$s saved on this device, and only those are '
          'shown. They sync when the connection returns.';
    }
    if (status.remoteUnavailable) {
      return 'Offline. Inspections already on the server are not available '
          'until the connection returns.';
    }
    return '$n draft$s not synced yet.';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('offline-banner'),
      margin: const EdgeInsets.fromLTRB(
        AppMetrics.gutter,
        8,
        AppMetrics.gutter,
        0,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.orangeTint,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (status.syncing) ...[
                const CupertinoActivityIndicator(radius: 7),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  _message,
                  key: const Key('offline-banner-message'),
                  style: const TextStyle(fontSize: 13, color: AppColors.label),
                ),
              ),
              if (onRetry != null && !status.syncing && status.hasPending)
                CupertinoButton(
                  key: const Key('offline-retry-button'),
                  padding: const EdgeInsets.only(left: 8),
                  minimumSize: Size.zero,
                  onPressed: () => unawaited(onRetry!()),
                  child: const Text(
                    'Retry',
                    style: TextStyle(fontSize: 13, color: AppColors.blue),
                  ),
                ),
            ],
          ),
          // The last failure verbatim. A user who can read the actual error can
          // tell "no route to host" from "your work was rejected"; one shown a
          // tidied "Sync failed" cannot.
          if (status.lastError != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                status.lastError!,
                key: const Key('offline-banner-error'),
                style: const TextStyle(fontSize: 12, color: AppColors.red),
              ),
            ),
        ],
      ),
    );
  }
}

/// The row and detail marker for a draft that exists only on this device.
///
/// Distinct from the Draft pill rather than replacing it: the inspection *is* a
/// draft, and it is also not on the server yet. Collapsing the two would lose
/// the distinction the moment it matters — after a sync, when one is still true
/// and the other is not.
class UnsyncedPill extends StatelessWidget {
  const UnsyncedPill({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('unsynced-pill'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.orangeTint,
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Text(
        'Not synced',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: AppColors.orange,
        ),
      ),
    );
  }
}
