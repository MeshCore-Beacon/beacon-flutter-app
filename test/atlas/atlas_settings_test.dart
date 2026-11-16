import 'dart:convert';

import 'package:beacon/core/instance.dart';
import 'package:beacon/core/preferences.dart';
import 'package:beacon/core/theme.dart';
import 'package:beacon/features/atlas/atlas.dart';
import 'package:beacon/features/atlas/atlas_settings.dart';
import 'package:beacon/features/settings/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const server = 'https://test.invalid';
Map<String, dynamic> pin(int n) => {
  'kind': 'node',
  'id': '11111111-1111-4111-8111-${'$n'.padLeft(12, '0')}',
  'publicKey': n.toRadixString(16).padLeft(2, '0') * 32,
  'name': 'Node $n',
};
String file(List<dynamic> pins) => jsonEncode({
  'format': 'beacon-atlas',
  'version': 2,
  'exportedAt': 1,
  'range': '3d',
  'pins': pins,
});

class FakeFiles implements AtlasFiles {
  String? picked;
  (String, String)? saved;
  bool accept = true;
  @override
  Future<String?> pick() async => picked;
  @override
  Future<bool> save(String name, String text) async {
    if (accept) saved = (name, text);
    return accept;
  }
}

Future<Preferences> open(
  WidgetTester tester,
  FakeFiles files, {
  List<Map<String, dynamic>> pins = const [],
}) async {
  SharedPreferences.setMockInitialValues({
    'beacon.servers': jsonEncode([
      {'name': 'Home mesh', 'url': server},
    ]),
    'beacon.active': server,
    if (pins.isNotEmpty)
      'beacon.atlas.$server': jsonEncode({
        'version': 2,
        'range': '24h',
        'pins': pins,
      }),
  });
  final prefs = await Preferences.load();
  await tester.pumpWidget(
    MaterialApp(
      theme: BeaconTheme.all.first.data,
      home: SettingsPage(
        preferences: prefs,
        appVersion: () async => '2.1.1',
        atlasFiles: files,
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.byKey(const ValueKey('atlas-import')),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  return prefs;
}

List<String> names(Preferences prefs) => [
  for (final pin in parseAtlas(prefs.atlasFor(server)).pins) pin.name,
];

void main() {
  setUp(BeaconTheme.load);

  testWidgets('exports the active server cards as an Atlas file', (
    tester,
  ) async {
    final files = FakeFiles();
    await open(tester, files, pins: [pin(1), pin(2)]);
    expect(find.text('Cards saved for Home mesh'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('atlas-export')));
    await tester.pumpAndSettle();
    expect(files.saved!.$1, matches(r'^beacon-atlas-\d{4}-\d\d-\d\d\.json$'));
    final read = readAtlasFile(files.saved!.$2)!;
    expect([for (final pin in read.atlas.pins) pin.name], ['Node 1', 'Node 2']);
    expect(find.text('Atlas exported.'), findsOneWidget);
  });

  testWidgets('export is off with no cards and silent when backed out of', (
    tester,
  ) async {
    final files = FakeFiles();
    await open(tester, files);
    await tester.tap(find.byKey(const ValueKey('atlas-export')));
    await tester.pumpAndSettle();
    expect(files.saved, isNull);
    expect(find.text('Atlas exported.'), findsNothing);
  });

  testWidgets('imports straight into an empty Atlas and counts the skipped', (
    tester,
  ) async {
    final files = FakeFiles()
      ..picked = file([
        pin(1),
        pin(1),
        {'kind': 'node'},
        pin(2),
      ]);
    final prefs = await open(tester, files);
    await tester.tap(find.byKey(const ValueKey('atlas-import')));
    await tester.pumpAndSettle();
    expect(names(prefs), ['Node 1', 'Node 2']);
    expect(parseAtlas(prefs.atlasFor(server)).range, AtlasRange.threeDays);
    expect(
      find.text(
        'Imported 2 cards. 2 entries skipped (duplicate, invalid or over the limit).',
      ),
      findsOneWidget,
    );
  });

  testWidgets('asks before replacing saved cards', (tester) async {
    final files = FakeFiles()..picked = file([pin(7), pin(8), pin(9)]);
    final prefs = await open(tester, files, pins: [pin(1)]);
    await tester.tap(find.byKey(const ValueKey('atlas-import')));
    await tester.pumpAndSettle();
    expect(
      find.text('Replace your 1 saved card with the 3 in this file?'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(names(prefs), ['Node 1']);

    await tester.tap(find.byKey(const ValueKey('atlas-import')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Replace'));
    await tester.pumpAndSettle();
    expect(names(prefs), ['Node 7', 'Node 8', 'Node 9']);
    expect(find.text('Imported 3 cards.'), findsOneWidget);
  });

  testWidgets('rejects a file that is not an Atlas export', (tester) async {
    final files = FakeFiles();
    final prefs = await open(tester, files, pins: [pin(1)]);
    for (final bad in ['{"pins":[]}', '', file([]), 'x' * 300000]) {
      files.picked = bad;
      await tester.tap(find.byKey(const ValueKey('atlas-import')));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'That file is not a Beacon Atlas export, or has no cards that can be imported.',
        ),
        findsOneWidget,
      );
      expect(names(prefs), ['Node 1']);
    }
  });

  test(
    'a removed server takes its Atlas with it; an edited one keeps it',
    () async {
      SharedPreferences.setMockInitialValues({
        'beacon.servers': jsonEncode([
          {'name': 'Home mesh', 'url': server},
        ]),
        'beacon.atlas.$server': 'cards',
      });
      final prefs = await Preferences.load();
      const moved = 'https://moved.invalid';
      await prefs.saveServer(
        BeaconInstance.create('Home mesh', moved),
        replacing: server,
      );
      expect(prefs.atlasFor(moved), 'cards');
      expect(prefs.atlasFor(server), isNull);
      await prefs.removeServer(moved);
      expect(prefs.atlasFor(moved), isNull);
    },
  );
}
