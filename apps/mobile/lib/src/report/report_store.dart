/// Where one rendering of the report goes once the inspection is submitted
/// (D21 amended, D31).
///
/// A port for the reason PhotoObjectStore is one (D19): the failure after the
/// submit succeeded is the part most likely to be wrong, and a widget test that
/// cannot force it proves nothing. One production implementation
/// (`SupabaseReportStore`, in supabase_repositories.dart), one fake.
/// Deliberately no remove(): the app cannot even express the delete the bucket
/// refuses.
library;

import 'dart:typed_data';

abstract interface class ReportStore {
  /// Uploads [bytes] at [path], once. An object already at [path] is the goal
  /// state — the bucket is write-once — so "already there" completes rather
  /// than fails.
  Future<void> put(String path, Uint8List bytes);

  /// Inspection ids under the caller's own folder that hold a report: a
  /// listing of `{inspectorId}/`, read through the owner SELECT policy. A folder
  /// in a listing is a fact derived from the objects beneath it, and the only
  /// object a client can write beneath it is report.pdf (hosted smoke 22a pins
  /// that the listing reflects the object).
  ///
  /// The whole folder, or a throw — never a page of it: an id left off a
  /// truncated listing would read as "not uploaded", which is a claim (D28).
  /// The production store pages to a short page; the fake has no pages.
  Future<Set<String>> published(String inspectorId);
}

/// `{inspector_id}/{inspection_id}/report.pdf` — the ONE name the INSERT policy
/// in 20260905001100_inspection_reports.sql admits. Must agree with that SQL
/// literal and with reportStoragePath() in apps/admin/src/lib/data/repository.ts;
/// pgTAP 110 pins the SQL side, report_store_test.dart this side, hosted smoke
/// 22a proves they meet.
///
/// [inspectorId] is the *authenticated* uid, supplied by the service from the
/// live session — never by a caller, and never from an Inspection row
/// (PhotoLimits.storagePath in models.dart follows the same rule).
String reportStoragePath({
  required String inspectorId,
  required String inspectionId,
}) =>
    '$inspectorId/$inspectionId/report.pdf';
