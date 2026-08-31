import 'dart:io';

import 'package:fieldproof/src/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// The client's length limits are a convenience mirror of the database CHECK
/// constraints. If someone widens one without the other, the user gets a raw
/// Postgres error instead of a readable message — or, worse, a field the UI
/// accepts and the database silently refuses. This test reads the migration and
/// fails on drift, so the two cannot separate unnoticed.
void main() {
  late String sql;

  setUpAll(() {
    final file =
        File('${_repoRoot()}/supabase/migrations/20260831000100_schema.sql');
    expect(
      file.existsSync(),
      isTrue,
      reason: 'schema migration not found at ${file.path}',
    );
    sql = file.readAsStringSync();
  });

  int upperBound(RegExp pattern, String label) {
    final match = pattern.firstMatch(sql);
    expect(match, isNotNull,
        reason: 'no $label constraint found in the migration');
    return int.parse(match!.group(1)!);
  }

  test('site_name limit matches inspections_site_name_len', () {
    expect(
      InspectionLimits.siteNameMax,
      upperBound(
        RegExp(r'char_length\(site_name\)\s+between\s+1\s+and\s+(\d+)'),
        'site_name',
      ),
    );
  });

  test('site_address limit matches inspections_site_address_len', () {
    expect(
      InspectionLimits.siteAddressMax,
      upperBound(
        RegExp(r'char_length\(site_address\)\s*<=\s*(\d+)'),
        'site_address',
      ),
    );
  });

  test('client_name limit matches inspections_client_name_len', () {
    expect(
      InspectionLimits.clientNameMax,
      upperBound(
        RegExp(r'char_length\(client_name\)\s*<=\s*(\d+)'),
        'client_name',
      ),
    );
  });

  test('item title limit matches inspection_items_title_len', () {
    expect(
      ItemLimits.titleMax,
      upperBound(
        RegExp(r'char_length\(title\)\s+between\s+1\s+and\s+(\d+)'),
        'item title',
      ),
    );
  });

  test('item description limit matches inspection_items_description_len', () {
    expect(
      ItemLimits.descriptionMax,
      upperBound(
        RegExp(r'char_length\(description\)\s*<=\s*(\d+)'),
        'item description',
      ),
    );
  });

  test('item area limit matches inspection_items_area_len', () {
    expect(
      ItemLimits.areaMax,
      upperBound(RegExp(r'char_length\(area\)\s*<=\s*(\d+)'), 'item area'),
    );
  });

  test('severity and punch-status enums match the schema declarations', () {
    Set<String> declared(String typeName) {
      final m = RegExp(
        'create type public\\.$typeName\\s+as enum \\(([^)]*)\\)',
      ).firstMatch(sql);
      expect(m, isNotNull, reason: 'no $typeName enum found');
      return RegExp("'([a-z_]+)'")
          .allMatches(m!.group(1)!)
          .map((x) => x.group(1)!)
          .toSet();
    }

    expect(
      declared('item_severity'),
      ItemSeverity.values.map((v) => v.wire).toSet(),
    );
    expect(
      declared('item_status'),
      ItemStatus.values.map((v) => v.wire).toSet(),
    );
  });

  test('the enum the client models matches the one the schema declares', () {
    final match = RegExp(
      r"create type public\.inspection_status\s+as enum \(([^)]*)\)",
    ).firstMatch(sql);
    expect(match, isNotNull);
    final declared = RegExp("'([a-z_]+)'")
        .allMatches(match!.group(1)!)
        .map((m) => m.group(1))
        .toSet();
    expect(declared, InspectionStatus.values.map((v) => v.wire).toSet());
  });
}

/// Walks up until the directory containing supabase/ is found, so the test works
/// whether it runs from apps/mobile or the repository root.
String _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (Directory('${dir.path}/supabase/migrations').existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail('could not locate the repository root from ${Directory.current.path}');
}
