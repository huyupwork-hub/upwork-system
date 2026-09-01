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
//      token, for rows created in the window between an insert and the manifest
//      flush that records it.
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
  // Trimmed before it ever reaches a header. A key with a trailing newline —
  // the usual shape when one has been piped in from a file — makes Dart's
  // header validator throw a FormatException that quotes the value it rejected,
  // and that exception would otherwise be printed.
  final key = _env('SUPABASE_SERVICE_ROLE_KEY').trim();
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
  if (_looksAnonymous(key)) {
    // An anon key would delete nothing and report success — exactly the failure
    // this script exists to end. Better to fail than to be silently useless.
    _error('SUPABASE_SERVICE_ROLE_KEY carries role "anon"; it cannot delete a '
        'submitted inspection and would purge nothing.');
    return 1;
  }

  final token = normaliseToken(_env('SMOKE_RUN_TOKEN'));
  if (token.isEmpty) {
    _error('SMOKE_RUN_TOKEN is not set; refusing to sweep without a bound.');
    return 1;
  }

  final manifest = _readManifest(manifestPath);

  // A self-hosted runner reuses its workspace, so a manifest can outlive the run
  // that wrote it. Acting on a previous run's ids while believing they are this
  // one's would not delete anything it should not — every id in there was a
  // fixture — but it would hide the fact that this run recorded nothing, which
  // is worth knowing. On a mismatch the ids are dropped and the token sweep,
  // bounded by this run alone, does the work.
  final stale = manifest.found && manifest.runToken != token;
  if (stale) {
    _warn('the manifest at $manifestPath belongs to run '
        '"${manifest.runToken}", not "$token"; ignoring its ids and relying on '
        'the token sweep.');
  }
  final knownIds = stale ? const <String>[] : manifest.inspectionIds;
  final knownObjects = stale ? const <String>[] : manifest.storagePaths;

  stdout.writeln('smoke purge: token=$token '
      'manifest=${manifest.found && !stale ? manifestPath : "absent"} '
      'ids=${knownIds.length} objects=${knownObjects.length}');

  final api = _Api(url, key);
  final storageFailures = <String>[];
  var removedObjects = 0;
  var removedRows = 0;

  try {
    // Resolve the rows first, because their ids are how the storage prefixes
    // are built. Doing this before any delete is what lets the object sweep work
    // at all on the path where no manifest was written.
    final targets = await api.findTargets(knownIds, _namePrefix, token);

    // Every object under this run's rows, whether or not the manifest names it.
    // The manifest can miss one: a process that dies between the upload landing
    // and the flush that records it leaves an object nothing knows about, and
    // deleting the row first would put it permanently out of reach of every
    // client — which is exactly how the orphans already in this project were
    // stranded.
    final objects = <String>{...knownObjects};
    for (final target in targets) {
      objects.addAll(await api.listObjectsUnder(
        _bucket,
        '${target.inspectorId}/${target.id}/',
      ));
    }

    // Storage before rows, and one failure must not stop the rest. An object
    // left behind is a leak; a row left behind because of an object is two.
    for (final path in objects) {
      try {
        if (await api.deleteObject(_bucket, path)) removedObjects++;
      } on _ApiException catch (e) {
        storageFailures.add('$path ($e)');
      }
    }

    // Then the rows. Items and photo metadata are FK cascades of the
    // inspection, so naming the parent is enough and is also the narrowest
    // possible delete.
    if (knownIds.isNotEmpty) {
      removedRows += await api.deleteInspectionsByIds(knownIds);
    }
    removedRows += await api.deleteInspectionsByToken(_namePrefix, token);

    // Verify rather than assume. A privileged key that silently matched nothing
    // is the same failure in a new coat, so the proof is a read-back.
    final leftover = await api.findTargets(knownIds, _namePrefix, token);
    if (leftover.isNotEmpty) {
      _error('purge incomplete: ${leftover.length} row(s) still present: '
          '${leftover.map((t) => t.id).join(", ")}');
      return 1;
    }
    if (storageFailures.isNotEmpty) {
      _error('rows are gone but ${storageFailures.length} object(s) could not '
          'be removed and are now unreachable: ${storageFailures.join("; ")}');
      return 1;
    }

    stdout.writeln('smoke purge: removed $removedRows row(s) and '
        '$removedObjects object(s); nothing remains for token $token');
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

/// Reduces a token to `[a-z0-9]`.
///
/// MUST match `_runToken` in `test_hosted/hosted_smoke_test.dart`, which applies
/// the same reduction before embedding the token in a fixture name. If the two
/// disagree, the test embeds one string and this sweeps for another, the sweep
/// matches nothing, and the step still reports success — a silent no-op, which
/// is the precise failure this whole file exists to remove.
///
/// It also keeps the token safe where it is used: interpolated into a SQL LIKE
/// pattern, where a stray `%` or `_` would quietly widen the match past this
/// run.
String normaliseToken(String raw) =>
    raw.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

// --------------------------------------------------------------------- manifest

class _Manifest {
  const _Manifest({
    required this.found,
    required this.runToken,
    required this.inspectionIds,
    required this.storagePaths,
  });

  final bool found;
  final String runToken;
  final List<String> inspectionIds;
  final List<String> storagePaths;

  static const _Manifest absent = _Manifest(
    found: false,
    runToken: '',
    inspectionIds: [],
    storagePaths: [],
  );
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
    return _Manifest.absent;
  }
  try {
    final decoded =
        json.decode(file.readAsStringSync()) as Map<String, dynamic>;
    return _Manifest(
      found: true,
      runToken: (decoded['runToken'] as String?) ?? '',
      inspectionIds: _stringList(decoded['inspectionIds']),
      storagePaths: _stringList(decoded['storagePaths']),
    );
  } on FormatException catch (e) {
    _warn('manifest at $path is unreadable ($e); '
        'falling back to the token sweep alone.');
    return _Manifest.absent;
  } on TypeError catch (e) {
    _warn('manifest at $path has an unexpected shape ($e); '
        'falling back to the token sweep alone.');
    return _Manifest.absent;
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

/// One inspection this run is responsible for, and the owner whose storage
/// prefix its objects live under.
class _Target {
  const _Target(this.id, this.inspectorId);
  final String id;
  final String inspectorId;
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
    Object? body,
    Map<String, String> extraHeaders = const {},
  }) async {
    final req = await _client.openUrl(method, uri);
    req.headers.set('apikey', key);
    req.headers.set('authorization', 'Bearer $key');
    extraHeaders.forEach(req.headers.set);
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(json.encode(body)));
    }
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    return _Response(res.statusCode, text);
  }

  /// The rows this run is responsible for: the manifest's ids plus anything the
  /// bounded name sweep finds, with the owner needed to build a storage prefix.
  Future<List<_Target>> findTargets(
    List<String> ids,
    String prefix,
    String token,
  ) async {
    final byId = <String, _Target>{};

    if (ids.isNotEmpty) {
      final list = ids.map(Uri.encodeComponent).join(',');
      for (final t in await _selectTargets(
        Uri.parse(
          '$baseUrl/rest/v1/inspections?select=id,inspector_id&id=in.($list)',
        ),
      )) {
        byId[t.id] = t;
      }
    }

    final pattern = Uri.encodeComponent('$prefix*$token*');
    for (final t in await _selectTargets(
      Uri.parse(
        '$baseUrl/rest/v1/inspections'
        '?select=id,inspector_id&site_name=like.$pattern',
      ),
    )) {
      byId[t.id] = t;
    }

    return byId.values.toList();
  }

  Future<List<_Target>> _selectTargets(Uri uri) async {
    final res = await _send('GET', uri);
    if (!res.ok) {
      throw _ApiException('select -> ${res.status} ${res.body}');
    }
    final decoded = json.decode(res.body.isEmpty ? '[]' : res.body);
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map<String, dynamic>>()
        .where((row) => row['id'] is String && row['inspector_id'] is String)
        .map(
          (row) => _Target(row['id'] as String, row['inspector_id'] as String),
        )
        .toList();
  }

  /// Every object beneath a prefix.
  ///
  /// Storage has no recursive list, only a directory emulation: an entry with a
  /// null `id` is a folder. Paths here are exactly four levels
  /// (`owner/inspection/item/file`), so one level of recursion below the given
  /// inspection prefix reaches every file and no more.
  Future<List<String>> listObjectsUnder(String bucket, String prefix) async {
    final found = <String>[];
    for (final entry in await _list(bucket, prefix)) {
      if (entry.isFolder) {
        for (final leaf in await _list(bucket, '$prefix${entry.name}/')) {
          if (!leaf.isFolder) found.add('$prefix${entry.name}/${leaf.name}');
        }
      } else {
        found.add('$prefix${entry.name}');
      }
    }
    return found;
  }

  Future<List<_Entry>> _list(String bucket, String prefix) async {
    final res = await _send(
      'POST',
      Uri.parse('$baseUrl/storage/v1/object/list/$bucket'),
      body: {'prefix': prefix, 'limit': 200, 'offset': 0},
    );
    if (!res.ok) {
      throw _ApiException('storage list -> ${res.status} ${res.body}');
    }
    final decoded = json.decode(res.body.isEmpty ? '[]' : res.body);
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map<String, dynamic>>()
        .where((row) => row['name'] is String)
        .map((row) => _Entry(row['name'] as String, row['id'] == null))
        .toList();
  }

  /// Deletes one object. A 404 counts as absent rather than failed — the run's
  /// own teardown removes the photo while the inspection is still a draft, so on
  /// a clean run there is nothing here and that is the expected case.
  Future<bool> deleteObject(String bucket, String path) async {
    final uri = Uri.parse(
      '$baseUrl/storage/v1/object/$bucket/${_encodePath(path)}',
    );
    final res = await _send('DELETE', uri);
    if (res.ok) return true;
    if (res.status == 404) return false;
    throw _ApiException('storage delete -> ${res.status} ${res.body}');
  }

  Future<int> deleteInspectionsByIds(List<String> ids) async {
    final list = ids.map(Uri.encodeComponent).join(',');
    final uri = Uri.parse('$baseUrl/rest/v1/inspections?id=in.($list)');
    return _deleteReturningCount(uri, 'by id');
  }

  /// Bounded by the `SMOKE ` prefix AND the run's own token, both required.
  ///
  /// PostgREST maps `*` in a `like` value to SQL `%`, so this is
  /// `site_name like 'SMOKE %<token>%'` and nothing wider. A demo record cannot
  /// match it: it would have to be named `SMOKE ...` and contain a token minted
  /// by this run. The token is reduced to `[a-z0-9]` by [normaliseToken] before
  /// it gets here, so it can carry no LIKE metacharacter of its own.
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
}

class _Entry {
  const _Entry(this.name, this.isFolder);
  final String name;
  final bool isFolder;
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
/// the end, which fails the step.
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
