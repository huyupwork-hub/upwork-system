/// Builds a [ReportSnapshot] from the persisted record, once.
///
/// `DB state -> ReportSnapshot -> PDF bytes`. Everything is read here; the
/// renderer never touches the network. That ordering is the whole point: a
/// document assembled from repeated queries could show a header from one moment
/// and a body from another.
library;

import '../data/models.dart';
import '../data/repositories.dart';
import 'report_snapshot.dart';

class ReportLoader {
  ReportLoader({
    required InspectionItemsRepository items,
    required PhotosRepository photos,
    required ProfileRepository profiles,
    DateTime Function() now = DateTime.now,
  }) : _items = items,
       _photos = photos,
       _profiles = profiles,
       _now = now;

  final InspectionItemsRepository _items;
  final PhotosRepository _photos;
  final ProfileRepository _profiles;
  final DateTime Function() _now;

  /// Loads everything the report needs.
  ///
  /// Throws [InspectionNotSubmittedException] for a draft. Generation never
  /// submits as a side effect — asking to see a report must not be the act that
  /// makes an inspection permanent.
  Future<ReportSnapshot> load(Inspection inspection) async {
    if (inspection.status != InspectionStatus.submitted) {
      throw const InspectionNotSubmittedException();
    }

    final inspector = await _profiles.loadCurrent();
    final items = await _items.listFor(inspection.id);

    // Deterministic: sort_order, then created_at, then id. The last key is what
    // makes two runs over the same data produce the same document even when the
    // first two tie.
    final ordered = [...items]..sort(_compareItems);

    final reportItems = <ReportItem>[];
    for (final item in ordered) {
      final photos = await _photos.listFor(item.id);
      final orderedPhotos = [...photos]..sort(_comparePhotos);

      final loaded = <ReportPhoto>[];
      for (final photo in orderedPhotos) {
        try {
          loaded.add(ReportPhoto.available(photo, await _photos.bytes(photo)));
        } catch (e) {
          // Recorded, not dropped. A missing photo the report stays silent about
          // reads as "there was no photo", which is a different claim.
          loaded.add(ReportPhoto.unavailable(photo, e.toString()));
        }
      }
      reportItems.add(ReportItem(item: item, photos: loaded));
    }

    return ReportSnapshot(
      inspection: inspection,
      inspector: inspector,
      items: reportItems,
      generatedAt: _now(),
    );
  }

  static int _compareItems(InspectionItem a, InspectionItem b) {
    final byOrder = a.sortOrder.compareTo(b.sortOrder);
    if (byOrder != 0) return byOrder;
    final byCreated = _compareNullableDates(a.createdAt, b.createdAt);
    if (byCreated != 0) return byCreated;
    return a.id.compareTo(b.id);
  }

  static int _comparePhotos(ItemPhoto a, ItemPhoto b) {
    final byCreated = _compareNullableDates(a.createdAt, b.createdAt);
    if (byCreated != 0) return byCreated;
    return a.id.compareTo(b.id);
  }

  /// Rows without a timestamp sort last, so a null never reorders the rest.
  static int _compareNullableDates(DateTime? a, DateTime? b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    return a.compareTo(b);
  }
}
