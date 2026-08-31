/// Domain models and validation.
///
/// The length limits below mirror the CHECK constraints in
/// supabase/migrations/20260831000100_schema.sql. They exist so the user gets an
/// immediate, readable message instead of a Postgres error — the database remains
/// the authority. `test/constraint_parity_test.dart` reads the migration and fails
/// if the two ever drift apart.
library;

enum InspectionStatus {
  draft,
  submitted;

  static InspectionStatus fromWire(String value) => switch (value) {
        'draft' => InspectionStatus.draft,
        'submitted' => InspectionStatus.submitted,
        _ => throw ArgumentError.value(
            value, 'status', 'unknown inspection status'),
      };

  String get wire => name;
}

class Profile {
  const Profile({required this.id, required this.fullName, required this.role});

  final String id;
  final String fullName;
  final String role;

  bool get isAdmin => role == 'admin';

  factory Profile.fromRow(Map<String, dynamic> row) => Profile(
        id: row['id'] as String,
        fullName: row['full_name'] as String,
        role: row['role'] as String,
      );
}

class Inspection {
  const Inspection({
    required this.id,
    required this.inspectorId,
    required this.siteName,
    required this.inspectionDate,
    required this.status,
    this.siteAddress,
    this.clientName,
    this.submittedAt,
    this.createdAt,
  });

  final String id;
  final String inspectorId;
  final String siteName;
  final String? siteAddress;
  final String? clientName;
  final DateTime inspectionDate;
  final InspectionStatus status;
  final DateTime? submittedAt;
  final DateTime? createdAt;

  factory Inspection.fromRow(Map<String, dynamic> row) => Inspection(
        id: row['id'] as String,
        inspectorId: row['inspector_id'] as String,
        siteName: row['site_name'] as String,
        siteAddress: row['site_address'] as String?,
        clientName: row['client_name'] as String?,
        inspectionDate: DateTime.parse(row['inspection_date'] as String),
        status: InspectionStatus.fromWire(row['status'] as String),
        submittedAt: row['submitted_at'] == null
            ? null
            : DateTime.parse(row['submitted_at'] as String),
        createdAt: row['created_at'] == null
            ? null
            : DateTime.parse(row['created_at'] as String),
      );
}

/// A not-yet-persisted inspection.
class NewInspection {
  const NewInspection({
    required this.siteName,
    required this.inspectionDate,
    this.siteAddress,
    this.clientName,
  });

  final String siteName;
  final String? siteAddress;
  final String? clientName;
  final DateTime inspectionDate;

  /// The insert payload.
  ///
  /// `inspector_id` is supplied by the repository from the live session, never by
  /// the caller, so a client cannot express an insert owned by someone else. The
  /// RLS WITH CHECK would reject it regardless; this makes the attempt
  /// unrepresentable one layer earlier.
  ///
  /// `status` is omitted so the column default ('draft') applies, and
  /// `submitted_at` is omitted so the submitted_at/status CHECK holds by default.
  Map<String, dynamic> toInsert({required String inspectorId}) => {
        'inspector_id': inspectorId,
        'site_name': siteName.trim(),
        'site_address': _nullIfBlank(siteAddress),
        'client_name': _nullIfBlank(clientName),
        'inspection_date': dateOnly(inspectionDate),
      };

  static String? _nullIfBlank(String? v) {
    final trimmed = v?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }

  /// `inspection_date` is a Postgres `date`, so send a date, not a timestamp.
  static String dateOnly(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// Client-side mirrors of the database CHECK constraints.
class InspectionLimits {
  const InspectionLimits._();

  static const int siteNameMax = 200;
  static const int siteAddressMax = 300;
  static const int clientNameMax = 200;

  static String? validateSiteName(String? value) {
    final v = (value ?? '').trim();
    if (v.isEmpty) return 'Site name is required.';
    if (v.length > siteNameMax) {
      return 'Site name must be $siteNameMax characters or fewer.';
    }
    return null;
  }

  static String? validateSiteAddress(String? value) {
    final v = (value ?? '').trim();
    if (v.length > siteAddressMax) {
      return 'Address must be $siteAddressMax characters or fewer.';
    }
    return null;
  }

  static String? validateClientName(String? value) {
    final v = (value ?? '').trim();
    if (v.length > clientNameMax) {
      return 'Client must be $clientNameMax characters or fewer.';
    }
    return null;
  }

  /// True when every field would satisfy the database constraints.
  static bool isValid(NewInspection draft) =>
      validateSiteName(draft.siteName) == null &&
      validateSiteAddress(draft.siteAddress) == null &&
      validateClientName(draft.clientName) == null;
}
