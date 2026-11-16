import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/core/strings.dart';
import 'package:beacon/core/units.dart';
import 'package:beacon/features/analytics/charts.dart';
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

    test('temperature converts through convert', () {
      final s = telemetrySeries(
        [
          point(0, {'temperatureC': 35}),
        ],
        'temperatureC',
        hour,
        convert: (c) => toDisplayTemp(c, 'f'),
      );
      expect(s.single.y, closeTo(95, 1e-9));
    });

    test('readingsLine shows the temperature in the unit', () {
      final points = [
        point(0, {'batteryMv': 4230, 'temperatureC': 16.5}),
      ];
      expect(readingsLine(points, 'c'), '4.23 V · 16.5 °C');
      expect(readingsLine(points, 'f'), '4.23 V · 61.7 °F');
    });

    test('airtime seconds become percent of the counter span', () {
      // 36 s over a 6 h span is 36 / 21600 = 0.1667 %, whatever the bucket.
      final s = airtimeSeries(
        [
          point(0, {'airtimeTxSecs': 36, 'counterSpanSecs': 21600}),
        ],
        'airtimeTxSecs',
        hour,
      );
      expect(s.single.y, closeTo(36 * 100 / 21600, 1e-9));
    });

    test('airtime without a span, or with a zero span, is null', () {
      final s = airtimeSeries(
        [
          point(0, {'airtimeTxSecs': 36}),
          point(hour, {'airtimeTxSecs': 36, 'counterSpanSecs': 0}),
        ],
        'airtimeTxSecs',
        hour,
      );
      expect(s.map((p) => p.y), [null, null]);
    });

    test('airtime above 100 percent is null', () {
      final s = airtimeSeries(
        [
          point(0, {'airtimeTxSecs': 30000, 'counterSpanSecs': 21600}),
          point(hour, {'airtimeTxSecs': 21600, 'counterSpanSecs': 21600}),
        ],
        'airtimeTxSecs',
        hour,
      );
      expect(s.map((p) => p.y), [null, 100]);
    });

    test('airtime keeps the gap break', () {
      final s = airtimeSeries(
        [
          point(0, {'airtimeTxSecs': 1, 'counterSpanSecs': 100}),
          point(3 * hour, {'airtimeTxSecs': 1, 'counterSpanSecs': 100}),
        ],
        'airtimeTxSecs',
        hour,
      );
      expect(s.map((p) => p.x), [0, hour, 3 * hour]);
      expect(s.map((p) => p.y), [1, null, 1]);
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
      int Function(Uri)? statusFor,
      Map<String, dynamic>? telemetry,
      Map<String, dynamic>? pollingBody,
      void Function(String, String)? onOpen,
      String temperatureUnit = 'c',
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
                'display': {'temperatureUnit': temperatureUnit},
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
              statusFor?.call(request.url) ?? telemetryStatus,
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
          'counterSpanSecs': 21600,
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

    testWidgets('a failed first load renders nothing', (tester) async {
      await pump(tester, telemetryStatus: 500, pollingBody: poller);
      expect(find.text('TELEMETRY'), findsNothing);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      expect(find.text(trKey('nodeTelemetry.failed')), findsNothing);
      expect(find.text('Retry'), findsNothing);
    });

    testWidgets('a failed later load keeps the section, dropdown and retry', (
      tester,
    ) async {
      var fail = false;
      await pump(
        tester,
        telemetry: data(),
        pollingBody: poller,
        statusFor: (_) => fail ? 500 : 200,
      );
      expect(find.text('BATTERY (V)'), findsOneWidget);
      fail = true;
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(trKey('nodeTelemetry.range24h')).last);
      await tester.pumpAndSettle();
      expect(find.text('TELEMETRY'), findsOneWidget);
      expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
      expect(find.text(trKey('nodeTelemetry.failed')), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('every chart in the section draws dots', (tester) async {
      await pump(tester, telemetry: data(), pollingBody: poller);
      final charts = tester.widgetList<TimeChart>(find.byType(TimeChart));
      expect(charts.length, 4);
      expect(charts.every((c) => c.showDots), isTrue);
    });

    testWidgets('a failure after a range change recovers on retry', (
      tester,
    ) async {
      var fail = false;
      final seen = await pump(
        tester,
        telemetry: data(),
        pollingBody: poller,
        statusFor: (_) => fail ? 500 : 200,
      );
      fail = true;
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(trKey('nodeTelemetry.range24h')).last);
      await tester.pumpAndSettle();
      expect(find.text('TELEMETRY'), findsOneWidget);
      expect(find.text(trKey('nodeTelemetry.failed')), findsOneWidget);
      fail = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text(trKey('nodeTelemetry.failed')), findsNothing);
      expect(find.text('BATTERY (V)'), findsOneWidget);
      final last = seen.lastWhere((u) => u.path.endsWith('/telemetry'));
      expect(last.queryParameters['range'], '24h');
    });

    testWidgets('a polled node with no points in range says so', (
      tester,
    ) async {
      await pump(
        tester,
        telemetry: {'polled': true, 'points': []},
        pollingBody: poller,
      );
      expect(find.text('No readings in this range'), findsOneWidget);
      expect(find.text(trKey('nodeTelemetry.waiting')), findsNothing);
      expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
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
      expect(find.text('AIRTIME TX AND RX (% OF TIME)'), findsOneWidget);
      expect(find.text('Polled by HOWL V4.2'), findsOneWidget);
      expect(find.text('2 standby observers'), findsOneWidget);
      expect(find.text(trKey('nodeTelemetry.waiting')), findsNothing);
      await tester.tap(find.text('Polled by HOWL V4.2'));
      expect(opened, 'observer:obs-9');
    });

    testWidgets('the temperature chart follows the instance unit', (
      tester,
    ) async {
      await pump(tester, telemetry: data(), temperatureUnit: 'f');
      expect(find.text('TEMPERATURE (°F)'), findsOneWidget);
      expect(find.text('TEMPERATURE (°C)'), findsNothing);
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
      expect(find.text('AIRTIME TX AND RX (% OF TIME)'), findsNothing);
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
