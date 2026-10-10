import 'dart:async';
import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/features/packets/packet_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('packet row expands inline before analyzer navigation', (
    tester,
  ) async {
    final destinations = <String>[];
    final api = ApiClient(
      Uri.parse('https://test.invalid'),
      client: MockClient(
        (r) async => http.Response(
          jsonEncode(
            r.url.path == '/api/v1/packets'
                ? {
                    'items': [
                      {
                        'packetHash': 'abcd1234',
                        'payloadType': 4,
                        'observationCount': 0,
                      },
                    ],
                    'hasMore': false,
                  }
                : {'observations': []},
          ),
          200,
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PacketScreen(
            api: api,
            region: const {},
            onOpen: (k, id) => destinations.add('$k/$id'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('ABCD1234'));
    await tester.pumpAndSettle();
    expect(destinations, isEmpty);
    expect(find.text('Open analyzer'), findsOneWidget);
    await tester.tap(find.text('Open analyzer'));
    expect(destinations, ['packet/abcd1234']);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'multiple scopes use plural server parameter and observer filter is local',
    (tester) async {
      final requests = <Uri>[];
      final api = ApiClient(
        Uri.parse('https://test.invalid'),
        client: MockClient((r) async {
          requests.add(r.url);
          return http.Response(
            jsonEncode(
              r.url.path.endsWith('/scopes')
                  ? ['#bc', '#west']
                  : {
                      'items': [
                        {
                          'packetHash': 'abcd',
                          'payloadType': 4,
                          'latestObserver': {
                            'id': 'o1',
                            'displayName': 'Roof observer',
                          },
                        },
                      ],
                      'hasMore': false,
                    },
            ),
            200,
          );
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PacketScreen(api: api, region: const {}, onOpen: (_, _) {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Filters'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('filter-Observers')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.widgetWithText(CheckboxListTile, 'Roof observer'),
      );
      await tester.tap(find.widgetWithText(CheckboxListTile, 'Roof observer'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('filter-Observers')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('filter-Scope')));
      await tester.pumpAndSettle();
      final before = requests.where((r) => r.path.endsWith('/packets')).length;
      await tester.ensureVisible(find.widgetWithText(CheckboxListTile, '#bc'));
      await tester.tap(find.widgetWithText(CheckboxListTile, '#bc'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.widgetWithText(CheckboxListTile, '#west'),
      );
      await tester.tap(find.widgetWithText(CheckboxListTile, '#west'));
      await tester.pumpAndSettle();
      final last = requests.lastWhere((r) => r.path.endsWith('/packets'));
      expect(last.queryParameters['scopes'], '#bc,#west');
      expect(last.queryParameters.containsKey('scope'), isFalse);
      expect(last.queryParameters.containsKey('observers'), isFalse);
      expect(before, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'live packets obey selected scope and previous observer remains selectable',
    (tester) async {
      final events = StreamController<Map<String, dynamic>>.broadcast();
      final api = ApiClient(
        Uri.parse('https://test.invalid'),
        client: MockClient(
          (r) async => http.Response(
            jsonEncode(
              r.url.path.endsWith('/scopes')
                  ? ['#bc']
                  : {
                      'items': [
                        {
                          'packetHash': 'abcd',
                          'scope': '#bc',
                          'payloadType': 4,
                          'lastHeardAt': 1,
                          'latestObserver': {
                            'id': 'old',
                            'displayName': 'Old observer',
                          },
                        },
                      ],
                      'hasMore': false,
                    },
            ),
            200,
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PacketScreen(
              api: api,
              region: const {},
              events: events.stream,
              onOpen: (_, _) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      events.add({
        'event': 'packetObservation',
        'data': {
          'packetHash': 'abcd',
          'packet': {'payloadType': 4, 'scope': '#bc'},
          'observation': {
            'observerId': 'new',
            'observerName': 'New observer',
            'heardAt': 2,
          },
        },
      });
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Filters'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('filter-Observers')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.widgetWithText(CheckboxListTile, 'Old observer'),
      );
      await tester.tap(find.widgetWithText(CheckboxListTile, 'Old observer'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('filter-Observers')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('filter-Scope')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.widgetWithText(CheckboxListTile, '#bc'));
      await tester.tap(find.widgetWithText(CheckboxListTile, '#bc'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('filter-Scope')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Done'));
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      events.add({
        'event': 'packetObservation',
        'data': {
          'packetHash': 'ffff',
          'packet': {'payloadType': 4, 'scope': '#west'},
          'observation': {'observerId': 'old', 'heardAt': 3},
        },
      });
      await tester.pumpAndSettle();
      expect(find.text('ABCD'), findsOneWidget);
      expect(find.text('FFFF'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await events.close();
    },
  );

  testWidgets('expanded packet holds live arrivals until explicitly revealed', (
    tester,
  ) async {
    final events = StreamController<Map<String, dynamic>>.broadcast();
    final api = ApiClient(
      Uri.parse('https://test.invalid'),
      client: MockClient(
        (r) async => http.Response(
          jsonEncode(
            r.url.path == '/api/v1/packets'
                ? {
                    'items': [
                      {
                        'packetHash': 'abcd',
                        'payloadType': 4,
                        'observationCount': 0,
                        'lastHeardAt': 1,
                      },
                    ],
                    'hasMore': false,
                  }
                : {'observations': []},
          ),
          200,
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PacketScreen(
            api: api,
            region: const {},
            events: events.stream,
            onOpen: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('ABCD'));
    await tester.pumpAndSettle();
    events.add({
      'event': 'packetObservation',
      'data': {
        'packetHash': 'ffff',
        'packet': {'payloadType': 4},
        'observation': {'observerId': 'new', 'heardAt': 2},
      },
    });
    await tester.pumpAndSettle();
    expect(find.text('FFFF'), findsNothing);
    expect(find.text('Open analyzer'), findsOneWidget);
    expect(find.text('1 new packet'), findsOneWidget);
    await tester.tap(find.text('1 new packet'));
    await tester.pumpAndSettle();
    expect(find.text('FFFF'), findsOneWidget);
    expect(find.text('Open analyzer'), findsNothing);
    events.add({
      'event': 'packetObservation',
      'data': {
        'packetHash': 'eeee',
        'packet': {'payloadType': 4},
        'observation': {'observerId': 'new', 'heardAt': 3},
      },
    });
    await tester.pumpAndSettle();
    expect(find.text('EEEE'), findsOneWidget);
    expect(find.text('1 new packet'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });
}
