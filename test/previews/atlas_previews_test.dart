// Renders an Atlas card on its Telemetry tab to PNGs for review. Off in the normal run:
//   BEACON_PREVIEW=1 flutter test test/previews/atlas_previews_test.dart
// Output goes to BEACON_PREVIEW_DIR (default ../graphics/app-account).
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:beacon/core/api.dart';
import 'package:beacon/core/preferences.dart';
import 'package:beacon/core/theme.dart';
import 'package:beacon/features/atlas/atlas_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _on = Platform.environment['BEACON_PREVIEW'] != null;
final _dir =
    Platform.environment['BEACON_PREVIEW_DIR'] ?? '../graphics/app-account';
final _shot = GlobalKey();

const _server = 'https://test.invalid';
const _nodeId = '11111111-1111-4111-8111-111111111111';
const _observerId = '44444444-4444-4444-8444-444444444444';
final _key = 'ab' * 32;
final _now = DateTime.utc(2026, 11, 14, 12, 10);
final _tick = _now.millisecondsSinceEpoch;
final _hour = DateTime.utc(2026, 11, 14, 12).millisecondsSinceEpoch;

/// Counters over the hour that ends at each point, as the server reports them.
Map<String, dynamic> _point(int back, double wave) => {
  't': _hour - back * 3600000,
  'readings': 1,
  'batteryMv': (4120 - back * 2 + wave * 25).round(),
  'noiseFloorDb': (-108 + wave * 4).round(),
  'lastSnrDb': 8 + wave * 3,
  'lastRssiDb': -88 + (wave * 4).round(),
  'uptimeSeconds': back > 40 ? (72 - back) * 3600 : (40 - back) * 3600 + 900,
  'airtimeTxSecs': 28 + wave * 10,
  'airtimeRxSecs': 150 + wave * 60,
  'packetsReceived': (420 + wave * 90).round(),
  'packetsSent': (36 + wave * 9).round(),
  'receiveErrors': (12 + wave * 4).round(),
  'counterSpanSecs': 3600,
};

List<Map<String, dynamic>> _full() => [
  for (var back = 71; back >= 0; back--)
    _point(back, math.sin(back / 5) * .8 + math.cos(back / 2.3) * .2),
];

List<Map<String, dynamic>> _few() => [
  {..._point(14, .2), 'temperatureC': 14.8},
  {..._point(8, -.4), 'temperatureC': 15.6},
  {..._point(1, .5), 'temperatureC': 16.4},
];

Future<void> _fonts() async {
  for (final (family, file) in [
    ('Inter', 'assets/fonts/Inter.ttf'),
    ('JetBrainsMono', 'assets/fonts/JetBrainsMono.ttf'),
  ]) {
    final bytes = File(file).readAsBytesSync();
    await (FontLoader(
      family,
    )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
  }
  final sdk =
      Platform.environment['FLUTTER_ROOT'] ??
      File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.path;
  final icons = File(
    '$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (icons.existsSync()) {
    await (FontLoader(
          'MaterialIcons',
        )..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync()))))
        .load();
  }
}

void main() {
  setUpAll(() async {
    await _fonts();
    await BeaconTheme.load();
    Directory(_dir).createSync(recursive: true);
  });

  Future<void> shot(
    WidgetTester tester,
    String name, {
    required List<Map<String, dynamic>> readings,
    required String range,
    required double height,
  }) async {
    tester.view.physicalSize = Size(390 * 3, height * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({
      'beacon.servers': jsonEncode([
        {'name': 'Home mesh', 'url': _server},
      ]),
      'beacon.active': _server,
      'beacon.atlas.$_server': jsonEncode({
        'version': 2,
        'range': range,
        'pins': [
          {
            'kind': 'node',
            'id': _nodeId,
            'publicKey': _key,
            'name': 'Hilltop',
            'view': 'telemetry',
          },
        ],
      }),
    });
    final prefs = await Preferences.load();
    final node = {
      'id': _nodeId,
      'publicKey': _key,
      'name': 'Hilltop',
      'nodeTypeName': 'Repeater',
      'stale': false,
      'lastSeen': _tick - 180000,
      'knownNeighborCount': 9,
    };
    Object? reply(Uri url) {
      final path = url.path.replaceFirst('/api/v1', '');
      return switch (path) {
        '/info' => {
          'features': {'polling': true, 'atlasTelemetry': true},
        },
        '/nodes/$_nodeId' => node,
        '/nodes/$_nodeId/telemetry' => {
          'polled': true,
          'points': url.queryParameters['range'] == '720h' ? [] : readings,
        },
        '/nodes/$_nodeId/polling' => {
          'polled': true,
          'latestReadingAt': readings.last['t'],
          'poller': {'observerId': _observerId, 'name': 'HOWL V4.2'},
          'standbys': <dynamic>[],
        },
        '/nodes/$_nodeId/activity' => {
          'summary': {'observations': 0},
          'points': <dynamic>[],
          'latest': null,
        },
        _ => null,
      };
    }

    final api = ApiClient(
      Uri.parse(_server),
      transientRetries: 0,
      now: () => _now,
      client: MockClient((request) async {
        final body = reply(request.url);
        return body == null
            ? http.Response('{"error":{"message":"not found"}}', 404)
            : http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
      }),
    );
    await tester.pumpWidget(
      RepaintBoundary(
        key: _shot,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: BeaconTheme.all.firstWhere((t) => t.id == 'neutral-blue').data,
          home: Scaffold(
            body: AtlasScreen(
              api: api,
              preferences: prefs,
              onOpen: (_, _) {},
              clock: () => _now,
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.pump(const Duration(milliseconds: 600));
    await tester.runAsync(() async {
      final boundary =
          _shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$_dir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
    });
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('Atlas telemetry, three readings (dark)', (tester) async {
    await shot(
      tester,
      '11-atlas-telemetry-few-dark',
      readings: _few(),
      range: '24h',
      height: 560,
    );
  }, skip: !_on);

  testWidgets('Atlas telemetry, three days hourly (dark)', (tester) async {
    await shot(
      tester,
      '12-atlas-telemetry-full-dark',
      readings: _full(),
      range: '3d',
      height: 560,
    );
  }, skip: !_on);
}
