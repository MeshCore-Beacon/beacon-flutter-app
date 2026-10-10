import 'dart:io';

import 'package:beacon/core/api.dart';
import 'package:beacon/core/instance.dart';
import 'package:beacon/core/live.dart';
import 'package:beacon/core/strings.dart';
import 'package:beacon/core/theme.dart';
import 'package:beacon/features/packets/packet_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'test_server.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('searchable packet filter dropdowns', (tester) async {
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
    await tester.tap(find.byTooltip('Filters'));
    await wait(1);
    expect(find.byType(CheckboxListTile), findsNothing);
    await binding.takeScreenshot(
      '${Platform.operatingSystem}-filter-dropdowns',
    );
    await tester.tap(find.byKey(const ValueKey('filter-Payload type')));
    await wait(1);
    await tester.enterText(
      find.byKey(const ValueKey('search-Payload type')),
      'advert',
    );
    await wait(1);
    // Payload names use the protocol abbreviation.
    await tester.enterText(
      find.byKey(const ValueKey('search-Payload type')),
      'adv',
    );
    await wait(1);
    expect(find.widgetWithText(CheckboxListTile, 'ADVERT'), findsOneWidget);
    await tester.tap(find.widgetWithText(CheckboxListTile, 'ADVERT'));
    await wait(1);
    await binding.takeScreenshot('${Platform.operatingSystem}-filter-search');
    await tester.tap(find.byKey(const ValueKey('filter-Payload type')));
    await wait(1);
    FocusManager.instance.primaryFocus?.unfocus();
    await wait(1);
    await tester.tap(find.text('Clear all'));
    await wait(1);
    await tester.tap(find.text('Done'));
    await wait(1);
    expect(find.byKey(const ValueKey('filter-Payload type')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    live.dispose();
    api.close();
  });
}
