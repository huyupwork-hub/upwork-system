/// What the app knows about connectivity and pending work, and how it decides.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The four states the offline UI is allowed to be in.
///
/// Deliberately this small. There is no job list, no per-record progress and no
/// activity feed: the user needs to know that work is held locally, that it is
/// being pushed, that a push failed and why, and how to try again.
@immutable
class OfflineStatus {
  const OfflineStatus({
    this.remoteUnavailable = false,
    this.syncing = false,
    this.pendingIds = const {},
    this.lastError,
  });

  /// The last operation that tried to reach Supabase could not.
  ///
  /// Derived from a failed request, never from a network interface's opinion: a
  /// device can hold a full-strength connection to a captive portal. Cleared by
  /// the next request that succeeds.
  final bool remoteUnavailable;

  /// A push is in flight.
  final bool syncing;

  /// Ids of the drafts held only on this device.
  ///
  /// Ids rather than a count because the history list has to mark exactly those
  /// rows, and the detail screen has to know whether the record it is showing
  /// can be submitted yet.
  final Set<String> pendingIds;

  /// The last sync failure, verbatim. Truthfulness matters more than tidiness
  /// here — a user who can read "connection closed" retries; one shown "Sync
  /// failed" cannot tell that from "your work was rejected".
  final String? lastError;

  int get pending => pendingIds.length;

  bool get hasPending => pendingIds.isNotEmpty;

  OfflineStatus copyWith({
    bool? remoteUnavailable,
    bool? syncing,
    Set<String>? pendingIds,
    String? Function()? lastError,
  }) =>
      OfflineStatus(
        remoteUnavailable: remoteUnavailable ?? this.remoteUnavailable,
        syncing: syncing ?? this.syncing,
        pendingIds: pendingIds ?? this.pendingIds,
        lastError: lastError == null ? this.lastError : lastError(),
      );
}

/// One notifier, listened to by the two screens that show offline state.
///
/// A `ValueNotifier` rather than a state-management package: there is a single
/// value, three writers and two readers. Anything larger would be architecture
/// for its own sake.
class OfflineStatusNotifier extends ValueNotifier<OfflineStatus> {
  OfflineStatusNotifier() : super(const OfflineStatus());

  void setRemoteUnavailable(bool unavailable) {
    if (value.remoteUnavailable == unavailable) return;
    value = value.copyWith(remoteUnavailable: unavailable);
  }

  void setSyncing(bool syncing) {
    if (value.syncing == syncing) return;
    value = value.copyWith(syncing: syncing);
  }

  void setPendingIds(Set<String> ids) {
    if (setEquals(value.pendingIds, ids)) return;
    value = value.copyWith(pendingIds: ids);
  }

  void setLastError(String? error) {
    if (value.lastError == error) return;
    value = value.copyWith(lastError: () => error);
  }
}

/// Whether a failure means "the server was not reachable" or "the server
/// answered, and the answer was no".
///
/// This distinction is the whole safety of the offline path. Treating every
/// failure as offline would stash drafts that the database has already refused —
/// a constraint violation, or an RLS denial — and they would sit in the queue
/// failing forever while the app told the user they were merely waiting for
/// signal. So the rule is inverted from the convenient one: a response from
/// PostgREST, GoTrue or Storage is **never** offline, whatever it says.
bool isTransportFailure(Object error) {
  // GoTrue raises this specifically for a request it could not complete. Tested
  // before AuthApiException because both descend from AuthException and only
  // this one means the request never landed.
  if (error is AuthRetryableFetchException) return true;

  // The server spoke. Whatever it said, connectivity is not the problem.
  if (error is PostgrestException) return false;
  if (error is StorageException) return false;
  if (error is AuthException) return false;

  if (error is SocketException) return true;
  if (error is HttpException) return true;
  if (error is HandshakeException) return true;
  if (error is TimeoutException) return true;

  // package:http's transport failure, matched by type name so this file does
  // not take a direct dependency on http just to name one class.
  return error.runtimeType.toString() == 'ClientException';
}
