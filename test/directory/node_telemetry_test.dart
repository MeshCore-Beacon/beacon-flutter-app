import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/core/strings.dart';
import 'package:beacon/features/directory/directory.dart';
import 'package:beacon/features/directory/node_telemetry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const hour = 3600000;

Map<String, dynamic> point(int t, [Map<String, dynamic> more = const {}]) => {
  't': t,
  'readings': 1,
  ...more,
};

void main() {
  group('transforms', () {
    test('battery millivolts become volts', () {
      final s = telemetrySeries(
        [
          point(0, {'batteryMv': 4226}),
        ],
        'batteryMv',
        hour,
        scale: .001,
      );
      expect(s.single.y, closeTo(4.226, 1e-9));
    });

    test('airtime seconds become percent of the bucket', () {
      // 36 s of a 6 h bucket is 36 / 21600 = 0.1667 %.
      final s = airtimeSeries(
        [
          point(0, {'airtimeTxSecs': 36}),
        ],
        'airtimeTxSecs',
        6 * hour,
      );
      expect(s.single.y, closeTo(36 * 100 / 21600, 1e-9));
    });

    test('missing buckets and missing fields are null, not bridged', () {
      final s = telemetrySeries(
        [
          point(0, {'temperatureC': 10}),
          point(3 * hour, {'temperatureC': 12}),
          point(4 * hour),
        ],
        'temperatureC',
        hour,
      );
      expect(s.map((p) => p.x), [0, hour, 3 * hour, 4 * hour]);
      expect(s.map((p) => p.y), [10, null, 12, null]);
    });

    test('no points gives no series', () {
      expect(telemetrySeries([], 'batteryMv', hour), isEmpty);
    });
  });

  group('section', () {
    Future<List<Uri>> pump(
      WidgetTester tester, {
      String type = 'repeater',
      bool polling = true,
      int telemetryStatus = 200,
      Map<String, dynamic>? telemetry,
      Map<String, dynamic>? pollingBody,
      void Function(String, String)? onOpen,
    }) async {
      tester.view.physicalSize = const Size(800, 6000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final seen = <Uri>[];
      final api = ApiClient(
        Uri.parse('https://test.invalid'),
        transientRetries: 0,
        client: MockClient((request) async {
          seen.add(request.url);
          final path = request.url.path;
          if (path.endsWith('/info')) {
            return http.Response(
              jsonEncode({
                'features': {'polling': polling},
              }),
              200,
            );
          }
          if (path.endsWith('/telemetry')) {
            return http.Response(
              jsonEncode(
                telemetry ??
                    {
                      'range': '168h',
                      'interval': '6h',
                      'polled': false,
                      'points': [],
                    },
              ),
              telemetryStatus,
            );
          }
          if (path.endsWith('/polling')) {
            return http.Response(
              jsonEncode(
                pollingBody ??
                    {'polled': false, 'poller': null, 'standbys': []},
              ),
              200,
            );
          }
          final body = path.endsWith('/observations')
              ? {'items': [], 'hasMore': false}
              : path.endsWith('/neighbors')
              ? []
              : {'id': 'node-1', 'publicKey': 'pk', 'nodeTypeName': type};
          return http.Response(jsonEncode(body), 200);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: EntityDetailScreen(
            kind: 'node',
            id: 'node-1',
            api: api,
            region: const {},
            onOpen: onOpen ?? (_, _) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      return seen;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    Map<String, dynamic> data() => {
      'range': '168h',
      'interval': '6h',
      'polled': true,
      'points': [
        point(now - 12 * hour, {
          'batteryMv': 4100,
          'temperatureC': 16.5,
          'noiseFloorDb': -97,
          'airtimeTxSecs': 1.5,
          'airtimeRxSecs': 220,
        }),
        point(now - 6 * hour, {'batteryMv': 4000}),
      ],
    };
    final poller = {
      'polled': true,
      'latestReadingAt': now - hour,
      'poller': {'observerId': 'obs-9', 'name': 'HOWL V4.2'},
      'standbys': [
        {'observerId': 'obs-3', 'name': 'Two', 'rank': 1},
        {'observerId': 'obs-4', 'name': 'Three', 'rank': 2},
      ],
    };

    testWidgets('no section for a companion', (tester) async {
      final seen = await pump(tester, type: 'companion', telemetry: data());
      expect(find.text('TELEMETRY'), findsNothing);
      expect(seen.where((u) => u.path.contains('telemetry')), isEmpty);
    });

    testWidgets('no section when polling is off', (tester) async {
      final seen = await pump(tester, polling: false, telemetry: data());
      expect(find.text('TELEMETRY'), findsNothing);
      expect(seen.where((u) => u.path.contains('telemetry')), isEmpty);
    });

    testWidgets('no section when the route answers 404', (tester) async {
      await pump(tester, telemetryStatus: 404, pollingBody: poller);
      expect(find.text('TELEMETRY'), findsNothing);
    });

    testWidgets('nothing when there is no telemetry and no poller', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('TELEMETRY'), findsNothing);
    });

    testWidgets('one waiting line with a poller and no points', (tester) async {
      await pump(tester, pollingBody: poller);
      expect(find.text('TELEMETRY'), findsOneWidget);
      expect(find.text(trKey('nodeTelemetry.waiting')), findsOneWidget);
      expect(find.text('BATTERY (V)'), findsNothing);
    });

    testWidgets('charts with data, poller, last reading and standbys', (
      tester,
    ) async {
      String? opened;
      final seen = await pump(
        tester,
        telemetry: data(),
        pollingBody: poller,
        onOpen: (kind, id) => opened = '$kind:$id',
      );
      final request = seen.firstWhere((u) => u.path.endsWith('/telemetry'));
      expect(request.queryParameters, {'range': '168h', 'interval': '6h'});
      expect(find.text('TELEMETRY'), findsOneWidget);
      expect(find.text('BATTERY (V)'), findsOneWidget);
      expect(find.text('TEMPERATURE (°C)'), findsOneWidget);
      expect(find.text('NOISE FLOOR (DBM)'), findsOneWidget);
      expect(find.text('AIRTIME TX AND RX (%)'), findsOneWidget);
      expect(find.text('Polled by HOWL V4.2'), findsOneWidget);
      expect(find.text(trKey('nodeTelemetry.standbys', count: 2)), findsOne);
      expect(find.text(trKey('nodeTelemetry.waiting')), findsNothing);
      await tester.tap(find.text('Polled by HOWL V4.2'));
      expect(opened, 'observer:obs-9');
    });

    testWidgets('only charts that carry data are drawn', (tester) async {
      await pump(
        tester,
        telemetry: {
          'polled': true,
          'points': [
            point(now - hour, {'batteryMv': 4000}),
          ],
        },
      );
      expect(find.text('BATTERY (V)'), findsOneWidget);
      expect(find.text('TEMPERATURE (°C)'), findsNothing);
      expect(find.text('AIRTIME TX AND RX (%)'), findsNothing);
    });

    testWidgets('the range dropdown asks for another window', (tester) async {
      final seen = await pump(tester, telemetry: data(), pollingBody: poller);
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(trKey('nodeTelemetry.range24h')).last);
      await tester.pumpAndSettle();
      final last = seen.lastWhere((u) => u.path.endsWith('/telemetry'));
      expect(last.queryParameters, {'range': '24h', 'interval': '1h'});
    });
  });
}
