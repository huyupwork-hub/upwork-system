// Removes the exact fixtures one hosted smoke run created, and proves they are
// gone.
//
// Why this exists: `submit` is one-way (D10) and the delete policy requires
// `status = 'draft'` (D17), so the one inspection the smoke test deliberately
// submits cannot be deleted by the anon key that created it. Its own teardown
// therefore matched zero rows and succeeded silently, stranding a
// `SMOKE ... do-not-keep` row in the shared project on every CI run.
//
// Nothing about RLS changes to fix that, and no client gains any power. This is
// a separate GitHub Actions *job*, gated behind an environment, holding a key
// that the smoke job — and every other job — never receives.
// `hosted_smoke_test.dart` still refuses to start under anything but an anon
// key, which is the property it exists to prove.
//
// SCOPE. Explicit identifiers only:
//
//   * inspection ids, item ids and storage object paths recorded by the run as
//     it created each one, or
//   * the same three, named on the command line for a documented one-off.
//
// There is no pattern match anywhere in this file. No delete by name, by owner,
// by date, by status, or by prefix. If the manifest is missing, nothing is
// deleted — a cleanup that cannot name its target does not guess.
//
// Storage objects go through the Supabase Storage API, never SQL: Postgres
// refuses a direct delete from `storage.objects` precisely because it would
// leave the backing file behind.
//
// Usage (from apps/mobile):
//
//   dart run tool/smoke_purge.dart
//   dart run tool/smoke_purge.dart --inspection <uuid> --object <path> ...
//
// Environment:
//   SUPABASE_URL                 https://<ref>.supabase.co
//   SUPABASE_SERVICE_ROLE_KEY    privileged; absent => warn and exit 0
//   SMOKE_RUN_TOKEN              identifies the run that wrote the manifest
//   SMOKE_MANIFEST               path to the manifest (default below)
//
// Imports nothing but `dart:` libraries, so it adds no dependency to the app
// package and cannot be reached from application code.

import 'dart:convert';
import 'dart:io';

const String _defaultManifest = 'build/smoke-manifest.json';
const String _bucket = 'inspection-photos';

/// Dart ignores whatever `main` returns, so the outcome has to be assigned to
/// `exitCode` or the step is green no matter what happened. Keeping the logic in
/// [_run] makes that impossible to forget again.
Future<void> main(List<String> args) async {
  exitCode = await _run(args);
}

Future<int> _run(List<String> args) async {
  final _Targets explicit;
  try {
    explicit = _parseArgs(args);
  } on FormatException catch (e) {
    _error('$e');
    return 2;
  }

  final url = _env('SUPABASE_URL');
  // Trimmed before it ever reaches a header. A key with a trailing newline —
  // the usual shape when one has been piped in from a file — makes Dart's
  // header validator throw a FormatException that quotes the value it rejected,
  // and that exception would otherwise be printed.
  final key = _env('SUPABASE_SERVICE_ROLE_KEY').trim();

  if (key.isEmpty) {
    // Loud, and green. Failing here would turn the job red for a secret that may
    // legitimately not be configured — on a fork, or before the environment is
    // set up — and a permanently red gate is one nobody triages. The smoke job's
    // own case 38 is what fails if a fixture goes unrecorded, so nothing is
    // being papered over here.
    _warn('SUPABASE_SERVICE_ROLE_KEY is not set, so this run\'s submitted '
        'fixture stays in the project. See docs/SMOKE_TEST.md for the two '
        'settings that enable cleanup.');
    return 0;
  }
  if (url.isEmpty) {
    _error('SUPABASE_URL is not set.');
    return 1;
  }
  if (_looksAnonymous(key)) {
    // An anon key would delete nothing and report success — exactly the failure
    // this script exists to end. Better to fail than to be silently useless.
    _error('SUPABASE_SERVICE_ROLE_KEY carries role "anon"; it cannot delete a '
        'submitted inspection and would purge nothing.');
    return 1;
  }

  final targets = explicit.isEmpty ? _fromManifest() : explicit;
  if (targets.isEmpty) {
    // Nothing nameable, so nothing to do. Deliberately not an error: a run that
    // died before writing a manifest is already failing somewhere louder, and a
    // cleanup job that cannot name a target must not invent one.
    _warn('no explicit targets (${targets.source}); nothing will be deleted.');
    return 0;
  }

  stdout.writeln('smoke purge: source=${targets.source} '
      'inspections=${targets.inspectionIds.length} '
      'items=${targets.itemIds.length} '
      'objects=${targets.storagePaths.length}');

  final api = _Api(url, key);
  final storageFailures = <String>[];
  var removedObjects = 0;
  var removedRows = 0;

  try {
    // Storage first, through the Storage API. Deleting the row first would
    // strand the bytes: the object's own delete policy reaches through the
    // owning inspection, and Postgres refuses a direct delete from
    // storage.objects, so nothing could reach it afterwards. That ordering is
    // how the two orphans already in this project were made.
    for (final path in targets.storagePaths) {
      stdout.writeln('  object  $path');
      try {
        if (await api.deleteObject(_bucket, path)) {
          removedObjects++;
        } else {
          stdout.writeln('          (already absent)');
        }
      } on _ApiException catch (e) {
        // Collected rather than thrown: an object left behind is a leak, and a
        // row left behind because of an object is two.
        storageFailures.add('$path ($e)');
      }
    }

    // Items before their parents. The FK would cascade them anyway, but naming
    // them is what the scope promises, and it makes the log say what went.
    if (targets.itemIds.isNotEmpty) {
      for (final id in targets.itemIds) {
        stdout.writeln('  item    $id');
      }
      removedRows += await api.deleteByIds('inspection_items', targets.itemIds);
    }

    if (targets.inspectionIds.isNotEmpty) {
      for (final id in targets.inspectionIds) {
        stdout.writeln('  row     $id');
      }
      removedRows +=
          await api.deleteByIds('inspections', targets.inspectionIds);
    }

    // Verify rather than assume. A privileged key that silently matched nothing
    // is the same failure in a new coat, so the proof is a read-back by id.
    final leftoverRows =
        await api.selectIds('inspections', targets.inspectionIds);
    final leftoverItems =
        await api.selectIds('inspection_items', targets.itemIds);
    if (leftoverRows.isNotEmpty || leftoverItems.isNotEmpty) {
      _error('purge incomplete: '
          '${leftoverRows.length} inspection(s) and ${leftoverItems.length} '
          'item(s) still present: '
          '${[...leftoverRows, ...leftoverItems].join(", ")}');
      return 1;
    }
    if (storageFailures.isNotEmpty) {
      _error('rows are gone but ${storageFailures.length} object(s) could not '
          'be removed and are now unreachable: ${storageFailures.join("; ")}');
      return 1;
    }

    stdout.writeln('smoke purge: removed $removedRows row(s) and '
        '$removedObjects object(s); nothing named remains');
    return 0;
  } on _ApiException catch (e) {
    _error('purge failed: $e');
    return 1;
  } on Exception catch (e) {
    // A dropped socket or a TLS failure is a real outcome for a maintenance
    // step, not a bug in it, and it should read as one line rather than a stack
    // dump. Errors still propagate: a programming mistake here is not something
    // to report as a network problem.
    _error('purge failed before it could finish: $e');
    return 1;
  } finally {
    api.close();
  }
}

// --------------------------------------------------------------------- targets

/// What to delete. Every field is an explicit identifier; there is no pattern.
class _Targets {
  const _Targets({
    required this.source,
    required this.inspectionIds,
    required this.itemIds,
    required this.storagePaths,
  });

  final String source;
  final List<String> inspectionIds;
  final List<String> itemIds;
  final List<String> storagePaths;

  bool get isEmpty =>
      inspectionIds.isEmpty && itemIds.isEmpty && storagePaths.isEmpty;

  static _Targets none(String source) => _Targets(
        source: source,
        inspectionIds: const [],
        itemIds: const [],
        storagePaths: const [],
      );
}

/// `--inspection <uuid>`, `--item <uuid>`, `--object <path>`, repeatable.
///
/// The documented one-off path. Naming targets on the command line skips the
/// manifest entirely, which is what makes it usable for artefacts no run
/// recorded — the historical orphans, and the device-QA row.
_Targets _parseArgs(List<String> args) {
  final inspections = <String>[];
  final items = <String>[];
  final objects = <String>[];

  for (var i = 0; i < args.length; i++) {
    final flag = args[i];
    if (i + 1 >= args.length) {
      throw FormatException('$flag needs a value');
    }
    final value = args[++i];
    switch (flag) {
      case '--inspection':
        inspections.add(value);
      case '--item':
        items.add(value);
      case '--object':
        objects.add(value);
      default:
        throw FormatException(
          'unknown argument "$flag"; expected --inspection, --item or --object',
        );
    }
  }

  return _Targets(
    source: 'command line',
    inspectionIds: inspections,
    itemIds: items,
    storagePaths: objects,
  );
}

/// The identifiers the run recorded as it created each fixture.
_Targets _fromManifest() {
  final path = _env('SMOKE_MANIFEST', _defaultManifest);
  final token = _normaliseToken(_env('SMOKE_RUN_TOKEN'));
  final file = File(path);

  if (!file.existsSync()) {
    _warn('no manifest at $path.');
    return _Targets.none('no manifest');
  }

  final Map<String, dynamic> decoded;
  try {
    decoded = json.decode(file.readAsStringSync()) as Map<String, dynamic>;
  } on FormatException catch (e) {
    _warn('manifest at $path is unreadable ($e).');
    return _Targets.none('unreadable manifest');
  } on TypeError catch (e) {
    _warn('manifest at $path has an unexpected shape ($e).');
    return _Targets.none('malformed manifest');
  }

  // A self-hosted runner reuses its workspace, so a manifest can outlive the
  // run that wrote it. Acting on a previous run's ids would delete only
  // fixtures — but it would also hide that this run recorded nothing, and
  // "cleaned up the wrong run and told you it cleaned up this one" is not a
  // state worth entering.
  final recorded = (decoded['runToken'] as String?) ?? '';
  if (token.isNotEmpty && recorded != token) {
    _warn('the manifest at $path belongs to run "$recorded", not "$token"; '
        'refusing to act on it.');
    return _Targets.none('stale manifest');
  }

  return _Targets(
    source: path,
    inspectionIds: _stringList(decoded['inspectionIds']),
    itemIds: _stringList(decoded['itemIds']),
    storagePaths: _stringList(decoded['storagePaths']),
  );
}

/// Reduces a token to `[a-z0-9]`.
///
/// MUST match `_runToken` in `test_hosted/hosted_smoke_test.dart`, which applies
/// the same reduction before recording it. If the two disagree, every manifest
/// looks stale and nothing is ever cleaned — silently.
String _normaliseToken(String raw) =>
    raw.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

List<String> _stringList(Object? value) {
  if (value is! List) return const [];
  return value.whereType<String>().where((s) => s.isNotEmpty).toList();
}

// --------------------------------------------------------------------- http

class _ApiException implements Exception {
  const _ApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The smallest PostgREST/Storage client that does this job.
///
/// `dart:io` only, matching `httpGet` in the smoke test: a maintenance script
/// holding a privileged key should have as little between it and the wire as
/// possible.
class _Api {
  _Api(this.baseUrl, this.key);

  final String baseUrl;
  final String key;
  final HttpClient _client = HttpClient();

  void close() => _client.close(force: true);

  Future<_Response> _send(
    String method,
    Uri uri, {
    Map<String, String> extraHeaders = const {},
  }) async {
    final req = await _client.openUrl(method, uri);
    req.headers.set('apikey', key);
    req.headers.set('authorization', 'Bearer $key');
    extraHeaders.forEach(req.headers.set);
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    return _Response(res.statusCode, text);
  }

  /// Deletes one object through the Storage API.
  ///
  /// Never SQL: Postgres refuses a direct delete from `storage.objects` — the
  /// guard exists because removing the row leaves the backing file behind. A 404
  /// counts as absent rather than failed, since the run's own teardown removes
  /// the photo while the inspection is still a draft and on a clean run there is
  /// nothing here.
  Future<bool> deleteObject(String bucket, String path) async {
    final uri = Uri.parse(
      '$baseUrl/storage/v1/object/$bucket/${_encodePath(path)}',
    );
    final res = await _send('DELETE', uri);
    if (res.ok) return true;
    if (res.status == 404) return false;
    throw _ApiException('storage delete -> ${res.status} ${res.body}');
  }

  Future<int> deleteByIds(String table, List<String> ids) async {
    if (ids.isEmpty) return 0;
    final list = ids.map(Uri.encodeComponent).join(',');
    final res = await _send(
      'DELETE',
      Uri.parse('$baseUrl/rest/v1/$table?id=in.($list)'),
      extraHeaders: {'prefer': 'return=representation'},
    );
    if (!res.ok) {
      throw _ApiException('delete $table -> ${res.status} ${res.body}');
    }
    final decoded = json.decode(res.body.isEmpty ? '[]' : res.body);
    return decoded is List ? decoded.length : 0;
  }

  Future<List<String>> selectIds(String table, List<String> ids) async {
    if (ids.isEmpty) return const [];
    final list = ids.map(Uri.encodeComponent).join(',');
    final res = await _send(
      'GET',
      Uri.parse('$baseUrl/rest/v1/$table?select=id&id=in.($list)'),
    );
    if (!res.ok) {
      throw _ApiException('verify $table -> ${res.status} ${res.body}');
    }
    final decoded = json.decode(res.body.isEmpty ? '[]' : res.body);
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map<String, dynamic>>()
        .map((row) => row['id'])
        .whereType<String>()
        .toList();
  }
}

class _Response {
  const _Response(this.status, this.body);
  final int status;
  final String body;
  bool get ok => status >= 200 && status < 300;
}

/// Percent-encodes each segment but keeps the separators.
String _encodePath(String path) =>
    path.split('/').map(Uri.encodeComponent).join('/');

// --------------------------------------------------------------------- misc

String _env(String name, [String fallback = '']) {
  final value = Platform.environment[name];
  if (value == null || value.isEmpty) return fallback;
  return value;
}

/// True when the key announces itself as the public one.
///
/// Deliberately a negative check. Asserting the privileged claim by name would
/// put that literal in the tree, and the repository's own secret-hygiene gate
/// greps for exactly that string outside `docs/` — a check that had to be
/// spelled around the guard is a check nobody should trust. What matters here is
/// caught anyway: a key that cannot delete is proven useless by the read-back at
/// the end, which fails the job.
bool _looksAnonymous(String key) {
  if (key.startsWith('sb_publishable_')) return true;
  final parts = key.split('.');
  if (parts.length != 3) return false;
  try {
    final payload = json.decode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    );
    return payload is Map && payload['role'] == 'anon';
  } on FormatException {
    return false;
  }
}

void _warn(String message) =>
    stdout.writeln('::warning::smoke purge: $message');

void _error(String message) => stderr.writeln('::error::smoke purge: $message');
