import 'package:fieldproof/src/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NewInspection.toInsert', () {
    final draft = NewInspection(
      siteName: '  Harbour View  ',
      siteAddress: '  12 Dock Road ',
      clientName: '   ',
      inspectionDate: DateTime(2026, 8, 20, 13, 45),
    );

    test('takes inspector_id from the caller-supplied session id', () {
      final payload = draft.toInsert(inspectorId: 'session-user', id: 'insp-1');
      expect(payload['inspector_id'], 'session-user');
    });

    test('trims text and nulls out blank optional fields', () {
      final payload = draft.toInsert(inspectorId: 'u', id: 'insp-1');
      expect(payload['site_name'], 'Harbour View');
      expect(payload['site_address'], '12 Dock Road');
      expect(payload['client_name'], isNull);
    });

    test('sends a date, not a timestamp, for the date column', () {
      final payload = draft.toInsert(inspectorId: 'u', id: 'insp-1');
      expect(payload['inspection_date'], '2026-08-20');
    });

    test('omits status and submitted_at so the column defaults apply', () {
      final payload = draft.toInsert(inspectorId: 'u', id: 'insp-1');
      expect(payload.containsKey('status'), isFalse);
      expect(payload.containsKey('submitted_at'), isFalse);
    });

    test('carries the device-generated id, which is what makes sync idempotent',
        () {
      // D5 calls inspections.id "the idempotency key for first sync". Until the
      // offline slice the client omitted it and let gen_random_uuid() apply, so
      // a retried write was indistinguishable from a new one.
      final payload = draft.toInsert(inspectorId: 'u', id: 'insp-1');
      expect(payload['id'], 'insp-1');
    });

    test('payload carries no key beyond the six the schema defines', () {
      expect(
        draft.toInsert(inspectorId: 'u', id: 'insp-1').keys.toSet(),
        {
          'id',
          'inspector_id',
          'site_name',
          'site_address',
          'client_name',
          'inspection_date',
        },
      );
    });
  });

  group('Inspection.fromRow', () {
    test('parses a draft row', () {
      final row = <String, dynamic>{
        'id': 'i1',
        'inspector_id': 'u1',
        'site_name': 'Harbour View',
        'site_address': null,
        'client_name': null,
        'inspection_date': '2026-08-20',
        'status': 'draft',
        'submitted_at': null,
        'created_at': '2026-08-20T10:00:00Z',
      };
      final inspection = Inspection.fromRow(row);
      expect(inspection.status, InspectionStatus.draft);
      expect(inspection.siteName, 'Harbour View');
      expect(inspection.submittedAt, isNull);
    });

    test('rejects a status the schema does not define', () {
      final row = <String, dynamic>{
        'id': 'i1',
        'inspector_id': 'u1',
        'site_name': 'X',
        'inspection_date': '2026-08-20',
        'status': 'archived',
      };
      expect(() => Inspection.fromRow(row), throwsArgumentError);
    });
  });
}
