// Renders the Packets and Nodes filter sheets to PNGs for review. Off in the normal run:
//   BEACON_PREVIEW=1 flutter test test/previews/filter_sheet_previews_test.dart
// Output goes to BEACON_PREVIEW_DIR (default ../graphics/filter-sheets).
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:beacon/core/api.dart';
import 'package:beacon/core/theme.dart';
import 'package:beacon/features/directory/directory.dart';
import 'package:beacon/features/packets/packet_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final _on = Platform.environment['BEACON_PREVIEW'] != null;
final _dir =
    Platform.environment['BEACON_PREVIEW_DIR'] ?? '../graphics/filter-sheets';
final _shot = GlobalKey();

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

  ApiClient api() => ApiClient(
    Uri.parse('https://test.invalid'),
    transientRetries: 0,
    client: MockClient((r) async {
      final body = r.url.path.endsWith('/scopes')
          ? ['#yow', '#yul']
          : {'items': <dynamic>[], 'hasMore': false};
      return http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
    }),
  );

  Future<void> sheet(WidgetTester tester, String name, Widget screen) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        key: _shot,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: BeaconTheme.all.firstWhere((t) => t.id == 'neutral-blue').data,
          home: Scaffold(body: screen),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Filters'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final boundary =
          _shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$_dir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
    });
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('packets sheet', (tester) async {
    await sheet(
      tester,
      'packets-sheet',
      PacketScreen(api: api(), region: const {}, onOpen: (_, _) {}),
    );
  }, skip: !_on);

  testWidgets('nodes sheet', (tester) async {
    await sheet(
      tester,
      'nodes-sheet',
      DirectoryScreen(
        kind: 'nodes',
        api: api(),
        region: const {},
        onOpen: (_, _) {},
      ),
    );
  }, skip: !_on);
}
