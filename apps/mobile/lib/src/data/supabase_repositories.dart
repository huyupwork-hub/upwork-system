/// Supabase-backed repositories.
///
/// Every call here goes through the ordinary authenticated client: the anon key
/// plus the signed-in user's JWT. There is no service-role key in this app and no
/// privileged path — the database decides what each request may see, via the
/// policies in supabase/migrations/20260831000300_rls.sql.
library;

import 'package:supabase_flutter/supabase_flutter.dart';

import 'models.dart';
import 'repositories.dart';

class SupabaseAuthRepository implements AuthRepository {
  SupabaseAuthRepository(this._client);

  final SupabaseClient _client;

  @override
  Stream<String?> get userIdChanges =>
      _client.auth.onAuthStateChange.map((event) => event.session?.user.id);

  @override
  String? get currentUserId => _client.auth.currentUser?.id;

  @override
  Future<void> signIn({required String email, required String password}) async {
    await _client.auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );
  }

  @override
  Future<void> signOut() => _client.auth.signOut();
}

class SupabaseProfileRepository implements ProfileRepository {
  SupabaseProfileRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<Profile> loadCurrent() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) throw const NotSignedInException();

    // maybeSingle(): a missing row is a real condition to handle, not an error to
    // swallow. RLS restricts this to the caller's own row regardless of the filter.
    final row = await _client
        .from('profiles')
        .select('id, full_name, role')
        .eq('id', userId)
        .maybeSingle();

    if (row == null) throw ProfileMissingException(userId);
    return Profile.fromRow(row);
  }
}

class SupabaseInspectionsRepository implements InspectionsRepository {
  SupabaseInspectionsRepository(this._client);

  final SupabaseClient _client;

  static const String _columns =
      'id, inspector_id, site_name, site_address, client_name, '
      'inspection_date, status, submitted_at, created_at';

  @override
  Future<Inspection> create(NewInspection draft) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) throw const NotSignedInException();

    final row = await _client
        .from('inspections')
        .insert(draft.toInsert(inspectorId: userId))
        .select(_columns)
        .single();

    return Inspection.fromRow(row);
  }

  @override
  Future<List<Inspection>> listMine() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) throw const NotSignedInException();

    // RLS already restricts this to the caller's rows. The explicit eq() is
    // defence in depth and lets the planner use the
    // (inspector_id, created_at desc) index rather than filtering after the fact.
    final rows = await _client
        .from('inspections')
        .select(_columns)
        .eq('inspector_id', userId)
        .order('created_at', ascending: false);

    return rows.map(Inspection.fromRow).toList(growable: false);
  }
}
