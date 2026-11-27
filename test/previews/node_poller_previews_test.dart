// Renders the node screen's Poller view to PNGs for review. Off in the normal run:
//   BEACON_PREVIEW=1 flutter test test/previews/node_poller_previews_test.dart
// Output goes to BEACON_PREVIEW_DIR (default ../graphics/node-poller).
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:beacon/core/api.dart';
import 'package:beacon/core/strings.dart';
import 'package:beacon/core/theme.dart';
import 'package:beacon/features/directory/directory.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final _on = Platform.environment['BEACON_PREVIEW'] != null;
final _dir =
    Platform.environment['BEACON_PREVIEW_DIR'] ?? '../graphics/node-poller';
final _shot = GlobalKey();

const _min = 60000;
final _now = DateTime.now().millisecondsSinceEpoch;

Map<String, dynamic> _target(
  String name,
  String key, {
  bool requested = false,
  String role = 'poller',
  int? rank,
  String state = 'ok',
  int misses = 0,
  int? lastOk,
  double? claimedSnr,
  double? evidenceSnr,
  int evidenceCount = 0,
  int? reading,
}) => {
  'nodeId': 'n-$key',
  'publicKey': key.padRight(64, '0'),
  'name': name.isEmpty ? null : name,
  'requested': requested,
  'role': role,
  'rank': rank,
  'state': state,
  'misses': misses,
  'lastOk': lastOk == null ? null : _now - lastOk * _min,
  'claimedSnr': claimedSnr,
  'evidenceSnr': evidenceSnr,
  'evidenceCount': evidenceCount,
  'latestReadingAt': reading == null ? null : _now - reading * _min,
};

Map<String, dynamic> _poller({bool live = true}) => {
  'claim': {
    'receivedAt': _now - (live ? 12 : 180) * _min,
    'live': live,
    'acceptsRequests': true,
    'slots': {'max': 8, 'used': 5, 'own': 3, 'requested': 2, 'free': 2},
  },
  'readings24h': 212,
  'targets': [
    _target(
      'MrAlders0n_G3_R2',
      '5be1c07a',
      lastOk: 14,
      claimedSnr: 11.25,
      evidenceSnr: 10.4,
      evidenceCount: 22,
      reading: 14,
    ),
    _target(
      'Carp Ridge Solar with a rather long name',
      '91d02e44',
      lastOk: 21,
      claimedSnr: 7.5,
      evidenceSnr: 6.9,
      evidenceCount: 9,
      reading: 21,
    ),
    _target(
      'Kanata North Tower',
      'c4470b19',
      requested: true,
      role: 'standby',
      rank: 1,
      state: 'no_reply',
      misses: 3,
      lastOk: 190,
      claimedSnr: 3.25,
      evidenceSnr: 2.1,
      evidenceCount: 4,
      reading: 31,
    ),
    _target(
      '',
      '0e88a3f2',
      requested: true,
      state: 'pending',
      evidenceSnr: 8,
      evidenceCount: 6,
    ),
    _target(
      'Almonte Hilltop',
      '7a31ffde',
      role: 'unassigned',
      state: 'not_direct',
      misses: 1,
      claimedSnr: -4.5,
    ),
  ],
};

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

  ApiClient api(bool live) => ApiClient(
    Uri.parse('https://test.invalid'),
    transientRetries: 0,
    client: MockClient((r) async {
      final path = r.url.path.replaceFirst('/api/v1', '');
      final Object body = switch (path) {
        '/info' => {
          'features': {'polling': true},
        },
        '/nodes/n1' => {
          'id': 'n1',
          'name': 'MrAlders0n_G3_R1',
          'publicKey': '8426a02c7f1d93b05e6a4c2d18f0b7e39a5d6c41f2e8b70394ad1c5e6f708192',
          'nodeTypeName': 'repeater',
          'isPoller': true,
          'isObserver': true,
          'observerId': 'o1',
          'lastSeen': _now - 2 * _min,
        },
        '/nodes/n1/poller' => _poller(live: live),
        _ when path.endsWith('/observations') => {
          'items': [],
          'hasMore': false,
        },
        _ => <dynamic>[],
      };
      return http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
    }),
  );

  for (final live in [true, false]) {
    testWidgets('poller view, ${live ? 'live' : 'stale'} claim', (
      tester,
    ) async {
      // iPhone 14 width, tall enough to show every card.
      tester.view.physicalSize = const Size(390 * 3, 1180 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        RepaintBoundary(
          key: _shot,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: BeaconTheme.all
                .firstWhere((t) => t.id == 'neutral-blue')
                .data,
            home: EntityDetailScreen(
              kind: 'node',
              id: 'n1',
              api: api(live),
              region: const {},
              onOpen: (_, _) {},
            ),
          ),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      await tester.tap(find.text(trKey('nodePoller.tab')));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      await tester.runAsync(() async {
        final boundary =
            _shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 3);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$_dir/poller-${live ? 'live' : 'stale'}.png')
            .writeAsBytesSync(data!.buffer.asUint8List());
      });
      await tester.pumpWidget(const SizedBox());
    }, skip: !_on);
  }
}
