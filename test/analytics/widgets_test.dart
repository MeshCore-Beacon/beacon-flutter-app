import 'dart:async';
import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/features/analytics/analytics_screen.dart';
import 'package:beacon/features/analytics/charts.dart';
import 'package:beacon/features/analytics/transforms.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets(
    'zero-sample histogram shows no observations instead of empty axes',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: DistributionChart(
              labels: ['< -30', '-30 to < -25'],
              values: [0, 0],
            ),
          ),
        ),
      );
      expect(find.text('No observations in this window.'), findsOneWidget);
    },
  );

  testWidgets(
    'clock drift refreshes on its own without a global refresh action',
    (tester) async {
      var clockDriftRequests = 0;
      final api = ApiClient(
        Uri.parse('https://example.test'),
        client: MockClient((r) async {
          if (r.url.path.endsWith('/clock-drift')) clockDriftRequests++;
          return http.Response(jsonEncode([]), 200);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AnalyticsScreen(
              api: api,
              region: const {},
              initialTab: 'Clock Drift',
              onOpen: (_, _) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(find.byTooltip('Refresh analytics'), findsNothing);
      expect(clockDriftRequests, 1);
      await tester.pump(const Duration(minutes: 1));
      await tester.pumpAndSettle();
      expect(clockDriftRequests, 2);
    },
  );

  testWidgets(
    'path classification shows format coverage without raw tables',
    (tester) async {
      final hour = DateTime.now().millisecondsSinceEpoch ~/ 3600000 * 3600000;
      final api = ApiClient(
        Uri.parse('https://example.test'),
        client: MockClient(
          (r) async => http.Response(
            jsonEncode({
              'since': hour - 3600000,
              'until': hour,
              'receptions': 10,
              'hashed': 7,
              'empty': 1,
              'trace': 1,
              'unclassified': 1,
              'hashWidths': [
                {'bytes': 1, 'receptions': 5},
                {'bytes': 2, 'receptions': 2},
              ],
              'pathLengths': [
                {'entries': 1, 'receptions': 5},
                {'entries': 2, 'receptions': 2},
              ],
              'hourly': [
                {
                  'hour': hour - 3600000,
                  'receptions': 10,
                  'oneByte': 5,
                  'twoByte': 2,
                  'threeByte': 0,
                  'empty': 1,
                  'trace': 1,
                  'unclassified': 1,
                  'maxEntries': 2,
                },
              ],
            }),
            200,
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AnalyticsScreen(
              api: api,
              region: const {},
              initialTab: 'Paths',
              onOpen: (_, _) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('PATH FORMAT COVERAGE'), findsOneWidget);
      expect(find.text('PATH FORMAT COUNTS'), findsNothing);
      expect(find.text('Hourly path counts'), findsNothing);
      expect(find.text('Unclassified'), findsWidgets);
      expect(find.text('Empty'), findsWidgets);
      expect(find.text('Trace'), findsWidgets);
    },
  );

  testWidgets('observer dashboard orders activity then conditional telemetry', (
    tester,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final requested = <String>[];
    final api = ApiClient(
      Uri.parse('https://example.test'),
      client: MockClient((r) async {
        requested.add(r.url.path);
        if (r.url.path.endsWith('/activity')) {
          return http.Response(
            jsonEncode({
              'windowStart': now - 3600000,
              'windowEnd': now,
              'points': [
                {
                  't': now - 900000,
                  'observations': 4,
                  'snrAvg': 3,
                  'snrMin': -2,
                  'airtimeMs': 1200,
                },
              ],
              'payloadTypes': [
                {'payloadTypeName': 'ADVERT', 'count': 4},
              ],
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'points': [
              {
                't': now - 3600000,
                'batteryMv': 3700,
                'airtimeTxSecs': 30,
                'airtimeRxSecs': 60,
                'noiseFloorDb': -110,
                'uptimeSeconds': 1000,
                'queueLength': 2,
                'receiveErrors': 1,
              },
            ],
          }),
          200,
        );
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ObserverCharts(api: api, observerId: 'observer-1'),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    final activity = tester.getTopLeft(find.text('PACKETS HEARD PER 15M')).dy;
    final mix = tester.getTopLeft(find.text('PACKET-TYPE MIX')).dy;
    final signal = tester.getTopLeft(find.text('SIGNAL · DB')).dy;
    final airtime = tester.getTopLeft(find.text('AIRTIME TX / RX')).dy;
    final busy = tester.getTopLeft(find.text('CHANNEL BUSY')).dy;
    expect(
      activity < mix && mix < signal && signal < airtime && airtime < busy,
      isTrue,
    );
    expect(find.text('QUEUE'), findsOneWidget);
    expect(find.text('RECEIVE ERRORS'), findsOneWidget);
    expect(find.text('DEVICE TELEMETRY'), findsNothing);
    expect(find.text('UPTIME'), findsNothing);
    expect(find.text('RSSI · DBM'), findsNothing);
    expect(requested, hasLength(2));
  });
  testWidgets('neighbor graph refresh button reloads its node set', (
    tester,
  ) async {
    var graphRequests = 0;
    final api = ApiClient(
      Uri.parse('https://example.test'),
      client: MockClient((r) async {
        if (r.url.path.endsWith('/nodes')) {
          graphRequests++;
          return http.Response(
            jsonEncode([
              {
                'id': 'node-1',
                'name': 'Repeater',
                'knownNeighborCount': 0,
                'neighborIds': [],
              },
            ]),
            200,
          );
        }
        return http.Response(jsonEncode([]), 200);
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnalyticsScreen(
            api: api,
            region: const {
              'iatas': ['YVR'],
            },
            initialTab: 'Neighbour Graph',
            onOpen: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(graphRequests, 1);
    expect(find.byTooltip('Refresh graph'), findsOneWidget);
    await tester.tap(find.byTooltip('Refresh graph'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(graphRequests, 2);
  });

  testWidgets('observer busy chart is hidden when airtime was not reported', (
    tester,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final api = ApiClient(
      Uri.parse('https://example.test'),
      client: MockClient((r) async {
        if (r.url.path.endsWith('/activity')) {
          return http.Response(
            jsonEncode({
              'windowStart': now - 900000,
              'windowEnd': now,
              'points': [
                {'t': now - 900000, 'observations': 1},
              ],
            }),
            200,
          );
        }
        return http.Response(jsonEncode({'points': []}), 200);
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ObserverCharts(api: api, observerId: 'observer-1'),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('CHANNEL BUSY'), findsNothing);
    expect(find.textContaining('no device telemetry'), findsOneWidget);
  });

  testWidgets('observer compare link seeds A and waits for a distinct B', (
    tester,
  ) async {
    const a = '00000000-0000-0000-0000-000000000001',
        b = '00000000-0000-0000-0000-000000000002';
    final requests = <Uri>[];
    final api = ApiClient(
      Uri.parse('https://example.test'),
      client: MockClient((r) async {
        requests.add(r.url);
        return http.Response(
          jsonEncode(
            r.url.path.endsWith('/observers')
                ? {
                    'items': [
                      {
                        'id': b,
                        'displayName': 'Partner station',
                        'iata': 'YVR',
                      },
                    ],
                  }
                : {'totalPackets': 10, 'onlyA': 3, 'both': 5, 'onlyB': 2},
          ),
          200,
        );
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnalyticsScreen(
            api: api,
            region: const {},
            observerId: a,
            initialTab: 'Compare Observers',
            onOpen: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      requests.where((u) => u.path.endsWith('observer-comparison')),
      isEmpty,
    );
    await tester.tap(find.textContaining('Observer B:'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Partner');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(requests.last.queryParameters['name'], 'Partner');
    await tester.tap(find.text('Partner station'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Compare'));
    await tester.pumpAndSettle();
    final request = requests.lastWhere(
      (u) => u.path.endsWith('observer-comparison'),
    );
    expect(request.queryParameters['observerA'], a);
    expect(request.queryParameters['observerB'], b);
    expect(find.text('10 distinct packets'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('all analytics sections render populated narrow-phone fixtures', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final hour = DateTime.now().millisecondsSinceEpoch ~/ 3600000 * 3600000;
    final api = ApiClient(
      Uri.parse('https://example.test'),
      client: MockClient((req) async {
        final endpoint = req.url.path.split('/').last;
        dynamic data;
        switch (endpoint) {
          case 'series':
            data = {
              'completeHours': 1,
              'summary': {
                'uniquePackets': 20,
                'observations': 30,
                'activeObservers': 2,
                'activeIatas': 1,
              },
              'hours': [
                {
                  'hour': hour - 7200000,
                  'status': 'complete',
                  'values': {
                    'uniquePackets': 20,
                    'observations': 30,
                    'activeObservers': 2,
                    'activeIatas': 1,
                  },
                },
              ],
            };
          case 'observations':
            data = [
              {'hour': hour - 3600000, 'iata': 'YVR', 'observationCount': 23},
              {'hour': hour, 'iata': 'SEA', 'observationCount': 4},
            ];
          case 'signal':
            data = {
              'since': hour - 7200000,
              'until': hour,
              'receptions': 27,
              'snr': {
                'average': 4,
                'samples': 20,
                'histogram': [
                  {'lower': 0, 'upper': 5, 'count': 20},
                ],
              },
              'rssi': {
                'average': -100,
                'samples': 20,
                'histogram': [
                  {'lower': -110, 'upper': -90, 'count': 20},
                ],
              },
              'hourly': [
                {
                  'hour': hour - 3600000,
                  'receptions': 27,
                  'snrSamples': 20,
                  'snrAverage': 4,
                  'rssiSamples': 20,
                  'rssiAverage': -100,
                },
              ],
            };
          case 'paths':
            data = {
              'since': hour - 7200000,
              'until': hour,
              'receptions': 27,
              'hashed': 25,
              'empty': 1,
              'trace': 1,
              'unclassified': 0,
              'hashWidths': [
                {'bytes': 1, 'receptions': 20},
                {'bytes': 2, 'receptions': 5},
              ],
              'pathLengths': [
                {'entries': 1, 'receptions': 20},
                {'entries': 2, 'receptions': 5},
              ],
              'hourly': [
                {
                  'hour': hour - 3600000,
                  'receptions': 27,
                  'oneByte': 20,
                  'twoByte': 5,
                  'threeByte': 0,
                  'maxEntries': 2,
                },
              ],
            };
          case 'scopes':
            data = [
              {
                'name': '#bc',
                'packetCount': 2,
                'observerCount': 1,
                'nodeCount': 3,
                'hourly': [
                  {
                    'hour': hour - 7200000,
                    'packets': 2,
                    'observers': 1,
                    'nodes': 3,
                  },
                ],
              },
            ];
          case 'radio-presets':
            data = [
              {'preset': '910.525,62.5,7', 'sourceType': 'node', 'count': 2},
            ];
          case 'node-types':
            data = [
              {'nodeTypeName': 'Repeater', 'count': 2},
            ];
          case 'payload-breakdown':
            data = [
              {'payloadTypeName': 'ADVERT', 'count': 27},
            ];
          case 'clock-drift':
            data = [
              {
                'nodeName': 'Repeater',
                'nodeId': 'a',
                'nodeTypeName': 'Repeater',
                'clockDriftSeconds': 7200,
                'clockCheckedAt': hour,
                'iatas': [
                  {'iata': 'YVR'},
                ],
              },
            ];
          default:
            data = [];
        }
        return http.Response(jsonEncode(data), 200);
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnalyticsScreen(api: api, region: const {}, onOpen: (_, _) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final label in [
      'Traffic',
      'RF / Signal',
      'Paths & hashes',
      'Scopes',
      'Talkers',
      'Clock drift',
      'Compare observers',
      'Neighbor graph',
    ]) {
      await tester.tap(find.byType(DropdownButton<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
      if (label == 'RF / Signal') {
        final grid = tester.widget<MetricGrid>(find.byType(MetricGrid).first);
        expect(grid.values['Active hours'], '1/2');
        expect(grid.presence['Active hours'], [false, true]);
        expect(
          grid.sparks.keys,
          containsAll(['Observations', 'Mean SNR', 'Mean RSSI']),
        );
      }
      expect(tester.takeException(), isNull, reason: label);
    }
  });

  testWidgets(
    'populated chart preserves gaps and legend toggles at narrow width',
    (tester) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: TimeChart(
              series: {
                'Receptions': [
                  ChartPoint(100000, 1),
                  ChartPoint(200000, null),
                  ChartPoint(300000, 9),
                ],
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Receptions'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('analytics mobile selector includes all nine sections', (
    tester,
  ) async {
    final calls = <String>[];
    final api = ApiClient(
      Uri.parse('https://example.test'),
      client: MockClient((r) async {
        calls.add(r.url.path);
        return http.Response(
          jsonEncode(
            r.url.path.endsWith('series')
                ? {'hours': [], 'completeHours': 0}
                : [],
          ),
          200,
        );
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnalyticsScreen(api: api, region: const {}, onOpen: (_, _) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(calls.any((p) => p.endsWith('/signal')), false);
    await tester.tap(find.text('Mesh').first);
    await tester.pumpAndSettle();
    expect(find.text('Compare observers'), findsOneWidget);
    expect(find.text('Neighbor graph'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'old request cannot paint after instance switch and errors retry',
    (tester) async {
      final oldResponse = Completer<http.Response>();
      final old = ApiClient(
        Uri.parse('https://old.test'),
        client: MockClient((_) => oldResponse.future),
      );
      var tries = 0;
      final next = ApiClient(
        Uri.parse('https://next.test'),
        client: MockClient(
          (_) async => ++tries == 1
              ? http.Response('failed', 500)
              : http.Response('"new data"', 200),
        ),
      );
      Widget view(ApiClient api) => MaterialApp(
        home: Scaffold(
          body: StatsQuery(
            api: api,
            path: '/stats/series',
            builder: (d) => Text('$d'),
          ),
        ),
      );
      await tester.pumpWidget(view(old));
      await tester.pumpWidget(view(next));
      await tester.pumpAndSettle();
      expect(find.text('Retry'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('new data'), findsOneWidget);
      oldResponse.complete(http.Response('"stale data"', 200));
      await tester.pumpAndSettle();
      expect(find.text('stale data'), findsNothing);
    },
  );
  testWidgets('charts tolerate x values outside the DateTime range', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                TimeChart(
                  series: {
                    'Observations': [ChartPoint(0, 1), ChartPoint(1e16, 2)],
                  },
                ),
                ActivityHeatmap(
                  points: [ChartPoint(0, 1), ChartPoint(1e16, 2)],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
