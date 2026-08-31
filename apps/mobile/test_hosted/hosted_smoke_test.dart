/// Hosted Supabase authenticated smoke test.
///
/// Proves the Auth -> Create Inspection slice against a REAL hosted project,
/// which no other test in this repository does: `test/` runs entirely against
/// in-memory fakes and touches no network.
///
/// Deliberately NOT under `test/`. `flutter test` with no arguments runs only
/// `test/`, so this cannot accidentally join the hermetic suite and make it
/// network-dependent or non-deterministic. Run it explicitly:
///
///   flutter test test_hosted/
///
/// Credentials come from the environment, never from --dart-define: dart-defines
/// land in the process command line and in CI step echoes, environment variables
/// do not. Nothing here is committed and nothing is printed.
///
/// Required environment variables:
///   SUPABASE_URL             https://<ref>.supabase.co
///   SUPABASE_ANON_KEY        the anon / publishable key — never the service role
///   SMOKE_USER_A_EMAIL       an existing confirmed user
///   SMOKE_USER_A_PASSWORD
///   SMOKE_USER_B_EMAIL       a second, different existing confirmed user
///   SMOKE_USER_B_PASSWORD
///
/// This test uses the anon key only. It exercises the same repository classes the
/// app uses, so what passes here is the real client path, not a parallel one.
library;

import 'dart:convert';
import 'dart:io';

import 'package:fieldproof/src/data/models.dart';
import 'package:fieldproof/src/data/repositories.dart';
import 'package:fieldproof/src/data/supabase_repositories.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _env(String name) {
  final value = Platform.environment[name] ?? '';
  if (value.isEmpty) {
    fail(
      '$name is not set. This test needs a hosted Supabase project; see '
      'docs/SMOKE_TEST.md for the full list and how to provide it.',
    );
  }
  return value;
}

/// Refuses to run under a privileged key.
///
/// This is the one mistake that would invalidate every assertion in the file: a
/// privileged key bypasses RLS completely, so the isolation cases would pass
/// while proving nothing at all.
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
    fail('SUPABASE_ANON_KEY is a secret key; this test must use a public one.');
  }
}

void main() {
  // Two independent clients, so each holds its own session. Sharing one client
  // would make "user B cannot see it" meaningless — it would still be user A.
  late SupabaseClient clientA;
  late SupabaseClient clientB;

  late AuthRepository authA;
  late ProfileRepository profilesA;
  late InspectionsRepository inspectionsA;
  late InspectionsRepository inspectionsB;

  late String userAId;
  late String userBId;

  Inspection? created;

  // Distinctive per-run name so a leaked row is traceable to the run that made it.
  final siteName =
      'SMOKE ${DateTime.now().toUtc().toIso8601String()} do-not-keep';

  setUpAll(() async {
    final url = _env('SUPABASE_URL');
    final anonKey = _env('SUPABASE_ANON_KEY');

    _assertNotPrivileged(anonKey);

    clientA = SupabaseClient(url, anonKey);
    clientB = SupabaseClient(url, anonKey);

    final a = await clientA.auth.signInWithPassword(
      email: _env('SMOKE_USER_A_EMAIL'),
      password: _env('SMOKE_USER_A_PASSWORD'),
    );
    final b = await clientB.auth.signInWithPassword(
      email: _env('SMOKE_USER_B_EMAIL'),
      password: _env('SMOKE_USER_B_PASSWORD'),
    );

    userAId = a.user!.id;
    userBId = b.user!.id;

    authA = SupabaseAuthRepository(clientA);
    profilesA = SupabaseProfileRepository(clientA);
    inspectionsA = SupabaseInspectionsRepository(clientA);
    inspectionsB = SupabaseInspectionsRepository(clientB);
  });

  tearDownAll(() async {
    // Leave the project as we found it. Deleting as A also re-proves the owner
    // delete policy works.
    final id = created?.id;
    if (id != null) {
      await clientA.from('inspections').delete().eq('id', id);
    }
    await clientA.auth.signOut();
    await clientB.auth.signOut();
    await clientA.dispose();
    await clientB.dispose();
  });

  test('1. user A authenticates with ordinary Supabase Auth', () {
    expect(userAId, isNotEmpty);
    expect(authA.currentUserId, userAId);
    // Two genuinely different principals, or the isolation cases below are void.
    expect(userBId, isNot(userAId));
  });

  test('2. user A profile exists via the trigger bootstrap path', () async {
    final profile = await profilesA.loadCurrent();
    expect(profile.id, userAId);
    expect(profile.fullName, isNotEmpty);
    expect(profile.role, 'inspector',
        reason: 'a smoke user must not be an admin; D3 changes what it can see');
  });

  test('3. user A creates a draft through the app repository path', () async {
    created = await inspectionsA.create(
      NewInspection(
        siteName: siteName,
        siteAddress: '1 Smoke Test Road',
        clientName: 'Smoke Test Client',
        inspectionDate: DateTime.now(),
      ),
    );

    expect(created!.id, isNotEmpty);
    expect(created!.status, InspectionStatus.draft,
        reason: 'status is omitted on insert so the column default applies');
    expect(created!.submittedAt, isNull);
  });

  test('4. user A reads it back', () async {
    final mine = await inspectionsA.listMine();
    final match = mine.where((i) => i.id == created!.id);
    expect(match, hasLength(1));
    expect(match.single.siteName, siteName);
    expect(match.single.clientName, 'Smoke Test Client');
  });

  test('5. stored inspector_id is user A', () async {
    expect(created!.inspectorId, userAId);

    // Re-read from the server rather than trusting the insert's return value.
    final row = await clientA
        .from('inspections')
        .select('inspector_id')
        .eq('id', created!.id)
        .single();
    expect(row['inspector_id'], userAId);
  });

  test('6. user B cannot read user A draft', () async {
    final byId = await clientB
        .from('inspections')
        .select('id')
        .eq('id', created!.id);
    expect(byId, isEmpty, reason: 'RLS must hide it even when named directly');

    final bList = await inspectionsB.listMine();
    expect(bList.where((i) => i.id == created!.id), isEmpty);
  });

  test('7. user B cannot update or delete user A draft', () async {
    // RLS denies these silently by matching zero rows rather than raising, so
    // the assertion has to be made afterwards, against the data.
    await clientB
        .from('inspections')
        .update({'site_name': 'HIJACKED BY B'}).eq('id', created!.id);
    await clientB.from('inspections').delete().eq('id', created!.id);

    final after = await clientA
        .from('inspections')
        .select('id, site_name')
        .eq('id', created!.id)
        .maybeSingle();

    expect(after, isNotNull, reason: 'user B must not have deleted the row');
    expect(after!['site_name'], siteName,
        reason: 'user B must not have modified the row');
  });

  test('8. user B cannot create an inspection owned by user A', () async {
    // The repository never lets a caller name the owner, so this goes to the
    // raw client to prove the database refuses it too.
    await expectLater(
      clientB.from('inspections').insert({
        'inspector_id': userAId,
        'site_name': 'PLANTED BY B',
        'inspection_date': NewInspection.dateOnly(DateTime.now()),
      }),
      throwsA(isA<PostgrestException>()),
    );
  });
}
