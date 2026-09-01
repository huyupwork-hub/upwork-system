/// Durable storage for offline-origin drafts.
///
/// The port is deliberately the narrowest thing that survives process death: one
/// string, read and written whole. Everything above it works in domain objects,
/// so the persistence mechanism is one file's worth of surface — swappable, and
/// small enough that a test can prove reconstruction rather than simulate it.
///
/// **Why not a database.** The queue holds drafts that have not synced yet — a
/// handful of rows at the very most, written on user actions, never queried by
/// anything but "all of them". sqflite or drift would add a schema, migrations
/// and a code generator to serialise a list that fits in a preference value, and
/// would invite exactly the shadow-copy-of-Supabase design this slice refuses.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'local_draft.dart';

/// Where the queue's bytes live.
abstract interface class DraftStore {
  /// The stored document, or null when nothing has been written.
  Future<String?> read();

  Future<void> write(String json);
}

/// `shared_preferences`, which is already in the dependency graph.
///
/// It arrives transitively with `supabase_flutter`, which uses it to persist the
/// auth session — so the plugin, its platform channel and its Android
/// implementation are all in the app already. Declaring it directly adds a line
/// to `pubspec.yaml` and no native code to the APK; depending on it implicitly
/// through another package's graph would be the thing worth avoiding.
///
/// On Android this is a `SharedPreferences` XML file in the app's private data
/// directory: it outlives the process, is cleared only by uninstalling or
/// clearing app data, and is not readable by other apps.
class SharedPreferencesDraftStore implements DraftStore {
  const SharedPreferencesDraftStore({this.key = _defaultKey});

  static const String _defaultKey = 'fieldproof.offline_drafts.v1';

  /// Versioned so a future change of shape can be recognised rather than
  /// silently mis-parsed into an empty queue.
  final String key;

  @override
  Future<String?> read() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(key);
  }

  @override
  Future<void> write(String json) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, json);
  }
}

/// A store that keeps the document in memory.
///
/// Lives in `lib/` rather than in the test folder because it is also the honest
/// fallback for a platform where preferences are unavailable, and because tests
/// that reconstruct a repository over the *same* store are proving the
/// repository re-reads its state — which is the property that matters — rather
/// than proving `shared_preferences` works.
class MemoryDraftStore implements DraftStore {
  MemoryDraftStore([this._document]);

  String? _document;

  /// Set to make [write] throw, so a caller can be shown to keep the user's data
  /// rather than dropping it when persistence fails.
  Object? failWrites;

  @override
  Future<String?> read() async => _document;

  @override
  Future<void> write(String json) async {
    if (failWrites != null) throw failWrites!;
    _document = json;
  }
}

/// The queue itself: decode on first use, write through on every change.
///
/// Write-through rather than periodic flushing, because the property being
/// bought is "the draft is still there after the process dies", and a flush
/// interval is exactly the window in which it would not be. The volumes involved
/// make the cost irrelevant.
class LocalDraftBook {
  LocalDraftBook(this._store, {this.onChanged});

  final DraftStore _store;

  /// Called after every successful load or mutation, with the current queue.
  /// Used to keep the status the UI renders in step with what is on disk.
  final void Function(List<LocalDraft> drafts)? onChanged;

  List<LocalDraft>? _cache;

  /// Every offline-origin draft on this device, oldest first.
  ///
  /// Oldest first because that is the order they are synced in: work is pushed
  /// in the order it was captured.
  Future<List<LocalDraft>> all() async {
    final cached = _cache;
    if (cached != null) return cached;

    final raw = await _store.read();
    final loaded = _decode(raw);
    _cache = loaded;
    onChanged?.call(loaded);
    return loaded;
  }

  /// The drafts belonging to [ownerId].
  ///
  /// A device can be signed into one account at a time, but sign-out does not
  /// erase the queue — an inspector who signs out with unsynced work must find
  /// it again on sign-in, not discover it was thrown away. Filtering by owner is
  /// what keeps that safe: another inspector signing in on the same handset
  /// never sees, edits or pushes work that is not theirs.
  Future<List<LocalDraft>> ownedBy(String ownerId) async {
    final drafts = await all();
    return drafts.where((d) => d.ownerId == ownerId).toList(growable: false);
  }

  Future<LocalDraft?> byId(String id) async {
    for (final draft in await all()) {
      if (draft.id == id) return draft;
    }
    return null;
  }

  /// The draft containing [itemId], or null. Items are addressed by their own id
  /// throughout the repository contract, so the queue has to be able to resolve
  /// one back to its parent.
  Future<LocalDraft?> containingItem(String itemId) async {
    for (final draft in await all()) {
      if (draft.items.any((i) => i.id == itemId)) return draft;
    }
    return null;
  }

  /// Inserts or replaces [draft], then persists.
  ///
  /// Persisting before returning is what makes the caller's success meaningful:
  /// if the write throws, the exception reaches the user instead of the app
  /// reporting a draft it did not actually keep.
  Future<void> put(LocalDraft draft) async {
    final drafts = [...await all()];
    final index = drafts.indexWhere((d) => d.id == draft.id);
    if (index < 0) {
      drafts.add(draft);
    } else {
      drafts[index] = draft;
    }
    await _commit(drafts);
  }

  /// Drops [id] from the queue.
  ///
  /// Called in exactly one place — after a sync has verified the row and its
  /// items are on the server. This is the handoff of authority, so it is a
  /// deliberate deletion and not a state change.
  Future<void> remove(String id) async {
    final drafts = [...await all()]..removeWhere((d) => d.id == id);
    await _commit(drafts);
  }

  Future<void> _commit(List<LocalDraft> drafts) async {
    await _store.write(_encode(drafts));
    _cache = drafts;
    onChanged?.call(drafts);
  }

  static String _encode(List<LocalDraft> drafts) =>
      json.encode(drafts.map((d) => d.toJson()).toList(growable: false));

  /// A document that cannot be parsed yields an empty queue rather than an
  /// exception that would make the app unusable.
  ///
  /// The catch is deliberately broad: malformed JSON raises `FormatException`,
  /// but well-formed JSON of the wrong *shape* raises a `TypeError` out of the
  /// casts in `fromJson`, and both mean the same thing here. This is the one
  /// place that choice is made, and it is only reachable if the stored bytes
  /// were corrupted or written by an incompatible version — the key is versioned
  /// so the latter does not silently happen.
  static List<LocalDraft> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      // Typed as Object? rather than left dynamic, so `strict-casts` has
      // something to check and nothing here is an implicit downcast.
      final decoded = json.decode(raw) as Object?;
      if (decoded is! List<dynamic>) return const [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(LocalDraft.fromJson)
          .toList(growable: false);
    } on Object {
      return const [];
    }
  }
}
