import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/core/preferences.dart';
import 'package:beacon/core/theme.dart';
import 'package:beacon/features/atlas/atlas.dart';
import 'package:beacon/features/atlas/atlas_grid.dart';
import 'package:beacon/features/atlas/atlas_screen.dart';
import 'package:beacon/features/atlas/atlas_widgets.dart';
import 'package:flutter/material.dart';
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
String stored(List<Map<String, dynamic>> pins) =>
    jsonEncode({'version': 2, 'range': '24h', 'pins': pins});

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
  bool activity404 = false;

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
    'beacon.atlas.$server': ?(pins == null ? null : stored(pins)),
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

void main() {
  // Asset loads never finish inside a widget test's fake clock.
  setUp(() async {
    fake = Server();
    await BeaconTheme.load();
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
    await tester.tap(find.text('Heard by'));
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
    expect(find.text('Last seen 3m ago'), findsOneWidget);
    expect(find.text('Mean hops 2.3 · Neighbors (5)'), findsOneWidget);
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

  testWidgets('says so when the server has no node activity', (tester) async {
    fake.activity404 = true;
    await pump(tester, pins: [nodePin()]);
    expect(find.text('—'), findsWidgets);
    await tester.tap(find.text('Heard by'));
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
    await tester.tap(find.text('Heard by'));
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
    expect(find.byTooltip('The card opens on this tab'), findsOneWidget);
    await tester.tap(find.text('Heard by'));
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
      expect(find.text('Heard by'), findsOneWidget);
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

  testWidgets('removes a card', (tester) async {
    final prefs = await pump(
      tester,
      pins: [
        nodePin(),
        {'kind': 'node', 'id': otherId, 'publicKey': otherKey, 'name': 'Ridge'},
      ],
    );
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

  testWidgets('the card header stays on one line, the name giving way', (
    tester,
  ) async {
    fake.hill = {...fake.hill, 'name': 'A very long repeater name on a hill'};
    await pump(tester, pins: [nodePin()]);
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
}
