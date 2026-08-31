import 'package:fieldproof/src/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  NewInspection draft(
          {String site = 'Harbour View', String? address, String? client}) =>
      NewInspection(
        siteName: site,
        siteAddress: address,
        clientName: client,
        inspectionDate: DateTime(2026, 8, 20),
      );

  test('site name is required', () {
    expect(InspectionLimits.validateSiteName(''), isNotNull);
    expect(InspectionLimits.validateSiteName('   '), isNotNull);
    expect(InspectionLimits.validateSiteName('Harbour View'), isNull);
  });

  test('optional fields accept null and blank', () {
    expect(InspectionLimits.validateSiteAddress(null), isNull);
    expect(InspectionLimits.validateClientName('  '), isNull);
  });

  test('limits are enforced at the boundary, not one past it', () {
    expect(
      InspectionLimits.validateSiteName('x' * InspectionLimits.siteNameMax),
      isNull,
    );
    expect(
      InspectionLimits.validateSiteName(
          'x' * (InspectionLimits.siteNameMax + 1)),
      isNotNull,
    );
    expect(
      InspectionLimits.validateSiteAddress(
          'x' * InspectionLimits.siteAddressMax),
      isNull,
    );
    expect(
      InspectionLimits.validateSiteAddress(
        'x' * (InspectionLimits.siteAddressMax + 1),
      ),
      isNotNull,
    );
  });

  test('whitespace does not smuggle a value past the required check', () {
    expect(InspectionLimits.isValid(draft(site: '   ')), isFalse);
  });

  test('a well-formed draft validates', () {
    expect(
      InspectionLimits.isValid(
          draft(address: '12 Dock Road', client: 'Meridian')),
      isTrue,
    );
  });
}
