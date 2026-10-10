import 'dart:io';

import 'package:beacon/core/api.dart';
import 'package:beacon/core/instance.dart';
import 'package:beacon/core/live.dart';
import 'package:beacon/core/strings.dart';
import 'package:beacon/core/theme.dart';
import 'package:beacon/features/packets/packet_expansion.dart';
import 'package:beacon/features/packets/packet_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'test_server.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('edge-to-edge packet rows and tap-anywhere live resume', (
    tester,
  ) async {
    await Future.wait([BeaconTheme.load(), loadStrings()]);
    final server = BeaconInstance.create('Dev', testServer);
    final api = ApiClient(server.base);
    final live = LiveConnection(server.wsUri, const {});
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: BeaconTheme.resolve('neutral-blue'),
        home: Scaffold(
          appBar: AppBar(title: const Text('BEACON')),
          body: SafeArea(
            child: PacketScreen(
              api: api,
              region: const {},
              events: live.events,
              onOpen: (_, _) {},
            ),
          ),
        ),
      ),
    );
    live.start();
    Future<void> wait(int seconds) async {
      for (var i = 0; i < seconds * 2; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
    }

    await wait(7);
    expect(live.status, 'live');
    expect(find.byType(Card), findsWidgets);
    final row = tester.getRect(find.byType(Card).first);
    final screen = tester.getRect(find.byType(PacketScreen));
    expect(row.left, screen.left);
    expect(row.right, screen.right);
    if (Platform.isAndroid) {
      await binding.convertFlutterSurfaceToImage();
      await tester.pump();
    }
    final list = find.byType(ListView).first;
    await tester.drag(list, const Offset(0, -500));
    await wait(1);
    final banner = find.byKey(const ValueKey('resume-live-packets'));
    Future<void> awaitPending() async {
      for (var i = 0; i < 30 && banner.evaluate().isEmpty; i++) {
        await wait(1);
      }
      expect(banner, findsOneWidget);
    }

    await awaitPending();
    await binding.takeScreenshot(
      '${Platform.operatingSystem}-packets-paused-full-width',
    );
    final rect = tester.getRect(banner);
    await tester.tapAt(Offset(rect.left + 8, rect.center.dy));
    await wait(3);
    expect(tester.widget<ListView>(list).controller!.offset, 0);
    expect(banner, findsNothing);
    await tester.tap(find.byType(Card).first);
    await wait(2);
    expect(find.byType(PacketExpansion), findsOneWidget);
    await awaitPending();
    await tester.tap(banner);
    await wait(4);
    expect(find.byType(PacketExpansion), findsNothing);
    expect(banner, findsNothing);
    expect(tester.widget<ListView>(list).controller!.offset, 0);
    expect(tester.takeException(), isNull);
    await binding.takeScreenshot(
      '${Platform.operatingSystem}-packets-resumed-full-width',
    );
    await tester.pumpWidget(const SizedBox());
    live.dispose();
    api.close();
  });
}
