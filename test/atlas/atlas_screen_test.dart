import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:beacon/core/account.dart';
import 'package:beacon/core/api.dart';
import 'package:beacon/core/auth_api.dart';
import 'package:beacon/core/preferences.dart';
import 'package:beacon/core/strings.dart';
import 'package:beacon/core/theme.dart';
import 'package:beacon/core/token_store.dart';
import 'package:beacon/features/analytics/charts.dart';
import 'package:beacon/features/atlas/atlas.dart';
import 'package:beacon/features/atlas/atlas_grid.dart';
import 'package:beacon/features/atlas/atlas_screen.dart';
import 'package:beacon/features/atlas/atlas_store.dart';
import 'package:beacon/features/atlas/atlas_widgets.dart';
import 'package:beacon/features/directory/node_chips.dart';
import 'package:beacon/features/directory/node_poller.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const server = 'https://test.invalid';
const storeKey = 'beacon.atlas.$server';
const nodeId = '11111111-1111-4111-8111-111111111111';
const otherId = '22222222-2222-4222-8222-222222222222';
const observerId = '44444444-4444-4444-8444-444444444444';
final key = 'ab' * 32, otherKey = 'cd' * 32;
final now = DateTime.utc(2026, 9, 29, 12, 10);
final tick = now.millisecondsSinceEpoch;

Map<String, dynamic> nodePin([Map<String, dynamic> extra = const {}]) => {
  'kind': 'node',
  'id': nodeId,
  'publicKey': key,
  'name': 'Hill',
  ...extra,
};
String stored(List<Map<String, dynamic>> pins, [String range = '24h']) =>
    jsonEncode({'version': 2, 'range': range, 'pins': pins});

/// A small Beacon server: two nodes, one of them also an observer.
class Server {
  final requests = <Uri>[];
  Map<String, dynamic> hill = {
    'id': nodeId,
    'publicKey': key,
    'name': 'Hill',
    'nodeTypeName': 'Repeater',
    'stale': false,
    'lastSeen': tick - 180000,
    'knownNeighborCount': 5,
  };
  final ridge = {
    'id': otherId,
    'publicKey': otherKey,
    'name': 'Ridge',
    'nodeTypeName': 'Companion',
    'stale': true,
    'lastSeen': tick - 7200000,
    'knownNeighborCount': 1,
  };
  Map<String, dynamic> observer = {
    'id': observerId,
    'displayName': 'Roof',
    'observerType': 'meshcoretomqtt',
    'status': 'online',
    'publicKey': 'ef' * 32,
    'radio': '910.525,62.5,7',
    'batteryLevel': 4.1,
  };

  /// Holds the observer lookup, like a slow network.
  Completer<void>? holdObserver;
  bool activity404 = false;
  bool polling = true, atlasTelemetry = false, atlas7d = false;
  int? atlasLimit;
  String temperatureUnit = 'c';

  /// What /nodes/{id}/polling answers; null is a 404.
  Map<String, dynamic>? pollingDoc = {
    'polled': true,
    'latestReadingAt': tick - 720000,
    'poller': {'observerId': observerId, 'name': 'Roof'},
    'standbys': <dynamic>[],
  };

  /// What /nodes/{id}/poller answers; null is a 404.
  Map<String, dynamic>? pollerDoc = {
    'claim': {
      'receivedAt': tick - 720000,
      'live': true,
      'acceptsRequests': true,
      'slots': {'max': 8, 'used': 2, 'own': 2, 'requested': 0, 'free': 6},
    },
    'readings24h': 40,
    'targets': [
      {'nodeId': 'a', 'name': 'One', 'role': 'poller', 'state': 'ok'},
      {'nodeId': 'b', 'name': 'Two', 'role': 'poller', 'state': 'ok'},
    ],
  };
  List<Map<String, dynamic>> readings = [
    {'t': tick - 7200000, 'batteryMv': 4100, 'temperatureC': 15.2},
    {'t': tick - 3600000, 'batteryMv': 4226},
    {'t': tick - 1800000, 'temperatureC': 16.54},
    {'t': tick - 600000, 'readings': 1},
  ];

  Object? reply(Uri url) {
    final path = url.path.replaceFirst('/api/v1', '');
    final query = url.queryParameters;
    if (path == '/nodes') {
      final all = [hill, ridge];
      final found = query.containsKey('pubkey')
          ? all.where((n) => n['publicKey'] == query['pubkey'])
          : query.containsKey('pubkeyPrefix')
          ? all.where(
              (n) => '${n['publicKey']}'.startsWith(query['pubkeyPrefix']!),
            )
          : all.where(
              (n) => '${n['name']}'.toLowerCase().contains(
                query['name']!.toLowerCase(),
              ),
            );
      return {'items': found.toList(), 'hasMore': false};
    }
    if (path == '/info') {
      return {
        'features': {
          'polling': polling,
          'atlasTelemetry': atlasTelemetry,
          'atlas7d': atlas7d,
        },
        'display': {'temperatureUnit': temperatureUnit},
        if (atlasLimit != null) 'limits': {'atlas': atlasLimit},
      };
    }
    if (path == '/nodes/$nodeId/polling') return pollingDoc;
    if (path == '/nodes/$nodeId/poller') return pollerDoc;
    if (path == '/nodes/$nodeId/telemetry') {
      return {'polled': readings.isNotEmpty, 'points': readings};
    }
    if (path == '/nodes/$nodeId') return hill;
    if (path == '/nodes/$otherId') return ridge;
    if (path == '/nodes/$nodeId/activity') {
      if (activity404) return null;
      return {
        'range': query['range'],
        'summary': {
          'observations': 1500,
          'snrAvg': 5.25,
          'rssiAvg': -101.4,
          'hopAvg': 2.3,
        },
        'points': [
          {'t': tick - 600000, 'observations': 3, 'snrAvg': 4, 'rssiAvg': -90},
        ],
        'latest': {'packetHash': 'feed', 'heardAt': tick - 60000},
      };
    }
    if (path == '/nodes/$otherId/activity') {
      return {
        'summary': {'observations': 0},
        'points': <dynamic>[],
        'latest': null,
      };
    }
    if (path == '/observers/directory') {
      return {
        'items': [observer],
        'hasMore': false,
      };
    }
    if (path == '/observers/$observerId') return observer;
    if (path == '/observers/$observerId/activity') {
      return {
        'points': [
          {'t': tick - 600000, 'observations': 42, 'snrAvg': 3, 'rssiAvg': -95},
        ],
        'payloadTypes': [
          {'payloadTypeName': 'ADVERT', 'count': 30},
          {'payloadTypeName': 'GRP_TXT', 'count': 12},
        ],
      };
    }
    if (path == '/observers/$observerId/telemetry') {
      return {
        'points': [
          {'t': tick - 600000, 'noiseFloorDb': -112, 'queueLength': 3},
        ],
      };
    }
    if (path == '/packets/feed') {
      return {
        'originPubkey': key,
        'observations': [
          {
            'observerId': observerId,
            'observerName': 'Roof',
            'iata': 'YOW',
            'heardAt': tick - 60000,
          },
          {
            'observerId': 'o2',
            'observerName': 'Tower',
            'iata': 'YUL',
            'heardAt': tick - 50000,
          },
        ],
      };
    }
    return null;
  }

  /// The client's response cache runs on this clock, not the test's fake timers.
  DateTime clock = now;
  ApiClient get api => ApiClient(
    Uri.parse(server),
    now: () => clock,
    client: MockClient((request) async {
      requests.add(request.url);
      if (request.url.path.endsWith('/observers/$observerId')) {
        await holdObserver?.future;
      }
      final body = reply(request.url);
      return body == null
          ? http.Response('{"error":{"message":"not found"}}', 404)
          : http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
    }),
  );
}

late Server fake;
final opened = <(String, String)>[];

Future<Preferences> pump(
  WidgetTester tester, {
  List<Map<String, dynamic>>? pins,
  String range = '24h',
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({
    'beacon.servers': jsonEncode([
      {'name': 'Test', 'url': server},
    ]),
    'beacon.active': server,
    'beacon.atlas.$server': ?(pins == null ? null : stored(pins, range)),
  });
  final prefs = await Preferences.load();
  opened.clear();
  await tester.pumpWidget(
    MaterialApp(
      theme: BeaconTheme.all.first.data,
      home: Scaffold(
        body: AtlasScreen(
          api: fake.api,
          preferences: prefs,
          onOpen: (kind, id) => opened.add((kind, id)),
          clock: () => now,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return prefs;
}

/// The test font is far wider than the app's, so layouts are measured with the real one.
Future<void> realFont(WidgetTester tester) => tester.runAsync(() async {
  final bytes = File('assets/fonts/JetBrainsMono.ttf').readAsBytesSync();
  await (FontLoader(
    'JetBrainsMono',
  )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
});

/// A card tab by its view; only the open one spells its name.
Finder tab(String view) => find.byKey(ValueKey('atlas-tab-$view'));

/// Unmounts the page so its poll timers end with the test.
Future<void> close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  expect(tester.takeException(), isNull);
}

List<dynamic> savedPins(Preferences prefs) =>
    (jsonDecode(prefs.atlasFor(server)!) as Map)['pins'] as List;

Future<void> search(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const ValueKey('atlas-search')), text);
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
}

/// Whether the footer dot beside [text] is lit; fails when there is no dot.
bool footerFresh(WidgetTester tester, String text) {
  final row = find
      .ancestor(of: find.text(text), matching: find.byType(Row))
      .first;
  final dot = find.descendant(
    of: row,
    matching: find.byKey(const ValueKey('atlas-footer-dot')),
  );
  final color =
      (tester.widget<Container>(dot).decoration! as BoxDecoration).color;
  return color == BeaconColors.of(tester.element(dot)).success;
}

/// Switches the cards to their edit buttons: pin, drag and remove.
Future<void> edit(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('atlas-edit')));
  await tester.pumpAndSettle();
}

void main() {
  // Asset loads never finish inside a widget test's fake clock.
  setUp(() async {
    fake = Server();
    await BeaconTheme.load();
  });

  testWidgets('takes its card cap from the server', (tester) async {
    fake.atlasLimit = 1;
    await pump(tester, pins: [nodePin()]);
    expect(find.text('1/1'), findsOneWidget);
    await search(tester, 'ridge');
    expect(find.textContaining('All 1 slots are in use'), findsOneWidget);
    await close(tester);
  });

  testWidgets('a poller search row shows both badges, others do not', (
    tester,
  ) async {
    fake.hill['isObserver'] = true;
    fake.hill['isPoller'] = true;
    fake.ridge['isObserver'] = true;
    await pump(tester);
    await search(tester, 'hill');
    expect(find.text('OBSERVER'), findsOneWidget);
    expect(find.text('POLLER'), findsOneWidget);
    await search(tester, 'ridge');
    expect(find.text('OBSERVER'), findsOneWidget);
    expect(find.text('POLLER'), findsNothing);
    fake.ridge.remove('isObserver');
    await search(tester, 'ridg');
    expect(find.text('POLLER'), findsNothing);
    await close(tester);
  });

  testWidgets('starts empty, finds a node by name and saves it as a card', (
    tester,
  ) async {
    final prefs = await pump(tester);
    expect(find.text('No nodes saved'), findsOneWidget);
    expect(find.text('0/12'), findsOneWidget);

    await search(tester, 'h');
    expect(find.text('Type at least 2 characters.'), findsOneWidget);
    await search(tester, 'hill');
    expect(find.text('MATCHES'), findsOneWidget);
    expect(find.text(formatHex(key)), findsOneWidget);
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(find.text('Saved'), findsOneWidget);
    expect(find.text('1/12'), findsOneWidget);
    expect(find.text('No nodes saved'), findsNothing);
    expect(savedPins(prefs), [nodePin()]);
    await close(tester);
  });

  testWidgets('the search box gives up focus when the page is used', (
    tester,
  ) async {
    await pump(tester, pins: [nodePin()]);
    await tester.tap(find.byKey(const ValueKey('atlas-search')));
    await tester.pump();
    bool focused() => tester
        .widget<EditableText>(find.byType(EditableText))
        .focusNode
        .hasFocus;
    expect(focused(), isTrue);
    await tester.tap(tab('heard'));
    await tester.pumpAndSettle();
    expect(focused(), isFalse);
    expect(find.text('Open packet'), findsOneWidget);
    await close(tester);
  });

  testWidgets('a public key search sends hex only', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('atlas-search-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Public Key').last);
    await tester.pumpAndSettle();
    fake.requests.clear();
    await search(tester, 'zz');
    expect(find.text('A public key prefix is hex only (0-9, a-f).'), findsOne);
    expect(fake.requests, isEmpty);
    await search(tester, 'CDcd');
    expect(fake.requests.single.queryParameters['pubkeyPrefix'], 'cdcd');
    expect(find.text('Ridge'), findsOneWidget);
    await close(tester);
  });

  testWidgets('a node card shows its hourly activity and opens the node', (
    tester,
  ) async {
    await pump(tester, pins: [nodePin()]);
    expect(find.text('REPEATER'), findsOneWidget);
    expect(find.byTooltip('Recent'), findsOneWidget);
    expect(find.text('RECENT'), findsNothing);
    expect(find.text('OBSERVATIONS'), findsOneWidget);
    expect(find.text('1.5k'), findsOneWidget);
    expect(find.text('5.3 dB'), findsOneWidget);
    expect(find.text('-101.4 dBm'), findsOneWidget);
    expect(find.text('1/24'), findsOneWidget);
    expect(find.text('Heard · 3m ago'), findsOneWidget);
    expect(find.text('2.3 hops · 5 neighbors'), findsOneWidget);
    expect(footerFresh(tester, 'Heard · 3m ago'), isTrue);
    expect(
      fake.requests
          .where((url) => url.path.endsWith('/activity'))
          .single
          .queryParameters['range'],
      '24h',
    );
    await tester.tap(find.text('Hill'));
    expect(opened, [('node', nodeId)]);

    await tester.tap(find.text('3d'));
    await tester.pumpAndSettle();
    expect(find.text('1/72'), findsOneWidget);
    expect(
      fake.requests
          .where((url) => url.path.endsWith('/activity'))
          .last
          .queryParameters['range'],
      '72h',
    );
    await close(tester);
  });

  group('Telemetry tab', () {
    bool tabShown() => tab('telemetry').evaluate().isNotEmpty;
    Iterable<Uri> asked(String range) => fake.requests.where(
      (url) =>
          url.path == '/api/v1/nodes/$nodeId/telemetry' &&
          url.queryParameters['range'] == range,
    );

    testWidgets('appears for a polled repeater with readings', (tester) async {
      final prefs = await pump(tester, pins: [nodePin()]);
      expect(tabShown(), true);
      // The old readings line is gone.
      expect(find.text('4.23 V · 16.5 °C'), findsNothing);
      // Nothing is read for the tiles until the tab is open.
      expect(asked('24h'), isEmpty);
      expect(prefs.atlasFor(server), stored([nodePin()]));
      await close(tester);
    });

    testWidgets('appears when the node is polled but has no readings', (
      tester,
    ) async {
      fake.readings = [];
      await pump(tester, pins: [nodePin()]);
      expect(tabShown(), true);
      await close(tester);
    });

    testWidgets('is missing with no readings and no poller', (tester) async {
      fake.readings = [];
      fake.pollingDoc = null;
      await pump(tester, pins: [nodePin()]);
      expect(tabShown(), false);
      await close(tester);
    });

    testWidgets('is missing for a non-repeater', (tester) async {
      await pump(
        tester,
        pins: [
          nodePin({'id': otherId, 'publicKey': otherKey}),
        ],
      );
      expect(tabShown(), false);
      expect(
        fake.requests.any((url) => url.path.endsWith('/telemetry')),
        false,
      );
      await close(tester);
    });

    testWidgets('is missing and asks nothing with polling off', (tester) async {
      fake.polling = false;
      await pump(tester, pins: [nodePin()]);
      expect(tabShown(), false);
      expect(
        fake.requests.any((url) => url.path.endsWith('/telemetry')),
        false,
      );
      await close(tester);
    });

    testWidgets('shows tile values, a dash for no data and the poller line', (
      tester,
    ) async {
      await pump(tester, pins: [nodePin()]);
      await tester.tap(tab('telemetry'));
      await tester.pumpAndSettle();
      expect(asked('24h').single.queryParameters['interval'], '1h');
      expect(find.text('BATTERY'), findsOneWidget);
      expect(find.text('4.23V'), findsOneWidget);
      expect(find.text('NOISE FLOOR'), findsOneWidget);
      // Readings exist but no counter pair: the counter tile says so.
      expect(find.text('No readings in this window'), findsNWidgets(2));
      expect(find.text('Needs two status readings'), findsOneWidget);
      expect(find.text('Polled · 12m ago'), findsOneWidget);
      expect(find.text('by Roof'), findsOneWidget);
      expect(footerFresh(tester, 'Polled · 12m ago'), isTrue);
      await close(tester);
    });

    for (final width in [390.0, 320.0]) {
      testWidgets(
        'a long poller name gives way and never cuts the age ($width)',
        (tester) async {
          fake.pollingDoc = {
            'polled': true,
            'latestReadingAt': tick - 49 * 60000,
            'poller': {'observerId': observerId, 'name': 'MrAlders0n_G3_R1'},
            'standbys': <dynamic>[],
          };
          await pump(tester, pins: [nodePin()], size: Size(width, 844));
          await tester.tap(tab('telemetry'));
          await tester.pumpAndSettle();
          final left = find.text('Polled · 49m ago');
          final right = find.text('by MrAlders0n_G3_R1');
          expect(left, findsOneWidget);
          expect(right, findsOneWidget);
          expect(
            tester.renderObject<RenderParagraph>(left).didExceedMaxLines,
            isFalse,
          );
          expect(
            tester.getTopLeft(right).dy,
            moreOrLessEquals(tester.getTopLeft(left).dy, epsilon: 1),
          );
          expect(tester.takeException(), isNull);
          await close(tester);
        },
      );
    }

    testWidgets('says when nobody is polling', (tester) async {
      fake.pollingDoc = {
        'polled': true,
        'latestReadingAt': tick - 3 * 86400000,
        'poller': null,
        'standbys': <dynamic>[],
      };
      await pump(tester, pins: [nodePin()]);
      await tester.tap(tab('telemetry'));
      await tester.pumpAndSettle();
      expect(find.text('Not polled'), findsOneWidget);
      expect(find.textContaining('by '), findsNothing);
      expect(footerFresh(tester, 'Not polled'), isFalse);
      await close(tester);
    });

    testWidgets('a pinned card opens on it and follows the range', (
      tester,
    ) async {
      await pump(
        tester,
        pins: [
          nodePin({'view': 'telemetry'}),
        ],
      );
      expect(find.text('BATTERY'), findsOneWidget);
      expect(asked('24h'), hasLength(1));
      await tester.tap(find.text('3d'));
      await tester.pumpAndSettle();
      // This server has no 72h range: a week, trimmed to the window.
      expect(asked('168h').last.queryParameters['interval'], '6h');
      expect(asked('72h'), isEmpty);
      await close(tester);
    });

    testWidgets('asks for 72h when the server offers it', (tester) async {
      fake.atlasTelemetry = true;
      await pump(
        tester,
        pins: [
          nodePin({'view': 'telemetry'}),
        ],
      );
      await tester.tap(find.text('3d'));
      await tester.pumpAndSettle();
      expect(asked('72h').last.queryParameters['interval'], '1h');
      expect(asked('168h'), isEmpty);
      await close(tester);
    });

    for (final (unit, shown) in [('c', '16.5 °C'), ('f', '61.8 °F')]) {
      testWidgets('shows the temperature tile in $unit', (tester) async {
        fake.temperatureUnit = unit;
        await pump(
          tester,
          pins: [
            nodePin({
              'view': 'telemetry',
              'telemetryTiles': ['temperature', 'noise', 'uptime', 'airtime'],
            }),
          ],
        );
        expect(find.text(shown), findsOneWidget);
        await close(tester);
      });
    }

    testWidgets('swaps a tile, stores it only when it differs', (tester) async {
      final prefs = await pump(
        tester,
        pins: [
          nodePin({'view': 'telemetry'}),
        ],
      );
      await tester.tap(find.text('NOISE FLOOR'));
      await tester.pumpAndSettle();
      expect(find.text('Reset tiles'), findsNothing);
      // The fixture has a temperature, so it is offered.
      expect(find.text('Temperature'), findsOneWidget);
      await tester.tap(find.text('Packets'));
      await tester.pumpAndSettle();
      expect(savedPins(prefs).single['telemetryTiles'], [
        'battery',
        'packets',
        'uptime',
        'airtime',
      ]);
      await tester.tap(find.text('PACKETS'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset tiles'));
      await tester.pumpAndSettle();
      expect(
        (savedPins(prefs).single as Map).containsKey('telemetryTiles'),
        false,
      );
      expect(find.text('NOISE FLOOR'), findsOneWidget);
      await close(tester);
    });

    testWidgets('pins the view', (tester) async {
      final prefs = await pump(tester, pins: [nodePin()]);
      await edit(tester);
      await tester.tap(tab('telemetry'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Open on this tab'));
      await tester.pumpAndSettle();
      expect(savedPins(prefs).single['view'], 'telemetry');
      await close(tester);
    });
  });

  group('7 day range', () {
    Iterable<Uri> asked(String path) =>
        fake.requests.where((url) => url.path == '/api/v1$path');

    testWidgets('is offered only by a server that has it', (tester) async {
      await pump(tester, pins: [nodePin()]);
      expect(find.text('3d'), findsOneWidget);
      expect(find.text('7d'), findsNothing);
      await close(tester);
      fake = Server()..atlas7d = true;
      await pump(tester, pins: [nodePin()]);
      expect(find.text('7d'), findsOneWidget);
      await close(tester);
    });

    testWidgets('asks every feed for 168 hourly buckets', (tester) async {
      fake.atlas7d = true;
      fake.hill = {...fake.hill, 'observerId': observerId};
      final prefs = await pump(tester, pins: [nodePin()]);
      await tester.tap(find.text('7d'));
      await tester.pumpAndSettle();
      expect(jsonDecode(prefs.atlasFor(server)!)['range'], '7d');
      expect(asked('/nodes/$nodeId/activity').last.queryParameters, {
        'range': '168h',
      });
      expect(find.text('7d'), findsNWidgets(2));
      await tester.tap(tab('observer'));
      await tester.pumpAndSettle();
      for (final feed in ['activity', 'telemetry']) {
        expect(asked('/observers/$observerId/$feed').last.queryParameters, {
          'range': '168h',
          'interval': '1h',
        });
      }
      await tester.tap(tab('telemetry'));
      await tester.pumpAndSettle();
      expect(asked('/nodes/$nodeId/telemetry').last.queryParameters, {
        'range': '168h',
        'interval': '1h',
      });
      await close(tester);
    });

    testWidgets('a saved 7d shows and fetches as 3d on an older server', (
      tester,
    ) async {
      final prefs = await pump(tester, pins: [nodePin()], range: '7d');
      expect(find.text('7d'), findsNothing);
      expect(asked('/nodes/$nodeId/activity').last.queryParameters, {
        'range': '72h',
      });
      // The stored range is left alone.
      expect(jsonDecode(prefs.atlasFor(server)!)['range'], '7d');
      await close(tester);
    });
  });

  group('tile graph', () {
    Finder sparkOf(String label) => find.descendant(
      of: find.ancestor(
        of: find.text(label),
        matching: find.byType(AtlasStatTile),
      ),
      matching: find.byKey(const ValueKey('atlas-tile-graph')),
    );
    LineChart chart(WidgetTester tester) =>
        tester.widget<LineChart>(find.byType(LineChart));

    testWidgets('a sparkline opens its metric large, in the tile\'s colour', (
      tester,
    ) async {
      await pump(tester, pins: [nodePin()]);
      expect(find.bySemanticsLabel('Open graph: Observations'), findsOneWidget);
      // The presence strip has no graph.
      expect(sparkOf('ACTIVE HOURS'), findsNothing);
      await tester.tap(sparkOf('OBSERVATIONS'));
      await tester.pumpAndSettle();
      expect(find.text('Hill · Observations'), findsOneWidget);
      expect(find.textContaining('24h · '), findsOneWidget);
      final bar = chart(tester).data.lineBarsData.single;
      expect(bar.spots, hasLength(24));
      expect(bar.spots.last.y, 3);
      expect(bar.dotData.show, isTrue);
      expect(
        bar.color,
        analyticsChartColors(tester.element(find.byType(LineChart))).first,
      );
      expect(chart(tester).data.maxX - chart(tester).data.minX, 24 * hourMs);
      // The newest slot starts on the hour, shown in UTC with the tile's format.
      final tip = chart(tester).data.lineTouchData.touchTooltipData
          .getTooltipItems([LineBarSpot(bar, 0, bar.spots.last)])
          .single!
          .text;
      expect(tip, '09-29T12:00 UTC\nObservations: 3');
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(LineChart), findsNothing);

      await tester.tap(sparkOf('MEAN SNR'));
      await tester.pumpAndSettle();
      expect(find.text('Hill · Mean SNR'), findsOneWidget);
      final snr = chart(tester).data.lineBarsData.single;
      // One hour was heard; the rest are gaps, not zeros.
      expect(snr.spots.where((s) => s.isNotNull()), hasLength(1));
      expect(
        chart(tester).data.lineTouchData.touchTooltipData
            .getTooltipItems([LineBarSpot(snr, 0, snr.spots.last)])
            .single!
            .text,
        endsWith('Mean SNR: 4.0 dB'),
      );
      await close(tester);
    });

    testWidgets('a tile with nothing to draw offers no graph', (tester) async {
      await pump(
        tester,
        pins: [
          nodePin({'id': otherId, 'publicKey': otherKey, 'name': 'Ridge'}),
        ],
      );
      expect(sparkOf('MEAN SNR'), findsNothing);
      expect(sparkOf('MEAN RSSI'), findsNothing);
      await close(tester);
    });

    testWidgets('the sheet zooms sideways and still drags shut', (
      tester,
    ) async {
      await pump(tester, pins: [nodePin()]);
      await tester.tap(sparkOf('OBSERVATIONS'));
      await tester.pumpAndSettle();
      final config = chart(tester).transformationConfig;
      expect(config.scaleAxis, FlScaleAxis.horizontal);
      final centre = tester.getCenter(find.byType(LineChart));
      final a = await tester.startGesture(centre - const Offset(20, 0));
      final b = await tester.startGesture(centre + const Offset(20, 0));
      await a.moveBy(const Offset(-60, 0));
      await b.moveBy(const Offset(60, 0));
      await tester.pump();
      await a.up();
      await b.up();
      await tester.pumpAndSettle();
      expect(
        config.transformationController!.value.getMaxScaleOnAxis(),
        greaterThan(1),
      );
      expect(find.text('Hill · Observations'), findsOneWidget);
      await tester.drag(find.byType(LineChart), const Offset(0, 500));
      await tester.pumpAndSettle();
      expect(find.text('Hill · Observations'), findsNothing);
      await close(tester);
    });

    testWidgets('fits a phone on its side', (tester) async {
      await pump(tester, pins: [nodePin()], size: const Size(640, 360));
      await tester.ensureVisible(sparkOf('OBSERVATIONS'));
      await tester.tap(sparkOf('OBSERVATIONS'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(LineChart)).height, greaterThan(100));
      await close(tester);
    });

    testWidgets(
      'Observer and Telemetry tiles open theirs, the label its menu',
      (tester) async {
        fake.hill = {...fake.hill, 'observerId': observerId};
        await pump(
          tester,
          pins: [
            nodePin({'observerId': observerId, 'view': 'observer'}),
          ],
        );
        // The type mix has no sparkline.
        expect(sparkOf('PACKET TYPES'), findsNothing);
        await tester.tap(sparkOf('NOISE FLOOR'));
        await tester.pumpAndSettle();
        expect(find.text('Hill · Noise floor'), findsOneWidget);
        final noise = chart(tester).data.lineBarsData.single;
        expect(
          chart(tester).data.lineTouchData.touchTooltipData
              .getTooltipItems([LineBarSpot(noise, 0, noise.spots.last)])
              .single!
              .text,
          endsWith('Noise floor: -112 dBm'),
        );
        await tester.tap(find.byTooltip('Close'));
        await tester.pumpAndSettle();
        // The label still opens the tile picker.
        await tester.tap(find.text('NOISE FLOOR'));
        await tester.pumpAndSettle();
        expect(find.text('Queue length'), findsOneWidget);
        expect(find.byType(LineChart), findsNothing);
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();

        await tester.tap(tab('telemetry'));
        await tester.pumpAndSettle();
        await tester.tap(sparkOf('BATTERY'));
        await tester.pumpAndSettle();
        expect(find.text('Hill · Battery'), findsOneWidget);
        final battery = chart(tester).data.lineBarsData.single;
        expect(
          [for (final s in battery.spots) s.isNull() ? null : (s.x, s.y)],
          [(tick - 7200000.0, 4.1), (tick - 3600000.0, 4.226)],
        );
        expect(
          chart(tester).data.lineTouchData.touchTooltipData
              .getTooltipItems([LineBarSpot(battery, 0, battery.spots.last)])
              .single!
              .text,
          endsWith('Battery: 4.23V'),
        );
        await tester.tap(find.byTooltip('Close'));
        await tester.pumpAndSettle();
        // No readings of noise: nothing to open.
        expect(sparkOf('NOISE FLOOR'), findsNothing);
        await close(tester);
      },
    );
  });

  testWidgets('says so when the server has no node activity', (tester) async {
    fake.activity404 = true;
    await pump(tester, pins: [nodePin()]);
    expect(find.text('—'), findsWidgets);
    await tester.tap(tab('heard'));
    await tester.pumpAndSettle();
    expect(
      find.text('This server does not provide node activity.'),
      findsOneWidget,
    );
    await close(tester);
  });

  testWidgets('Heard by lists who heard the latest packet and opens it', (
    tester,
  ) async {
    await pump(tester, pins: [nodePin()]);
    final height = tester.getSize(find.byType(AtlasPanel)).height;
    await tester.tap(tab('heard'));
    await tester.pumpAndSettle();
    expect(find.text('2 observers heard the latest packet 1m ago'), findsOne);
    expect(
      tester.getTopLeft(find.text('Tower')).dy,
      lessThan(tester.getTopLeft(find.text('Roof')).dy),
    );
    expect(find.text('YUL'), findsOneWidget);
    // Flipping the view never resizes the card.
    expect(tester.getSize(find.byType(AtlasPanel)).height, height);
    await tester.tap(find.text('Roof'));
    await tester.tap(find.text('Open packet'));
    expect(opened, [('observer', observerId), ('packet', 'feed')]);
    await close(tester);
  });

  testWidgets('pins the tab a card opens on', (tester) async {
    final prefs = await pump(tester, pins: [nodePin()]);
    await edit(tester);
    expect(find.byTooltip('The card opens on this tab'), findsOneWidget);
    await tester.tap(tab('heard'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Make this the tab the card opens on'));
    await tester.pumpAndSettle();
    expect(savedPins(prefs), [
      nodePin({'view': 'heard'}),
    ]);
    expect(find.byTooltip('The card opens on this tab'), findsOneWidget);
    expect(find.text('Open packet'), findsOneWidget);
    await close(tester);
  });

  testWidgets('every card keeps the view it was switched to', (tester) async {
    await pump(
      tester,
      pins: [
        nodePin(),
        nodePin({'id': otherId, 'publicKey': otherKey}),
      ],
      size: const Size(1200, 1600),
    );
    expect(find.text('OBSERVATIONS'), findsNWidgets(2));
    await tester.tap(tab('heard').at(0));
    await tester.pumpAndSettle();
    await tester.tap(tab('heard').at(1));
    await tester.pumpAndSettle();
    expect(find.text('OBSERVATIONS'), findsNothing);
    await close(tester);
  });

  testWidgets('an observer with no node is saved as an observer card', (
    tester,
  ) async {
    final prefs = await pump(tester);
    await tester.tap(find.byKey(const ValueKey('atlas-search-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Observer').last);
    await tester.pumpAndSettle();
    await search(tester, 'roof');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(savedPins(prefs), [
      {'kind': 'observer', 'observerId': observerId, 'name': 'Roof'},
    ]);
    expect(find.byTooltip('Online'), findsOneWidget);
    expect(find.text('AIRTIME'), findsOneWidget);
    expect(find.text('4.10V'), findsOneWidget);
    expect(find.text('42'), findsOneWidget);
    expect(find.text('-112 dBm'), findsOneWidget);
    expect(find.text('910.525 MHz · SF7'), findsOneWidget);
    expect(find.text('Heard by'), findsNothing);
    await close(tester);
  });

  testWidgets('an observer whose radio advertises is saved as that node', (
    tester,
  ) async {
    fake.observer = {...fake.observer, 'publicKey': key};
    final prefs = await pump(tester);
    await tester.tap(find.byKey(const ValueKey('atlas-search-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Observer').last);
    await tester.pumpAndSettle();
    await search(tester, 'roof');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(savedPins(prefs), [
      nodePin({'observerId': observerId}),
    ]);
    expect(find.text('Saved'), findsOneWidget);
    expect(find.text('Observer'), findsWidgets);
    await close(tester);
  });

  testWidgets(
    'an observer card becomes a node card once its radio advertises',
    (tester) async {
      fake.observer = {...fake.observer, 'publicKey': key};
      final prefs = await pump(
        tester,
        pins: [
          {
            'kind': 'observer',
            'observerId': observerId,
            'name': 'Roof',
            'tiles': ['snr', 'battery', 'types', 'noise'],
          },
        ],
      );
      expect(savedPins(prefs), [
        nodePin({
          'observerId': observerId,
          'tiles': ['snr', 'battery', 'types', 'noise'],
          'view': 'observer',
        }),
      ]);
      expect(tab('heard'), findsOneWidget);
      expect(find.text('MEAN SNR'), findsOneWidget);
      await close(tester);
    },
  );

  testWidgets('swaps an Observer view tile and resets the layout', (
    tester,
  ) async {
    final prefs = await pump(
      tester,
      pins: [
        nodePin({'observerId': observerId, 'view': 'observer'}),
      ],
    );
    expect(find.text('NOISE FLOOR'), findsOneWidget);
    await tester.tap(find.text('NOISE FLOOR'));
    await tester.pumpAndSettle();
    expect(find.text('Reset tiles'), findsNothing);
    expect(find.text('Battery'), findsNothing);
    await tester.tap(find.text('Queue length'));
    await tester.pumpAndSettle();
    expect(savedPins(prefs).single['tiles'], [
      'airtime',
      'battery',
      'types',
      'queue',
    ]);
    expect(find.text('QUEUE LENGTH'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);

    await tester.tap(find.text('QUEUE LENGTH'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset tiles'));
    await tester.pumpAndSettle();
    expect((savedPins(prefs).single as Map).containsKey('tiles'), isFalse);
    expect(find.text('NOISE FLOOR'), findsOneWidget);
    await close(tester);
  });

  testWidgets('pin, drag and remove wait for edit mode', (tester) async {
    await pump(tester, pins: [nodePin()]);
    expect(find.byTooltip('Open node'), findsOneWidget);
    expect(find.byTooltip('Remove'), findsNothing);
    expect(find.byTooltip('Drag to reorder'), findsNothing);
    await edit(tester);
    expect(find.byTooltip('Open node'), findsNothing);
    expect(find.byTooltip('Remove'), findsOneWidget);
    expect(find.byTooltip('Drag to reorder'), findsOneWidget);
    await edit(tester);
    expect(find.byTooltip('Remove'), findsNothing);
    await close(tester);
  });

  testWidgets('removes a card', (tester) async {
    final prefs = await pump(
      tester,
      pins: [
        nodePin(),
        {'kind': 'node', 'id': otherId, 'publicKey': otherKey, 'name': 'Ridge'},
      ],
    );
    await edit(tester);
    expect(find.byTooltip('Stale'), findsOneWidget);
    await tester.tap(find.byTooltip('Remove').first);
    await tester.pumpAndSettle();
    expect(savedPins(prefs).single['name'], 'Ridge');
    expect(find.text('Hill'), findsNothing);
    await close(tester);
  });

  testWidgets('dragging a grip reorders the cards', (tester) async {
    final prefs = await pump(
      tester,
      pins: [
        nodePin(),
        {'kind': 'node', 'id': otherId, 'publicKey': otherKey, 'name': 'Ridge'},
      ],
    );
    await edit(tester);
    final grips = find.byTooltip('Drag to reorder');
    final target = tester.getCenter(grips.last);
    final gesture = await tester.startGesture(tester.getCenter(grips.first));
    await tester.pump();
    await gesture.moveTo(target + const Offset(0, 20));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      [for (final pin in savedPins(prefs)) pin['name']],
      ['Ridge', 'Hill'],
    );
    expect(
      tester.getTopLeft(find.text('Ridge')).dy,
      lessThan(tester.getTopLeft(find.text('Hill')).dy),
    );
    await close(tester);
  });

  testWidgets('a pin recovers its new server id after a reset', (tester) async {
    const fresh = '99999999-9999-4999-8999-999999999999';
    final prefs = await pump(
      tester,
      pins: [
        nodePin({'id': fresh}),
      ],
    );
    expect(savedPins(prefs), [nodePin()]);
    expect(find.text('1.5k'), findsOneWidget);
    await close(tester);
  });

  testWidgets('polls every minute and stops in the background', (tester) async {
    await pump(tester, pins: [nodePin()]);
    int reads() =>
        fake.requests.where((url) => url.path.endsWith('/activity')).length;
    expect(reads(), 1);
    fake.clock = now.add(const Duration(seconds: 61));
    await tester.pump(const Duration(seconds: 61));
    await tester.pumpAndSettle();
    expect(reads(), 2);
    Future<void> lifecycle(List<AppLifecycleState> states) async {
      for (final state in states) {
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
      }
    }

    await lifecycle(const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]);
    fake.clock = now.add(const Duration(minutes: 7));
    await tester.pump(const Duration(minutes: 5));
    expect(reads(), 2);
    await lifecycle(const [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]);
    await tester.pump(const Duration(seconds: 61));
    await tester.pumpAndSettle();
    expect(reads(), 3);
    await close(tester);
  });

  for (final (width, rows) in [(320.0, 2), (375.0, 1)]) {
    testWidgets('the toolbar takes $rows row(s) at $width', (tester) async {
      await pump(tester, pins: [nodePin()], size: Size(width, 800));
      final field = tester.getRect(find.byType(TextField).first);
      final pencil = tester.getRect(find.byKey(const ValueKey('atlas-edit')));
      final range = tester.getRect(find.text('24h').first);
      if (rows == 2) {
        expect(pencil.top, greaterThan(field.bottom));
        expect(range.center.dy, moreOrLessEquals(pencil.center.dy, epsilon: 1));
        expect(pencil.right, moreOrLessEquals(width - 16, epsilon: 1));
        expect(find.text('Find a node'), findsOneWidget);
        expect(tester.getSize(find.text('Find a node')).width, greaterThan(70));
      } else {
        expect(pencil.center.dy, moreOrLessEquals(field.center.dy, epsilon: 2));
      }
      await close(tester);
    });
  }

  testWidgets('the card header stays on one line, the name giving way', (
    tester,
  ) async {
    fake.hill = {...fake.hill, 'name': 'A very long repeater name on a hill'};
    await pump(tester, pins: [nodePin()]);
    await edit(tester);
    final name = find.text('A very long repeater name on a hill');
    final badge = find.text('REPEATER');
    expect(tester.getCenter(name).dy, tester.getCenter(badge).dy);
    expect(
      tester.getCenter(find.byTooltip('Recent')).dy,
      tester.getCenter(badge).dy,
    );
    expect(
      tester.getTopRight(badge).dx,
      lessThan(tester.getTopLeft(find.byTooltip('Remove')).dx),
    );
    await close(tester);
  });

  group('card tabs', () {
    testWidgets('are icons, and only the open one spells its name', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      fake.hill = {...fake.hill, 'isPoller': true, 'observerId': observerId};
      await pump(
        tester,
        pins: [
          nodePin({'observerId': observerId}),
        ],
        size: const Size(375, 844),
      );
      const names = {
        'analytics': 'Analytics',
        'heard': 'Heard by',
        'observer': 'Observer',
        'telemetry': 'Telemetry',
        'poller': 'Poller',
      };
      // In this order, one icon each.
      final lefts = [
        for (final view in names.keys) tester.getTopLeft(tab(view)).dx,
      ];
      expect(lefts, [...lefts]..sort());
      for (final view in names.keys) {
        expect(
          find.descendant(of: tab(view), matching: find.byType(SvgPicture)),
          findsOneWidget,
        );
      }
      for (final open in names.keys) {
        await tester.tap(tab(open));
        await tester.pumpAndSettle();
        for (final MapEntry(key: view, value: name) in names.entries) {
          final text = find.descendant(
            of: tab(view),
            matching: find.text(name),
          );
          expect(text, view == open ? findsOneWidget : findsNothing);
          final node = tester.getSemantics(tab(view));
          expect(node.label, name);
          expect(node.flagsCollection.isSelected.toBoolOrNull(), view == open);
          // An icon alone is as wide as the others and names itself on a long press.
          if (view != open) {
            expect(tester.getSize(tab(view)).width, 38);
            expect(
              find.ancestor(of: tab(view), matching: find.byTooltip(name)),
              findsOneWidget,
            );
          }
        }
        expect(tester.takeException(), isNull);
      }
      handle.dispose();
      await close(tester);
    });

    testWidgets('a two tab card and the range switch keep their shapes', (
      tester,
    ) async {
      await pump(
        tester,
        pins: [
          nodePin({'id': otherId, 'publicKey': otherKey}),
        ],
      );
      expect(find.byType(AtlasTabs<AtlasView>), findsOneWidget);
      expect(tab('analytics'), findsOneWidget);
      expect(tester.getSize(tab('heard')).width, 44);
      expect(tab('observer'), findsNothing);
      // The range switch is still words.
      expect(find.byType(AtlasSegmented<AtlasRange>), findsOneWidget);
      expect(
        tester.getSize(find.byType(AtlasTabs<AtlasView>)).height,
        tester.getSize(find.byType(AtlasSegmented<AtlasRange>)).height,
      );
      await close(tester);
    });
  });

  group('Poller tab', () {
    Future<Preferences> open(WidgetTester tester, {String? view = 'poller'}) {
      fake.hill = {...fake.hill, 'isPoller': true, 'observerId': observerId};
      return pump(
        tester,
        pins: [
          nodePin({'observerId': observerId, 'view': ?view}),
        ],
        size: const Size(375, 844),
      );
    }

    bool asked() => fake.requests.any((u) => u.path.endsWith('/poller'));
    Finder tile(String id) => find.byKey(ValueKey('poller-$id'));
    Finder inTile(String id, String text) =>
        find.descendant(of: tile(id), matching: find.text(text));
    BeaconColors colors(WidgetTester tester) =>
        BeaconColors.of(tester.element(tile('claim')));

    testWidgets('is offered to a poller from any view', (tester) async {
      await open(tester, view: null);
      expect(find.text('OBSERVATIONS'), findsOneWidget);
      expect(tab('poller'), findsOneWidget);
      // Last, after Telemetry.
      expect(
        tester.getTopLeft(tab('poller')).dx,
        greaterThan(tester.getTopLeft(tab('telemetry')).dx),
      );
      await tester.tap(tab('poller'));
      await tester.pumpAndSettle();
      expect(tile('slots'), findsOneWidget);
      await close(tester);
    });

    testWidgets('shows its four tiles', (tester) async {
      final handle = tester.ensureSemantics();
      fake.pollerDoc = {
        'claim': {
          'receivedAt': DateTime.now().millisecondsSinceEpoch - 600000,
          'live': true,
          'acceptsRequests': true,
          'slots': {'max': 8, 'used': 3, 'own': 1, 'requested': 2, 'free': 3},
        },
        'readings24h': 46,
        'targets': [
          {'nodeId': 'a', 'role': 'poller', 'state': 'ok'},
          {'nodeId': 'b', 'role': 'poller', 'state': 'pending'},
          {'nodeId': 'c', 'role': 'standby', 'state': 'no_reply'},
          {'nodeId': 'd', 'role': 'poller', 'state': 'login_failed'},
        ],
      };
      await open(tester);
      expect(inTile('slots', 'SLOTS'), findsOneWidget);
      expect(inTile('slots', '3/8'), findsOneWidget);
      expect(inTile('slots', '1 own · 2 req'), findsOneWidget);
      expect(find.bySemanticsLabel('3 of 8 slots used'), findsOneWidget);
      final seats = tester
          .widgetList<PollerSeat>(
            find.descendant(
              of: tile('slots'),
              matching: find.byType(PollerSeat),
            ),
          )
          .map((s) => s.kind)
          .toList();
      expect(seats, [
        PollerSeatKind.own,
        PollerSeatKind.requested,
        PollerSeatKind.requested,
        PollerSeatKind.free,
        PollerSeatKind.free,
        PollerSeatKind.free,
        PollerSeatKind.notOffered,
        PollerSeatKind.notOffered,
      ]);

      expect(inTile('answering', 'ANSWERING'), findsOneWidget);
      expect(inTile('answering', '1'), findsOneWidget);
      expect(inTile('answering', 'of 4'), findsOneWidget);
      final c = colors(tester);
      expect(
        [
          for (var i = 0; i < 4; i++)
            (tester
                        .widget<Container>(
                          find.byKey(ValueKey('atlas-poller-dot-$i')),
                        )
                        .decoration!
                    as BoxDecoration)
                .color,
        ],
        [c.success, c.dim, c.warning, c.danger],
      );

      expect(inTile('readings', 'READINGS'), findsOneWidget);
      expect(inTile('readings', '46'), findsOneWidget);
      expect(inTile('readings', '24h'), findsOneWidget);

      expect(inTile('claim', 'LAST CLAIM'), findsOneWidget);
      final value = inTile('claim', '10m ago');
      expect(tester.widget<Text>(value).style!.color, c.bright);
      expect(inTile('claim', 'accepting requests'), findsOneWidget);
      // No tile picker on this view.
      expect(
        find.descendant(of: tile('slots'), matching: find.byType(TilePicker)),
        findsNothing,
      );
      handle.dispose();
      await close(tester);
    });

    testWidgets('says when requests are not accepted', (tester) async {
      fake.pollerDoc = {
        ...fake.pollerDoc!,
        'claim': {...fake.pollerDoc!['claim'] as Map, 'acceptsRequests': false},
      };
      await open(tester);
      expect(inTile('claim', 'not accepting requests'), findsOneWidget);
      await close(tester);
    });

    testWidgets('a stale claim is warned about on the tile and the footer', (
      tester,
    ) async {
      fake.pollerDoc = {
        ...fake.pollerDoc!,
        'claim': {
          ...fake.pollerDoc!['claim'] as Map,
          'receivedAt': DateTime.now().millisecondsSinceEpoch - 3 * 3600000,
          'live': false,
        },
      };
      await open(tester);
      final c = colors(tester);
      expect(
        tester.widget<Text>(inTile('claim', '3h ago')).style!.color,
        c.warning,
      );
      expect(inTile('claim', 'not currently polling'), findsOneWidget);
      expect(inTile('claim', 'accepting requests'), findsNothing);
      expect(find.text('Not currently polling'), findsOneWidget);
      expect(find.textContaining('Polling '), findsNothing);
      await close(tester);
    });

    testWidgets(
      'the footer counts the repeaters it polls; the open button goes to its view',
      (tester) async {
        fake.pollerDoc = {
          ...fake.pollerDoc!,
          'targets': [
            ...fake.pollerDoc!['targets'] as List,
            {'nodeId': 'c', 'role': 'standby', 'state': 'ok'},
          ],
        };
        await open(tester);
        expect(find.text('Polling 2 repeaters'), findsOneWidget);
        final dot = find.descendant(
          of: find
              .ancestor(
                of: find.text('Polling 2 repeaters'),
                matching: find.byType(Row),
              )
              .first,
          matching: find.byKey(const ValueKey('atlas-footer-dot')),
        );
        expect(
          (tester.widget<Container>(dot).decoration! as BoxDecoration).color,
          pollerColor,
        );
        expect(find.text('Poller view'), findsNothing);
        await tester.tap(find.byTooltip('Open node'));
        expect(opened, [('poller', nodeId)]);
        await close(tester);
      },
    );

    testWidgets('counts one repeater in the singular', (tester) async {
      fake.pollerDoc = {
        ...fake.pollerDoc!,
        'targets': [(fake.pollerDoc!['targets'] as List).first],
      };
      await open(tester);
      expect(find.text('Polling 1 repeater'), findsOneWidget);
      await close(tester);
    });

    testWidgets('the Observer view no longer carries a poller line', (
      tester,
    ) async {
      await open(tester, view: 'observer');
      expect(find.text('NOISE FLOOR'), findsOneWidget);
      expect(tab('poller'), findsOneWidget);
      expect(find.byKey(const ValueKey('atlas-poller-line')), findsNothing);
      expect(find.textContaining('Polling '), findsNothing);
      expect(find.text('Poller view'), findsNothing);
      await close(tester);
    });

    // Each falls back to Analytics, as a pinned Telemetry view does.
    testWidgets('is not offered to a node that is not a poller', (
      tester,
    ) async {
      await pump(
        tester,
        pins: [
          nodePin({'observerId': observerId, 'view': 'poller'}),
        ],
      );
      expect(asked(), isFalse);
      expect(tab('poller'), findsNothing);
      expect(find.text('OBSERVATIONS'), findsOneWidget);
      await close(tester);
    });

    testWidgets('is not offered and asks nothing with polling off', (
      tester,
    ) async {
      fake.polling = false;
      await open(tester);
      expect(asked(), isFalse);
      expect(tab('poller'), findsNothing);
      expect(find.text('OBSERVATIONS'), findsOneWidget);
      await close(tester);
    });

    testWidgets('is not offered on a server without the route', (tester) async {
      fake.pollerDoc = null;
      await open(tester);
      expect(asked(), isTrue);
      expect(tab('poller'), findsNothing);
      expect(find.text('OBSERVATIONS'), findsOneWidget);
      await close(tester);
    });

    testWidgets('is not offered to a radio with no claim', (tester) async {
      fake.pollerDoc = {'claim': null, 'readings24h': 0, 'targets': []};
      await open(tester);
      expect(asked(), isTrue);
      expect(tab('poller'), findsNothing);
      expect(find.text('OBSERVATIONS'), findsOneWidget);
      await close(tester);
    });

    testWidgets('is not offered to a poller with no observer', (tester) async {
      fake.hill = {...fake.hill, 'isPoller': true};
      await pump(
        tester,
        pins: [
          nodePin({'view': 'poller'}),
        ],
      );
      expect(asked(), isFalse);
      expect(tab('poller'), findsNothing);
      expect(find.text('OBSERVATIONS'), findsOneWidget);
      await close(tester);
    });

    testWidgets('pinning it saves the view on the pin', (tester) async {
      final prefs = await open(tester, view: null);
      await edit(tester);
      await tester.tap(tab('poller'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Make this the tab the card opens on'));
      await tester.pumpAndSettle();
      expect((savedPins(prefs).single as Map)['view'], 'poller');
      await close(tester);
    });
  });

  testWidgets('lays cards out in two and three columns on wide screens', (
    tester,
  ) async {
    await pump(
      tester,
      size: const Size(1000, 800),
      pins: [
        nodePin(),
        {'kind': 'node', 'id': otherId, 'publicKey': otherKey, 'name': 'Ridge'},
      ],
    );
    expect(
      tester.getTopLeft(find.text('Hill')).dy,
      tester.getTopLeft(find.text('Ridge')).dy,
    );
    expect(AtlasGrid.columnsFor(390), 1);
    expect(AtlasGrid.columnsFor(1300), 3);
    await close(tester);
  });

  test('the saved Atlas is kept per server', () async {
    SharedPreferences.setMockInitialValues({
      'beacon.atlas.$server': stored([nodePin()]),
    });
    final prefs = await Preferences.load();
    expect(parseAtlas(prefs.atlasFor(server)).pins, hasLength(1));
    expect(prefs.atlasFor('https://other.invalid'), isNull);
  });

  testWidgets('an observer add that outlives its sign-in writes nothing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({
      'beacon.servers': jsonEncode([
        {'name': 'Test', 'url': server},
      ]),
      'beacon.active': server,
      'beacon.atlas.synced.$server.u1': true,
      'beacon.atlas.synced.$server.u2': true,
    });
    final prefs = await Preferences.load();
    final tokens = MemoryTokenStore();
    await tokens.write(server, 'tok');
    final puts = <Map<String, dynamic>>[];
    final account = AccountState(
      AuthApi(
        server,
        tokens,
        client: MockClient((r) async {
          if (r.method == 'PUT') {
            puts.add(jsonDecode(r.body) as Map<String, dynamic>);
          }
          return http.Response(
            jsonEncode({
              'revision': 1,
              'range': '24h',
              'limit': 12,
              'pins': [],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      ),
    )..adopt({'id': 'u1'});
    final store = AtlasStore(prefs, server, account: account);
    await store.idle;
    await tester.pumpWidget(
      MaterialApp(
        theme: BeaconTheme.all.first.data,
        home: Scaffold(
          body: AtlasScreen(
            api: fake.api,
            preferences: prefs,
            store: store,
            onOpen: (_, _) {},
            clock: () => now,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('atlas-search-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Observer').last);
    await tester.pumpAndSettle();
    await search(tester, 'roof');
    fake.holdObserver = Completer();
    await tester.tap(find.text('Add'));
    await tester.pump();
    account.adopt(null);
    account.adopt({'id': 'u2'});
    await store.idle;
    fake.holdObserver!.complete();
    await tester.pumpAndSettle();
    await store.idle;
    expect(puts, isEmpty);
    expect(store.saved.pins, isEmpty);
    await close(tester);
  });

  // Last: its real font stays loaded for whatever runs after it.
  group('header tags', () {
    const typeChip = ValueKey('chip-type-repeater');
    const pollerChip = ValueKey('chip-poller');
    const observerChip = ValueKey('chip-observer');
    const tagRow = ValueKey('atlas-tags');

    testWidgets('one tag sits on the name\'s line', (tester) async {
      await pump(tester, pins: [nodePin()], size: const Size(375, 844));
      expect(find.byKey(tagRow), findsNothing);
      expect(find.byKey(pollerChip), findsNothing);
      expect(find.byKey(observerChip), findsNothing);
      expect(
        tester.getCenter(find.byKey(typeChip)).dy,
        tester.getCenter(find.text('Hill')).dy,
      );
      await close(tester);
    });

    testWidgets('one tag gets a row under the name on a narrow phone', (
      tester,
    ) async {
      await pump(tester, pins: [nodePin()], size: const Size(320, 800));
      for (final editing in [false, true]) {
        if (editing) await edit(tester);
        expect(find.byKey(tagRow), findsOneWidget);
        expect(
          tester.getTopLeft(find.byKey(typeChip)).dy,
          greaterThan(tester.getBottomLeft(find.text('Hill')).dy),
        );
      }
      await close(tester);
    });

    testWidgets('a poller\'s three tags get a row under the name at 375 px', (
      tester,
    ) async {
      await realFont(tester);
      fake.hill = {
        ...fake.hill,
        'name': 'A very long repeater name on a hill',
        'isPoller': true,
        'observerId': observerId,
      };
      await pump(tester, pins: [nodePin()], size: const Size(375, 844));
      await edit(tester);
      final name = find.text('A very long repeater name on a hill');
      final row = find.byKey(tagRow);
      for (final chip in [typeChip, pollerChip, observerChip]) {
        expect(
          find.descendant(of: row, matching: find.byKey(chip)),
          findsOneWidget,
        );
      }
      // All three on one line, under the name and the buttons, inside the card.
      final tops = {
        for (final chip in [typeChip, pollerChip, observerChip])
          tester.getTopLeft(find.byKey(chip)).dy,
      };
      expect(tops, hasLength(1));
      expect(tops.single, greaterThan(tester.getBottomLeft(name).dy));
      expect(
        tops.single,
        greaterThan(tester.getBottomLeft(find.byTooltip('Remove')).dy),
      );
      expect(
        tester.getTopLeft(find.byKey(typeChip)).dx,
        tester.getTopLeft(find.byTooltip('Recent')).dx,
      );
      expect(
        tester.getTopRight(find.byKey(observerChip)).dx,
        lessThan(tester.getTopRight(find.byTooltip('Drag to reorder')).dx),
      );
      expect(
        tester.getCenter(name).dy,
        tester.getCenter(find.byTooltip('Recent')).dy,
      );
      await close(tester);
    });

    testWidgets('an observing node gets the Observer tag', (tester) async {
      await pump(
        tester,
        pins: [
          nodePin({'observerId': observerId}),
        ],
      );
      expect(find.byKey(tagRow), findsOneWidget);
      expect(find.byKey(observerChip), findsOneWidget);
      expect(find.byKey(pollerChip), findsNothing);
      await close(tester);
    });

    testWidgets('an observer card keeps its one badge beside the name', (
      tester,
    ) async {
      await pump(
        tester,
        pins: [
          {'kind': 'observer', 'observerId': observerId, 'name': 'Roof'},
        ],
      );
      expect(find.byKey(tagRow), findsNothing);
      expect(
        tester.getCenter(find.text('MESHCORETOMQTT')).dy,
        tester.getCenter(find.text('Roof')).dy,
      );
      await close(tester);
    });
  });

  group('a poller card at 375 px', () {
    tearDown(() => language = 'en');
    const views = ['analytics', 'observer', 'telemetry', 'poller'];
    Future<void> open(WidgetTester tester) async {
      await realFont(tester);
      fake.hill = {...fake.hill, 'isPoller': true, 'observerId': observerId};
      await pump(
        tester,
        pins: [
          nodePin({'observerId': observerId}),
        ],
        size: const Size(375, 844),
      );
    }

    testWidgets('is the same height on every tile view', (tester) async {
      await open(tester);
      final heights = <String, double>{};
      for (final view in views) {
        await tester.tap(tab(view));
        await tester.pumpAndSettle();
        heights[view] = tester.getSize(find.byType(AtlasPanel)).height;
      }
      expect(heights['poller'], heights['observer']);
      expect(heights['poller'], heights['analytics']);
      // The list view is held to the tiles' height.
      await tester.tap(tab('heard'));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(AtlasPanel)).height, heights['poller']);
      await close(tester);
    });

    for (final code in supportedLanguages) {
      testWidgets('fits its five tabs and the Poller tab in $code', (
        tester,
      ) async {
        await open(tester);
        language = code;
        final bar = find.byType(AtlasTabs<AtlasView>);
        for (final view in [...views, 'heard']) {
          await tester.tap(tab(view));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          // The open tab's name is whole.
          final name = find.descendant(
            of: tab(view),
            matching: find.byType(Text),
          );
          final box = tester.renderObject<RenderParagraph>(name);
          expect(
            box.size.width,
            greaterThanOrEqualTo(
              box.getMaxIntrinsicWidth(double.infinity).floorToDouble(),
            ),
          );
          expect(
            tester.getRect(tab('poller')).right,
            lessThanOrEqualTo(tester.getRect(bar).right),
          );
        }
        await tester.tap(tab('poller'));
        await tester.pumpAndSettle();
        final card = tester.getRect(find.byType(AtlasPanel));
        for (final id in ['slots', 'answering', 'readings', 'claim']) {
          final tile = tester.getRect(find.byKey(ValueKey('poller-$id')));
          expect(tile.left, greaterThanOrEqualTo(card.left));
          expect(tile.right, lessThanOrEqualTo(card.right));
        }
        expect(tester.takeException(), isNull);
        await close(tester);
      });
    }
  });
}
