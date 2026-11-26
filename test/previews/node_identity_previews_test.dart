// Renders the nodes list and node identity card to PNGs for review. Off in the normal run:
//   BEACON_PREVIEW=1 flutter test test/previews/node_identity_previews_test.dart
// Output goes to BEACON_PREVIEW_DIR (default ../graphics/node-identity).
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:beacon/core/api.dart';
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
    Platform.environment['BEACON_PREVIEW_DIR'] ?? '../graphics/node-identity';
final _shot = GlobalKey();

final _nodes = <Map<String, dynamic>>[
  {
    'id': 'n1',
    'name': 'MrAlders0n_G3_R1',
    'nodeTypeName': 'repeater',
    'isPoller': true,
    'isObserver': true,
    'defaultScope': '#yow',
    'radio': '910.525,62.5,7',
    'knownNeighborCount': 20,
    'lastSeen': 1,
    'iatas': [
      {'iata': 'YOW'},
    ],
  },
  {
    'id': 'n2',
    'name': 'Roof watcher',
    'nodeTypeName': 'repeater',
    'isObserver': true,
    'radio': '910.525,62.5,7',
    'knownNeighborCount': 3,
    'iatas': [
      {'iata': 'YUL'},
    ],
  },
  {
    'id': 'n3',
    'name': 'Pocket',
    'nodeTypeName': 'companion',
    'radio': '910.525,62.5,7',
  },
  {
    'id': 'n4',
    'name': 'Town board',
    'nodeTypeName': 'room_server',
    'radio': '910.525,62.5,7',
  },
  {
    'id': 'n5',
    'name': 'Far weather',
    'nodeTypeName': 'sensor',
    'possiblyForeign': true,
    'radio': '910.525,62.5,7',
  },
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
    String name,
    Widget child,
    double h,
  ) async {
    tester.view.physicalSize = Size(390 * 3, h * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        key: _shot,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: BeaconTheme.all.firstWhere((t) => t.id == 'neutral-blue').data,
          home: Scaffold(body: child),
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.runAsync(() async {
      final boundary =
          _shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$_dir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
    });
    await tester.pumpWidget(const SizedBox());
  }

  ApiClient api() => ApiClient(
    Uri.parse('https://test.invalid'),
    transientRetries: 0,
    client: MockClient((r) async {
      final path = r.url.path.replaceFirst('/api/v1', '');
      Object? body = switch (path) {
        '/nodes' => {'items': _nodes, 'hasMore': false},
        _ when path.startsWith('/nodes/') && path.split('/').length == 3 =>
          _nodes.firstWhere((n) => n['id'] == path.split('/').last),
        _ when path.endsWith('/observations') => {
          'items': [],
          'hasMore': false,
        },
        _ => <dynamic>[],
      };
      return http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
    }),
  );

  testWidgets('nodes list', (tester) async {
    await shot(
      tester,
      'nodes-list',
      DirectoryScreen(
        kind: 'nodes',
        api: api(),
        region: const {},
        onOpen: (_, _) {},
      ),
      700,
    );
  }, skip: !_on);

  for (final n in _nodes) {
    testWidgets('panel ${n['id']}', (tester) async {
      await shot(
        tester,
        'panel-${n['id']}',
        EntityDetailScreen(
          kind: 'node',
          id: '${n['id']}',
          api: api(),
          region: const {},
          onOpen: (_, _) {},
        ),
        520,
      );
    }, skip: !_on);
  }
}
