import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/core/theme.dart';
import 'package:beacon/features/map/map_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<ApiClient> pumpMap(
  WidgetTester tester,
  Map<String, Object> prefs,
) async {
  SharedPreferences.setMockInitialValues({
    'beacon-map-settings-open': true,
    ...prefs,
  });
  final api = ApiClient(
    Uri.parse('https://beacon.example.com'),
    client: MockClient(
      (r) async => http.Response(
        jsonEncode(
          r.url.path.endsWith('/iatas') ? [] : {'items': [], 'hasMore': false},
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
  return api;
}

ChoiceChip chip(WidgetTester tester, String group, String label) =>
    tester.widget<ChoiceChip>(
      find.descendant(
        of: find
            .ancestor(of: find.text(group), matching: find.byType(Column))
            .first,
        matching: find.widgetWithText(ChoiceChip, label),
      ),
    );

Future<void> toggleLive(WidgetTester tester, {required bool on}) async {
  await tester.tap(
    find.byTooltip(
      on ? 'Play live map packet flow' : 'Stop live map packet flow',
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> unmount(WidgetTester tester, ApiClient api) async {
  // With no native view MapLibre never opens its channel, so dispose throws.
  await tester.pumpWidget(const SizedBox());
  expect('${tester.takeException()}', contains('LateInitializationError'));
  api.close();
}

void main() {
  setUp(BeaconTheme.load);

  // One test: the plugin's failed dispose leaks pointer routes into the next.
  testWidgets(
    'Live Map overrides clustering and all-node lines, saved prefs kept',
    (tester) async {
      final api = await pumpMap(tester, {
        'beacon-map-clustering': true,
        'beacon-map-neighbors': 'on',
      });
      ChoiceChip clustering(String label) => chip(tester, 'Clustering', label);
      ChoiceChip lines(String label) => chip(tester, 'Neighbor Lines', label);
      const clusteringNote = 'Off while Live Map is on';
      const linesNote = 'All lines are off while Live Map is on';

      expect(clustering('On').selected, isTrue);
      expect(clustering('On').onSelected, isNotNull);
      expect(lines('On').selected, isTrue);
      expect(lines('On').onSelected, isNotNull);
      expect(find.text(clusteringNote), findsNothing);
      expect(find.text(linesNote), findsNothing);

      await toggleLive(tester, on: true);
      expect(clustering('Off').selected, isTrue);
      expect(clustering('On').onSelected, isNull);
      expect(clustering('Off').onSelected, isNull);
      expect(find.text(clusteringNote), findsOneWidget);
      expect(lines('Selected').selected, isTrue);
      expect(lines('On').onSelected, isNull);
      expect(lines('Selected').onSelected, isNotNull);
      expect(lines('Off').onSelected, isNotNull);
      expect(find.text(linesNote), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('beacon-map-clustering'), isTrue);
      expect(prefs.getString('beacon-map-neighbors'), 'on');

      await toggleLive(tester, on: false);
      expect(clustering('On').selected, isTrue);
      expect(clustering('On').onSelected, isNotNull);
      expect(lines('On').selected, isTrue);
      expect(lines('On').onSelected, isNotNull);
      expect(find.text(clusteringNote), findsNothing);
      expect(find.text(linesNote), findsNothing);
      await unmount(tester, api);
    },
  );
}
