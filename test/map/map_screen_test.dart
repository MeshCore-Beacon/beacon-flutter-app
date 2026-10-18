import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/core/theme.dart';
import 'package:beacon/features/map/map_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(BeaconTheme.load);

  testWidgets('Live Map turns clustering off without touching the saved pref', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'beacon-map-clustering': true,
      'beacon-map-settings-open': true,
    });
    final api = ApiClient(
      Uri.parse('https://beacon.example.com'),
      client: MockClient(
        (r) async => http.Response(
          jsonEncode(
            r.url.path.endsWith('/iatas')
                ? []
                : {'items': [], 'hasMore': false},
          ),
          200,
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: BeaconTheme.all.first.data,
        home: Scaffold(
          body: MapScreen(api: api, region: const {}, onOpen: (_, _) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    ChoiceChip chip(String label) => tester.widget<ChoiceChip>(
      find.descendant(
        of: find
            .ancestor(
              of: find.text('Clustering'),
              matching: find.byType(Column),
            )
            .first,
        matching: find.widgetWithText(ChoiceChip, label),
      ),
    );
    const note = 'Off while Live Map is on';

    expect(chip('On').selected, isTrue);
    expect(chip('On').onSelected, isNotNull);
    expect(find.text(note), findsNothing);

    await tester.tap(find.byTooltip('Play live map packet flow'));
    await tester.pumpAndSettle();
    expect(chip('Off').selected, isTrue);
    expect(chip('On').onSelected, isNull);
    expect(chip('Off').onSelected, isNull);
    expect(find.text(note), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('beacon-map-clustering'), isTrue);

    await tester.tap(find.byTooltip('Stop live map packet flow'));
    await tester.pumpAndSettle();
    expect(chip('On').selected, isTrue);
    expect(chip('On').onSelected, isNotNull);
    expect(find.text(note), findsNothing);
    // With no native view MapLibre never opens its channel, so dispose throws.
    await tester.pumpWidget(const SizedBox());
    expect('${tester.takeException()}', contains('LateInitializationError'));
    api.close();
  });
}
