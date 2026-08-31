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

// ---------------------------------------------------------------- punch items

/// Severity as the accepted schema defines it (`item_severity`).
///
/// The Figma mockup shows `minor | major | critical`. The schema wins (D14): the
/// mockup's palette is adapted to these four values in the UI, rather than the
/// database being migrated to match a picture.
enum ItemSeverity {
  low,
  medium,
  high,
  critical;

  static ItemSeverity fromWire(String value) => switch (value) {
        'low' => ItemSeverity.low,
        'medium' => ItemSeverity.medium,
        'high' => ItemSeverity.high,
        'critical' => ItemSeverity.critical,
        _ =>
          throw ArgumentError.value(value, 'severity', 'unknown item severity'),
      };

  String get wire => name;

  String get label => switch (this) {
        ItemSeverity.low => 'Low',
        ItemSeverity.medium => 'Medium',
        ItemSeverity.high => 'High',
        ItemSeverity.critical => 'Critical',
      };
}

/// Punch status as the accepted schema defines it (`item_status`).
///
/// The mockup also has `in-review`; the schema has two values and wins (D14).
/// Unlike `inspections.status`, this transition is *not* one-way — no trigger
/// constrains it — so resolve and reopen are both supported.
enum ItemStatus {
  open,
  resolved;

  static ItemStatus fromWire(String value) => switch (value) {
        'open' => ItemStatus.open,
        'resolved' => ItemStatus.resolved,
        _ => throw ArgumentError.value(value, 'status', 'unknown item status'),
      };

  String get wire => name;

  bool get isResolved => this == ItemStatus.resolved;
}

class InspectionItem {
  const InspectionItem({
    required this.id,
    required this.inspectionId,
    required this.sortOrder,
    required this.title,
    required this.severity,
    required this.status,
    this.description,
    this.area,
    this.createdAt,
  });

  final String id;
  final String inspectionId;
  final int sortOrder;
  final String title;
  final String? description;
  final String? area;
  final ItemSeverity severity;
  final ItemStatus status;
  final DateTime? createdAt;

  factory InspectionItem.fromRow(Map<String, dynamic> row) => InspectionItem(
        id: row['id'] as String,
        inspectionId: row['inspection_id'] as String,
        sortOrder: row['sort_order'] as int,
        title: row['title'] as String,
        description: row['description'] as String?,
        area: row['area'] as String?,
        severity: ItemSeverity.fromWire(row['severity'] as String),
        status: ItemStatus.fromWire(row['status'] as String),
        createdAt: row['created_at'] == null
            ? null
            : DateTime.parse(row['created_at'] as String),
      );
}

/// A not-yet-persisted punch item.
class NewInspectionItem {
  const NewInspectionItem({
    required this.title,
    this.description,
    this.area,
    this.severity = ItemSeverity.medium,
  });

  final String title;
  final String? description;
  final String? area;
  final ItemSeverity severity;

  /// The insert payload.
  ///
  /// `inspection_id` is supplied by the repository, never by the caller, so a
  /// client cannot express an item under someone else's inspection. RLS would
  /// refuse it anyway; this makes it unrepresentable a layer earlier — the same
  /// rule `NewInspection` follows for `inspector_id`.
  ///
  /// `status` is omitted so the column default ('open') applies.
  Map<String, dynamic> toInsert({
    required String inspectionId,
    required int sortOrder,
  }) =>
      {
        'inspection_id': inspectionId,
        'sort_order': sortOrder,
        'title': title.trim(),
        'description': nullIfBlank(description),
        'area': nullIfBlank(area),
        'severity': severity.wire,
      };

  /// Public because updates apply the same blank-to-null rule as inserts.
  static String? nullIfBlank(String? v) {
    final trimmed = v?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }
}

/// Client-side mirrors of the `inspection_items` CHECK constraints.
class ItemLimits {
  const ItemLimits._();

  static const int titleMax = 200;
  static const int descriptionMax = 4000;
  static const int areaMax = 120;

  static String? validateTitle(String? value) {
    final v = (value ?? '').trim();
    if (v.isEmpty) return 'Title is required.';
    if (v.length > titleMax) {
      return 'Title must be $titleMax characters or fewer.';
    }
    return null;
  }

  static String? validateDescription(String? value) {
    final v = (value ?? '').trim();
    if (v.length > descriptionMax) {
      return 'Description must be $descriptionMax characters or fewer.';
    }
    return null;
  }

  static String? validateArea(String? value) {
    final v = (value ?? '').trim();
    if (v.length > areaMax) {
      return 'Area must be $areaMax characters or fewer.';
    }
    return null;
  }

  static bool isValid(NewInspectionItem draft) =>
      validateTitle(draft.title) == null &&
      validateDescription(draft.description) == null &&
      validateArea(draft.area) == null;
}

// ---------------------------------------------------------------- photos

/// A photo that has been persisted: a Storage object plus its metadata row.
class ItemPhoto {
  const ItemPhoto({
    required this.id,
    required this.itemId,
    required this.inspectionId,
    required this.storagePath,
    required this.contentType,
    required this.byteSize,
    this.caption,
    this.createdAt,
  });

  final String id;
  final String itemId;
  final String inspectionId;
  final String storagePath;
  final String contentType;
  final int byteSize;
  final String? caption;
  final DateTime? createdAt;

  factory ItemPhoto.fromRow(Map<String, dynamic> row) => ItemPhoto(
        id: row['id'] as String,
        itemId: row['item_id'] as String,
        inspectionId: row['inspection_id'] as String,
        storagePath: row['storage_path'] as String,
        contentType: row['content_type'] as String,
        byteSize: (row['byte_size'] as num).toInt(),
        caption: row['caption'] as String?,
        createdAt: row['created_at'] == null
            ? null
            : DateTime.parse(row['created_at'] as String),
      );
}

/// Bytes handed back by a [PhotoSource], before anything has been uploaded.
class CapturedPhoto {
  const CapturedPhoto({
    required this.bytes,
    required this.contentType,
  });

  final List<int> bytes;
  final String contentType;

  int get byteSize => bytes.length;

  /// Extension implied by the content type. Derived, never taken from the
  /// filename a picker reports — a caller-supplied name must not decide where
  /// the object lands.
  String get extension => switch (contentType) {
        'image/jpeg' => 'jpg',
        'image/png' => 'png',
        'image/webp' => 'webp',
        _ =>
          throw ArgumentError.value(contentType, 'contentType', 'unsupported'),
      };
}

/// Mirrors the `item_photos` CHECK constraints, and the bucket's own limits.
class PhotoLimits {
  const PhotoLimits._();

  static const int maxBytes = 10485760; // 10 MB
  static const Set<String> allowedContentTypes = {
    'image/jpeg',
    'image/png',
    'image/webp',
  };

  static String? validate(CapturedPhoto photo) {
    if (!allowedContentTypes.contains(photo.contentType)) {
      return 'Only JPEG, PNG and WebP images can be attached.';
    }
    if (photo.byteSize <= 0) return 'That image appears to be empty.';
    if (photo.byteSize > maxBytes) {
      return 'Images must be 10 MB or smaller.';
    }
    return null;
  }

  /// The one place a Storage path is constructed.
  ///
  /// `inspectorId` is the *authenticated* uid, supplied by the repository from
  /// the live session — never by a caller. Storage policy compares path segment
  /// [1] against `auth.uid()`, so a forged owner segment cannot be written; this
  /// keeps the app from even forming one.
  ///
  /// Deterministic on purpose: given the metadata row, the object path is
  /// recomputable, so cleanup and retry need no extra bookkeeping.
  static String storagePath({
    required String inspectorId,
    required String inspectionId,
    required String itemId,
    required String photoId,
    required String extension,
  }) =>
      '$inspectorId/$inspectionId/$itemId/$photoId.$extension';
}
