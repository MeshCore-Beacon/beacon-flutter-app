import 'dart:async';
import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/core/strings.dart';
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
  // maplibre_gl 0.28 disposes cleanly without a native view.
  await tester.pumpWidget(const SizedBox());
  expect(tester.takeException(), isNull);
  api.close();
}

void main() {
  setUp(BeaconTheme.load);
  pollerTests();

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

// Evaluates just the expression forms _nodeIcon uses.
Object? evalIcon(Object? e, Map<String, Object?> props) {
  if (e is! List) return e;
  switch (e.first) {
    case 'concat':
      return e.skip(1).map((x) => evalIcon(x, props)).join();
    case 'get':
      return props[e[1]];
    case 'case':
      for (var i = 1; i + 1 < e.length; i += 2) {
        if (evalIcon(e[i], props) == true) return evalIcon(e[i + 1], props);
      }
      return evalIcon(e.last, props);
    case '==':
      return evalIcon(e[1], props) == evalIcon(e[2], props);
  }
  throw StateError('unsupported $e');
}

void pollerTests() {
  testWidgets('the Pollers only options come from the locale strings', (
    tester,
  ) async {
    addTearDown(() => language = 'en');
    for (final (lang, on, off) in [
      ('fr', 'Activé', 'Désactivé'),
      ('sv', 'På', 'Av'),
    ]) {
      language = lang;
      final api = await pumpMap(tester, {});
      final group = find
          .ancestor(
            of: find.text(trKey('map.pollersOnly')),
            matching: find.byType(Column),
          )
          .first;
      for (final label in [on, off]) {
        expect(
          find.descendant(of: group, matching: find.text(label)),
          findsOneWidget,
          reason: '$lang $label',
        );
      }
      await unmount(tester, api);
    }
  });
  test('the node icon expression prefers the poller pip over the eye', () {
    String icon(bool poller, bool observer) =>
        '${evalIcon(nodeIconExpression, {'nodeTypeName': 'repeater', 'isPoller': poller, 'isObserver': observer})}';
    expect(icon(true, true), 'node-repeater-poller');
    expect(icon(true, false), 'node-repeater-poller');
    expect(icon(false, true), 'node-repeater-observer');
    expect(icon(false, false), 'node-repeater');
  });
  testWidgets('Pollers only filters the loaded points with the type filter', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'beacon-map-settings-open': true});
    final api = ApiClient(
      Uri.parse('https://beacon.example.com'),
      client: MockClient((r) async {
        if (r.url.path.endsWith('/iatas')) return http.Response('[]', 200);
        return http.Response(
          jsonEncode({
            'items': [
              {
                'id': 'rp',
                'nodeTypeName': 'repeater',
                'isPoller': true,
                'lat': 43,
                'lng': -79,
              },
              {
                'id': 'r',
                'nodeTypeName': 'repeater',
                'isObserver': true,
                'lat': 44,
                'lng': -80,
              },
              {
                'id': 'cp',
                'nodeTypeName': 'companion',
                'isPoller': true,
                'lat': 45,
                'lng': -81,
              },
            ],
            'hasMore': false,
          }),
          200,
        );
      }),
    );
    final events = StreamController<Map<String, dynamic>>.broadcast();
    await tester.pumpWidget(
      MaterialApp(
        theme: BeaconTheme.all.first.data,
        home: Scaffold(
          body: MapScreen(
            api: api,
            region: const {},
            events: events.stream,
            onOpen: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Future<void> pick(String group, String label) async {
      final target = find.descendant(
        of: find
            .ancestor(of: find.text(group), matching: find.byType(Column))
            .first,
        matching: find.widgetWithText(ChoiceChip, label),
      );
      await tester.ensureVisible(target);
      await tester.tap(target);
    }

    List ids() => [
      for (final f
          in tester.widget<NativeMap>(find.byType(NativeMap)).points['features']
              as List)
        f['id'],
    ];
    expect(ids(), ['rp', 'r', 'cp']);

    await pick('Pollers only', 'On');
    await tester.pumpAndSettle();
    expect(ids(), ['rp', 'cp']);

    await pick('Node Type', 'Repeater');
    await tester.pumpAndSettle();
    expect(ids(), ['rp']);

    // A live update that flips a poller updates the filtered points.
    events.add({
      'type': 'event',
      'event': 'nodeUpdate',
      'data': {'nodeId': 'r', 'isPoller': true},
    });
    await tester.pumpAndSettle();
    expect(ids(), ['rp', 'r']);
    await events.close();
    await unmount(tester, api);
  });
}
