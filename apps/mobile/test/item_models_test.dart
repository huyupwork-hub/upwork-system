import 'package:fieldproof/src/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('enums match the accepted schema, not the mockup', () {
    test('severity has the four schema values', () {
      expect(ItemSeverity.values.map((s) => s.wire).toList(), [
        'low',
        'medium',
        'high',
        'critical',
      ]);
    });

    test('severity rejects the Figma vocabulary', () {
      // The mockup uses minor | major | critical. Accepting those silently
      // would let a mismatched row through instead of failing loudly (D14).
      expect(() => ItemSeverity.fromWire('minor'), throwsArgumentError);
      expect(() => ItemSeverity.fromWire('major'), throwsArgumentError);
    });

    test('punch status has exactly open and resolved', () {
      expect(ItemStatus.values.map((s) => s.wire).toList(), [
        'open',
        'resolved',
      ]);
      expect(() => ItemStatus.fromWire('in-review'), throwsArgumentError);
    });
  });

  group('NewInspectionItem.toInsert', () {
    const draft = NewInspectionItem(
      title: '  Cracked pane  ',
      description: '  Hairline crack ',
      area: '   ',
      severity: ItemSeverity.high,
    );

    test('parent comes from the caller, never from the draft', () {
      final payload = draft.toInsert(inspectionId: 'insp-1', sortOrder: 3);
      expect(payload['inspection_id'], 'insp-1');
      expect(payload['sort_order'], 3);
    });

    test('trims text and nulls out blank optional fields', () {
      final payload = draft.toInsert(inspectionId: 'i', sortOrder: 0);
      expect(payload['title'], 'Cracked pane');
      expect(payload['description'], 'Hairline crack');
      expect(payload['area'], isNull);
    });

    test('severity is sent on the wire in schema form', () {
      final payload = draft.toInsert(inspectionId: 'i', sortOrder: 0);
      expect(payload['severity'], 'high');
    });

    test('status is omitted so the column default applies', () {
      final payload = draft.toInsert(inspectionId: 'i', sortOrder: 0);
      expect(payload.containsKey('status'), isFalse);
    });

    test('payload carries no key beyond the six the schema defines', () {
      // Guards against a Figma field (assignee, template, organisation)
      // reaching the database through this path.
      expect(draft.toInsert(inspectionId: 'i', sortOrder: 0).keys.toSet(), {
        'inspection_id',
        'sort_order',
        'title',
        'description',
        'area',
        'severity',
      });
    });

    test('defaults to medium severity', () {
      const d = NewInspectionItem(title: 'x');
      expect(d.severity, ItemSeverity.medium);
    });
  });

  group('InspectionItem.fromRow', () {
    Map<String, dynamic> row({
      String severity = 'medium',
      String status = 'open',
    }) =>
        {
          'id': 'it1',
          'inspection_id': 'insp1',
          'sort_order': 2,
          'title': 'Exposed wiring',
          'description': null,
          'area': 'Plant room',
          'severity': severity,
          'status': status,
          'created_at': '2026-08-20T10:00:00Z',
        };

    test('parses an open item', () {
      final item = InspectionItem.fromRow(row());
      expect(item.severity, ItemSeverity.medium);
      expect(item.status, ItemStatus.open);
      expect(item.status.isResolved, isFalse);
      expect(item.sortOrder, 2);
      expect(item.area, 'Plant room');
    });

    test('parses a resolved critical item', () {
      final item = InspectionItem.fromRow(
        row(severity: 'critical', status: 'resolved'),
      );
      expect(item.severity, ItemSeverity.critical);
      expect(item.status.isResolved, isTrue);
    });

    test('rejects a severity the schema does not define', () {
      expect(
        () => InspectionItem.fromRow(row(severity: 'major')),
        throwsArgumentError,
      );
    });

    test('rejects a status the schema does not define', () {
      expect(
        () => InspectionItem.fromRow(row(status: 'in-review')),
        throwsArgumentError,
      );
    });
  });

  group('ItemLimits', () {
    test('title is required', () {
      expect(ItemLimits.validateTitle(''), isNotNull);
      expect(ItemLimits.validateTitle('   '), isNotNull);
      expect(ItemLimits.validateTitle('Cracked pane'), isNull);
    });

    test('optional fields accept null and blank', () {
      expect(ItemLimits.validateDescription(null), isNull);
      expect(ItemLimits.validateArea('  '), isNull);
    });

    test('limits are enforced at the boundary, not one past it', () {
      expect(ItemLimits.validateTitle('x' * ItemLimits.titleMax), isNull);
      expect(
        ItemLimits.validateTitle('x' * (ItemLimits.titleMax + 1)),
        isNotNull,
      );
      expect(
        ItemLimits.validateDescription('x' * ItemLimits.descriptionMax),
        isNull,
      );
      expect(
        ItemLimits.validateDescription('x' * (ItemLimits.descriptionMax + 1)),
        isNotNull,
      );
      expect(ItemLimits.validateArea('x' * ItemLimits.areaMax), isNull);
      expect(
        ItemLimits.validateArea('x' * (ItemLimits.areaMax + 1)),
        isNotNull,
      );
    });

    test('whitespace does not smuggle a title past the required check', () {
      expect(
        ItemLimits.isValid(const NewInspectionItem(title: '   ')),
        isFalse,
      );
    });

    test('a well-formed draft validates', () {
      expect(
        ItemLimits.isValid(
          const NewInspectionItem(
            title: 'Fire door does not latch',
            area: 'Corridor B',
            severity: ItemSeverity.high,
          ),
        ),
        isTrue,
      );
    });
  });
}
