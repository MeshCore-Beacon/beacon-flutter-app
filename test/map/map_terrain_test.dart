import 'package:beacon/core/theme.dart';
import 'package:beacon/features/map/map_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'map_screen_test.dart' show chip, pumpMap, unmount;

void main() {
  setUp(BeaconTheme.load);

  // One test: the plugin's failed dispose leaks pointer routes into the next.
  testWidgets('terrain starts off, switches on and is remembered', (
    tester,
  ) async {
    NativeMap map() => tester.widget<NativeMap>(find.byType(NativeMap));
    // The switch recreates the native view; with none in tests its dispose throws.
    void recreated() => expect(
      '${tester.takeException()}',
      contains('LateInitializationError'),
    );
    Finder terrain(String label) => find.descendant(
      of: find
          .ancestor(of: find.text('Terrain'), matching: find.byType(Column))
          .first,
      matching: find.widgetWithText(ChoiceChip, label),
    );

    var api = await pumpMap(tester, {});
    expect(chip(tester, 'Terrain', 'Off').selected, isTrue);
    expect(map().hillshade, isFalse);

    await tester.ensureVisible(terrain('On'));
    await tester.tap(terrain('On'));
    await tester.pumpAndSettle();
    recreated();
    expect(chip(tester, 'Terrain', 'On').selected, isTrue);
    expect(map().hillshade, isTrue);
    final saved = (await SharedPreferences.getInstance()).getBool(
      'beacon-map-terrain',
    );
    expect(saved, isTrue);
    await unmount(tester, api);

    api = await pumpMap(tester, {'beacon-map-terrain': saved!});
    recreated();
    expect(chip(tester, 'Terrain', 'On').selected, isTrue);
    expect(map().hillshade, isTrue);
    await unmount(tester, api);
  });
}
