// Removes the fixtures one hosted smoke run created, and proves none are left.
//
// Why this exists at all: `submit` is one-way (D10) and the delete policy
// requires `status = 'draft'` (D17), so the one inspection the smoke test
// deliberately submits cannot be deleted by the anon key that created it. Its
// own teardown therefore matched zero rows and succeeded silently, stranding a
// `SMOKE ... do-not-keep` row in the shared project on every CI run.
//
// The fix does not touch RLS, and it gives no client any new power. This is a
// separate maintenance step, run after the test process has exited, holding a
// privileged key the test itself never sees. `hosted_smoke_test.dart` still
// refuses to run under anything but an anon key — that property is the point of
// the smoke test and is unchanged.
//
// Scope is deliberately narrow, and doubly so:
//
//   1. exact ids, read from the manifest the run wrote as it created them; and
//   2. a name sweep bounded by BOTH the `SMOKE ` prefix and the run's own
//      random token, for rows created in the window between an insert and the
//      manifest flush that records it.
//
// Neither can reach a row this run did not make. There is no unbounded delete
// anywhere in this file, and no code path deletes by owner, by date, or by
// status.
//
// Usage (from apps/mobile):
//
//   dart run tool/smoke_purge.dart
//
// Environment:
//   SUPABASE_URL                 https://<ref>.supabase.co
//   SUPABASE_SERVICE_ROLE_KEY    a privileged key; absent => skip, do not fail
//   SMOKE_RUN_TOKEN              the token the run embedded in every fixture
//   SMOKE_MANIFEST               path to the manifest (default below)
//
// Imports nothing but `dart:` libraries, so it adds no dependency to the app
// package and cannot be reached from application code.

import 'dart:convert';
import 'dart:io';

const String _defaultManifest = 'build/smoke-manifest.json';
const String _bucket = 'inspection-photos';

/// The prefix every smoke fixture's `site_name` starts with.
///
/// Load-bearing: it is half of the sweep's bound. A row that does not begin
/// with this is never a candidate, whatever else it contains.
const String _namePrefix = 'SMOKE ';

/// Dart ignores whatever `main` returns, so the outcome has to be assigned to
/// `exitCode` or the step is green no matter what happened. Keeping the logic in
/// [_run] makes that impossible to forget again.
Future<void> main(List<String> args) async {
  exitCode = await _run();
}

Future<int> _run() async {
  final url = _env('SUPABASE_URL');
  final key = _env('SUPABASE_SERVICE_ROLE_KEY');
  final token = _env('SMOKE_RUN_TOKEN');
  final manifestPath = _env('SMOKE_MANIFEST', _defaultManifest);

  if (key.isEmpty) {
    // Loud, and green. Failing here would turn every CI run red for a secret
    // the repository has never had, which is a worse outcome than a visible
    // warning: nobody triages a permanently red gate.
    _warn(
      'SUPABASE_SERVICE_ROLE_KEY is not set, so this run\'s submitted fixture '
      'stays in the project. See docs/SMOKE_TEST.md for the one command that '
      'enables cleanup.',
    );
    return 0;
  }
  if (url.isEmpty) {
    _error('SUPABASE_URL is not set.');
    return 1;
  }
  if (token.isEmpty) {
    _error('SMOKE_RUN_TOKEN is not set; refusing to sweep without a bound.');
    return 1;
  }
  if (_looksAnonymous(key)) {
    // An anon key would delete nothing and report success — exactly the failure
    // this script exists to end. Better to fail than to be silently useless.
    _error('SUPABASE_SERVICE_ROLE_KEY carries role "anon"; it cannot delete a '
        'submitted inspection and would purge nothing.');
    return 1;
  }

  final manifest = _readManifest(manifestPath);
  final ids = manifest.inspectionIds;
  final objects = manifest.storagePaths;

  stdout.writeln('smoke purge: token=$token '
      'manifest=${manifest.found ? manifestPath : "absent"} '
      'ids=${ids.length} objects=${objects.length}');

  final api = _Api(url, key);
  var removedObjects = 0;
  var removedRows = 0;

  try {
    // Storage first. An object's delete policy reaches through the owning
    // inspection, so removing the row first would strand the bytes beyond any
    // client's reach — which is how the two orphans already in this project
    // came to exist.
    for (final path in objects) {
      if (await api.deleteObject(_bucket, path)) removedObjects++;
    }

    // Then the rows. Items and photo metadata are FK cascades of the
    // inspection, so naming the parent is enough and is also the narrowest
    // possible delete.
    if (ids.isNotEmpty) {
      removedRows += await api.deleteInspectionsByIds(ids);
    }
    removedRows += await api.deleteInspectionsByToken(_namePrefix, token);

    // Verify rather than assume. A privileged key that silently matched nothing
    // is the same failure in a new coat, so the proof is a read-back.
    final leftover = await api.findRemaining(ids, _namePrefix, token);
    if (leftover.isNotEmpty) {
      _error('purge incomplete: ${leftover.length} row(s) still present: '
          '${leftover.join(", ")}');
      return 1;
    }

    stdout.writeln('smoke purge: removed $removedRows row(s) and '
        '$removedObjects object(s); nothing remains for token $token');
    return 0;
  } on _ApiException catch (e) {
    _error('purge failed: $e');
    return 1;
  } finally {
    api.close();
  }
}

// --------------------------------------------------------------------- manifest

class _Manifest {
  const _Manifest({
    required this.found,
    required this.inspectionIds,
    required this.storagePaths,
  });

  final bool found;
  final List<String> inspectionIds;
  final List<String> storagePaths;
}

/// Reads the manifest, tolerating its absence.
///
/// A missing or unreadable manifest is not fatal: the run may have died before
/// writing one, and the token sweep still bounds the work. It is reported, not
/// swallowed, because a manifest that silently stopped being written would
/// otherwise degrade the exact-id half of the scope without anyone noticing.
_Manifest _readManifest(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    _warn('no manifest at $path; falling back to the token sweep alone.');
    return const _Manifest(found: false, inspectionIds: [], storagePaths: []);
  }
  try {
    final decoded =
        json.decode(file.readAsStringSync()) as Map<String, dynamic>;
    return _Manifest(
      found: true,
      inspectionIds: _stringList(decoded['inspectionIds']),
      storagePaths: _stringList(decoded['storagePaths']),
    );
  } on FormatException catch (e) {
    _warn('manifest at $path is unreadable ($e); '
        'falling back to the token sweep alone.');
    return const _Manifest(found: false, inspectionIds: [], storagePaths: []);
  } on TypeError catch (e) {
    _warn('manifest at $path has an unexpected shape ($e); '
        'falling back to the token sweep alone.');
    return const _Manifest(found: false, inspectionIds: [], storagePaths: []);
  }
}

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

  Map<String, String> get _headers => {
        'apikey': key,
        'authorization': 'Bearer $key',
      };

  void close() => _client.close(force: true);

  Future<_Response> _send(
    String method,
    Uri uri, {
    Map<String, String> extraHeaders = const {},
  }) async {
    final req = await _client.openUrl(method, uri);
    _headers.forEach(req.headers.set);
    extraHeaders.forEach(req.headers.set);
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    return _Response(res.statusCode, body);
  }

  /// Deletes one object. A 404 counts as success — the run's own teardown
  /// removes the photo while the inspection is still a draft, so on a clean run
  /// there is nothing here and that is the expected case, not an error.
  Future<bool> deleteObject(String bucket, String path) async {
    final uri = Uri.parse(
      '$baseUrl/storage/v1/object/$bucket/${_encodePath(path)}',
    );
    final res = await _send('DELETE', uri);
    if (res.ok) return true;
    if (res.status == 404) return false;
    throw _ApiException('storage delete $path -> ${res.status} ${res.body}');
  }

  Future<int> deleteInspectionsByIds(List<String> ids) async {
    final list = ids.map(Uri.encodeComponent).join(',');
    final uri = Uri.parse('$baseUrl/rest/v1/inspections?id=in.($list)');
    return _deleteReturningCount(uri, 'by id');
  }

  /// Bounded by the `SMOKE ` prefix AND the run's random token, both required.
  ///
  /// PostgREST maps `*` in a `like` value to SQL `%`, so this is
  /// `site_name like 'SMOKE %<token>%'` and nothing wider. A demo record cannot
  /// match it: it would have to be named `SMOKE ...` and contain a token minted
  /// by this run.
  Future<int> deleteInspectionsByToken(String prefix, String token) async {
    final pattern = Uri.encodeComponent('$prefix*$token*');
    final uri =
        Uri.parse('$baseUrl/rest/v1/inspections?site_name=like.$pattern');
    return _deleteReturningCount(uri, 'by token');
  }

  Future<int> _deleteReturningCount(Uri uri, String what) async {
    final res = await _send('DELETE', uri, extraHeaders: {
      'prefer': 'return=representation',
    });
    if (!res.ok) {
      throw _ApiException('delete $what -> ${res.status} ${res.body}');
    }
    final decoded = json.decode(res.body.isEmpty ? '[]' : res.body);
    return decoded is List ? decoded.length : 0;
  }

  /// Everything still present that this run is responsible for.
  Future<List<String>> findRemaining(
    List<String> ids,
    String prefix,
    String token,
  ) async {
    final remaining = <String>{};

    if (ids.isNotEmpty) {
      final list = ids.map(Uri.encodeComponent).join(',');
      remaining.addAll(await _selectIds(
        Uri.parse('$baseUrl/rest/v1/inspections?select=id&id=in.($list)'),
      ));
    }
    final pattern = Uri.encodeComponent('$prefix*$token*');
    remaining.addAll(await _selectIds(
      Uri.parse(
        '$baseUrl/rest/v1/inspections?select=id&site_name=like.$pattern',
      ),
    ));
    return remaining.toList()..sort();
  }

  Future<List<String>> _selectIds(Uri uri) async {
    final res = await _send('GET', uri);
    if (!res.ok) {
      throw _ApiException('verify -> ${res.status} ${res.body}');
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
/// spelled around the guard is a check nobody should trust. What matters here
/// is caught anyway: a key that cannot delete is proven useless by the
/// read-back at the end, which fails the step.
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
