import 'dart:async';

import 'package:fieldproof/src/data/models.dart';
import 'package:fieldproof/src/data/repositories.dart';

/// In-memory stand-ins. They model the *client* contract only. Access control is
/// the database's job and is proven by the pgTAP suite in supabase/tests — these
/// fakes deliberately do not re-implement RLS, because a fake that enforced it
/// would prove nothing about the real policies.
class FakeAuthRepository implements AuthRepository {
  FakeAuthRepository({String? initialUserId}) : _userId = initialUserId;

  final _controller = StreamController<String?>.broadcast();
  String? _userId;

  /// Credentials this fake will accept.
  final Map<String, String> accounts = {'a@example.com': 'correct-horse'};

  /// Set to make signIn throw, to exercise error rendering.
  Object? failWith;

  int signOutCount = 0;

  @override
  Stream<String?> get userIdChanges => _controller.stream;

  @override
  String? get currentUserId => _userId;

  @override
  Future<void> signIn({required String email, required String password}) async {
    if (failWith != null) throw failWith!;
    if (accounts[email] != password) {
      throw Exception('Invalid login credentials');
    }
    _userId = 'user-${email.hashCode}';
    _controller.add(_userId);
  }

  @override
  Future<void> signOut() async {
    signOutCount++;
    _userId = null;
    _controller.add(null);
  }

  Future<void> dispose() => _controller.close();
}

class FakeProfileRepository implements ProfileRepository {
  FakeProfileRepository({this.profile, this.throwMissing = false});

  Profile? profile;
  bool throwMissing;

  @override
  Future<Profile> loadCurrent() async {
    if (throwMissing) throw const ProfileMissingException('user-1');
    return profile ??
        const Profile(id: 'user-1', fullName: 'Inspector Alpha', role: 'inspector');
  }
}

class FakeInspectionsRepository implements InspectionsRepository {
  FakeInspectionsRepository({List<Inspection>? initial, this.sessionUserId = 'user-1'})
      : rows = [...?initial];

  final List<Inspection> rows;
  final String sessionUserId;

  /// Every insert payload this repository was asked to persist.
  final List<Map<String, dynamic>> insertPayloads = [];

  Object? failWith;

  @override
  Future<Inspection> create(NewInspection draft) async {
    if (failWith != null) throw failWith!;

    // Mirrors the production path: the owner comes from the session.
    final payload = draft.toInsert(inspectorId: sessionUserId);
    insertPayloads.add(payload);

    final created = Inspection(
      id: 'inspection-${rows.length + 1}',
      inspectorId: payload['inspector_id'] as String,
      siteName: payload['site_name'] as String,
      siteAddress: payload['site_address'] as String?,
      clientName: payload['client_name'] as String?,
      inspectionDate: DateTime.parse(payload['inspection_date'] as String),
      status: InspectionStatus.draft,
    );
    rows.insert(0, created);
    return created;
  }

  @override
  Future<List<Inspection>> listMine() async => List.unmodifiable(rows);
}
