/// Headless backfill of stored reports — DEPLOY §7's fallback when no phone is
/// at hand.
///
/// Signs in as ONE inspector with the anon key and an ordinary password, reads
/// that inspector's own submitted inspections through `listMine()`, and hands
/// them to `ReportService.publishMissing` — the same objects, the same call and
/// the same session the Reports tab's "Upload N missing reports" tap uses
/// (D31). The INSERT policy pins `{uid}/{id}/report.pdf` and admits it only
/// while the inspection is `submitted`; nothing here holds a key that could do
/// anything else. The three demo inspections are the reason the file exists
/// (spec §5): they were submitted before the bucket, and the policy keys on
/// status rather than on the moment of transition, so they are exactly as
/// eligible as one submitted today.
///
/// Deliberately under `tool/`, not `test/` or `test_hosted/` (the `tool/render`
/// precedent, D30): `flutter test` with no path runs `test/` only and the
/// hosted smoke job runs `test_hosted/` only, so neither CI job ever runs this.
/// It is written as a test rather than a script so it keeps the smoke test's
/// discipline for free — a failing `expect` is a non-zero exit, `tearDownAll`
/// signs out whatever happened, and the runner attributes every printed line
/// to the case. Run it on purpose, on the T410s (the dev Mac has no Flutter,
/// D1):
///
///     flutter test tool/backfill/ --reporter expanded
///
/// Required environment variables. Environment, never --dart-define: defines
/// land in the process command line and in step echoes, environment variables
/// do not. Nothing here is committed and no credential is printed.
///   SUPABASE_URL                   https://<ref>.supabase.co
///   SUPABASE_ANON_KEY              the anon / publishable key — never the
///                                  service role
///   BACKFILL_INSPECTOR_EMAIL       the inspector whose submitted inspections
///                                  need reports
///   BACKFILL_INSPECTOR_PASSWORD
///
/// What it prints: one line per submitted inspection — id, the pinned path,
/// what the bucket holds there afterwards, and what this run did about it —
/// then a summary. What it asserts: every submitted inspection of that
/// inspector holds a stored report afterwards, read back from the bucket
/// through the app's own `published()` rather than from what the loop believed
/// it did (D27: upload state comes from the bucket, never from a local flag).
/// The exit code therefore says whether the backfill is complete, and nothing
/// more: contents are not verified (the record is authoritative, D21 amended),
/// DEPLOY §7's `storage.objects` query is the server-side read-back and the
/// console is the reviewer-side one.
///
/// Running it twice uploads nothing the second time: `publishMissing` reads the
/// bucket first, and `SupabaseReportStore.put` treats Duplicate as done (hosted
/// smoke 22e).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fieldproof/src/data/models.dart';
import 'package:fieldproof/src/data/photo_workflow.dart';
import 'package:fieldproof/src/data/supabase_repositories.dart';
import 'package:fieldproof/src/report/report_loader.dart';
import 'package:fieldproof/src/report/report_renderer.dart';
import 'package:fieldproof/src/report/report_service.dart';
import 'package:fieldproof/src/report/report_sharer.dart';
import 'package:fieldproof/src/report/report_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// _env and _assertNotPrivileged are the hosted smoke test's, copied rather than
// shared: they are private to that file, and the only home a shared copy could
// have is lib/, which must not depend on flutter_test's fail(). The two files
// must keep saying the same thing about what a key may be.

String _env(String name) {
  final value = Platform.environment[name] ?? '';
  if (value.isEmpty) {
    fail(
      '$name is not set. This backfill needs the hosted project and the '
      'inspector whose reports are missing; see the header of this file and '
      'docs/DEPLOY.md §7.',
    );
  }
  return value;
}

/// Refuses to run under a privileged key.
///
/// The backfill is the ordinary product path precisely so that no privileged
/// write is ever needed (spec §5). A privileged key would bypass the policies
/// this run is supposed to be subject to — an object could land at a name or
/// under a status the phone could never produce.
///
/// It decodes the JWT and inspects the `role` claim rather than substring-matching
/// the key, which is both a real check and avoids planting a string that the
/// repository's own secret-hygiene gate scans for.
void _assertNotPrivileged(String key) {
  final parts = key.split('.');
  if (parts.length == 3) {
    try {
      final payload = json.decode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      ) as Map<String, dynamic>;
      final role = payload['role'];
      if (role != 'anon') {
        fail('SUPABASE_ANON_KEY carries role "$role"; expected "anon".');
      }
    } on FormatException {
      // Not a JWT after all; fall through to the prefix check below.
    }
  }
  // Newer Supabase keys are not JWTs: publishable keys start sb_publishable_,
  // secret keys start sb_secret_.
  if (key.startsWith('sb_secret_')) {
    fail('SUPABASE_ANON_KEY is a secret key; this backfill must use a public '
        'one.');
  }
}

void main() {
  // Nullable rather than `late`: setUpAll fails before the client exists when
  // a variable is unset, and tearDownAll still runs. The message the operator
  // should read is the one about the variable, not a LateInitializationError
  // from the sign-out.
  SupabaseClient? client;
  late String inspectorId;
  late SupabaseInspectionsRepository inspections;
  late ReportService reports;

  setUpAll(() async {
    // All four before any network call, so a missing variable is the first
    // and only thing the run says.
    final url = _env('SUPABASE_URL');
    final anonKey = _env('SUPABASE_ANON_KEY');
    final email = _env('BACKFILL_INSPECTOR_EMAIL');
    final password = _env('BACKFILL_INSPECTOR_PASSWORD');

    _assertNotPrivileged(anonKey);

    final c = SupabaseClient(url, anonKey);
    client = c;
    final signedIn = await c.auth.signInWithPassword(
      email: email,
      password: password,
    );
    inspectorId = signedIn.user!.id;

    // main.dart's wiring minus the offline layer — a headless run has no
    // queue to merge, and only the server's rows can be submitted — and minus
    // the share sheet. The owner segment of every path is the live uid, never
    // a row's inspector_id, the rule the app and the policy share.
    final items = SupabaseInspectionItemsRepository(c);
    final profiles = SupabaseProfileRepository(c);
    final photos = PhotoWorkflow(
      objects: SupabaseObjectStore(c),
      metadata: SupabasePhotoMetadataStore(c),
      currentUserId: () => inspectorId,
    );
    inspections = SupabaseInspectionsRepository(c);
    reports = ReportService(
      loader: ReportLoader(items: items, photos: photos, profiles: profiles),
      renderer: const PdfReportRenderer(),
      sharer: const _NeverShare(),
      store: SupabaseReportStore(c),
      currentUserId: () => inspectorId,
    );
  });

  tearDownAll(() async {
    final c = client;
    if (c == null) return;
    await _attempt('sign out', c.auth.signOut);
    await _attempt('dispose', c.dispose);
  });

  test('every submitted inspection of the signed-in inspector holds a report',
      () async {
    // listMine() is what the Reports tab hands to publishMissing (hosted smoke
    // 22a reads back the same way), and the filter is the tab's own. Drafts
    // are not eligible and are not the phone's to submit from here (D10).
    final submitted = (await inspections.listMine())
        .where((i) => i.status == InspectionStatus.submitted)
        .toList();
    _say('backfill: inspector $inspectorId has ${submitted.length} submitted '
        'inspection(s)');
    if (submitted.isEmpty) {
      _say('backfill: nothing to upload. If reports are expected, check that '
          'BACKFILL_INSPECTOR_EMAIL is the inspector who owns them.');
    }

    // Stage lines as they happen, so a run that stalls says where it stalled
    // and on which inspection. The upload itself is bounded by
    // SupabaseReportStore.uploadTimeout.
    final report = await reports.publishMissing(
      submitted,
      onStage: (inspection, stage) => _say('  ${inspection.id}  ${stage.name}'),
    );
    if (report.lastError != null) {
      _say('backfill: last error: ${report.lastError}');
    }

    // Read back from the bucket the way the screens do (D27), not from what
    // the loop believed it did. A listing that fails here fails the run with
    // its own message: "could not check" is not "not uploaded" (D28), and it
    // is not "done" either.
    final stored = await reports.published();
    final missing = <String>[];
    for (final inspection in submitted) {
      final path = reportStoragePath(
        inspectorId: inspectorId,
        inspectionId: inspection.id,
      );
      final held = await _held(client!, path);
      final outcome = _outcome(inspection.id, report);
      _say('  ${inspection.id}  $path  $held  $outcome');
      if (!stored.contains(inspection.id)) missing.add(inspection.id);
    }

    final already = submitted.length -
        report.published.length -
        report.failed.length -
        report.skipped.length;
    _say('backfill: uploaded ${report.published.length}, already stored '
        '$already, failed ${report.failed.length}, skipped '
        '${report.skipped.length}; ${missing.length} still without a report');

    final lastError = report.lastError;
    expect(
      missing,
      isEmpty,
      reason: 'submitted inspections still without a stored report: '
          '${missing.join(', ')}'
          '${lastError == null ? '' : ' — last error: $lastError'}',
    );
  });
}

/// What this run did about one inspection, from the report's three lists. An
/// id in none of them already held a report before the run started, which is
/// what makes a second run print `already` on every line.
String _outcome(String id, PublishReport report) {
  if (report.published.contains(id)) return 'uploaded';
  if (report.failed.contains(id)) return 'failed';
  if (report.skipped.contains(id)) return 'skipped';
  return 'already';
}

/// What the bucket holds at [path] now, for the operator's eye: the object's
/// size, or that it is absent. One listing of the inspection's folder under
/// the owner SELECT policy — the same read DEPLOY §7's `storage.objects` query
/// makes with `metadata->>'size'`, minus the privilege. The size sits in the
/// Storage API's listing metadata, not in a column this repository controls, so
/// its absence with the object present is "size unknown", not "absent".
Future<String> _held(SupabaseClient client, String path) async {
  final slash = path.lastIndexOf('/');
  final folder = path.substring(0, slash);
  final name = path.substring(slash + 1);
  final entries =
      await client.storage.from(SupabaseReportStore.bucket).list(path: folder);
  for (final entry in entries) {
    if (entry.name != name) continue;
    final size = entry.metadata?['size'];
    return size is num ? '${size.toInt()} bytes' : 'present, size unknown';
  }
  return 'absent';
}

/// One line to the runner's output. `print` rather than `stdout`: the test
/// runner attributes printed lines to the case and shows them under
/// `--reporter expanded`, which is where this file's result is read. The
/// tool/render harness prints the same way.
void _say(String line) {
  // ignore: avoid_print
  print(line);
}

/// Runs one teardown step, reporting a failure rather than propagating it, so
/// a sign-out that fails cannot hide the result of the run above it. Catching
/// `Exception` and not `Error` keeps that tolerance to the things that go
/// wrong against a network while a programming mistake still surfaces as one.
Future<void> _attempt(String what, Future<void> Function() step) async {
  try {
    await step();
  } on Exception catch (e) {
    stderr.writeln('backfill teardown: $what failed: $e');
  }
}

/// The publish path never opens a share sheet, and this process has no
/// platform to open one on. A sharer that fails if reached turns the first
/// half from an assumption into an assertion.
class _NeverShare implements ReportSharer {
  const _NeverShare();

  @override
  Future<bool> share(Uint8List bytes, {required String filename}) async {
    fail('publish must never share; something tried to share $filename');
  }
}
