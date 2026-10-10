import 'dart:io';

import 'package:beacon/app.dart';
import 'package:beacon/core/preferences.dart';
import 'package:beacon/core/strings.dart';
import 'package:beacon/core/theme.dart';
import 'package:beacon/features/packets/packet_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  Future<void> wait(WidgetTester tester, int seconds) async {
    for (var i = 0; i < seconds * 2; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
  }

  Future<void> screenshot(String name) async {
    await binding.takeScreenshot('${Platform.operatingSystem}-$name');
  }

  testWidgets('compact packet analyzer layout', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await Future.wait([BeaconTheme.load(), loadStrings()]);
    final preferences = await Preferences.load();
    await tester.pumpWidget(BeaconApp(preferences: preferences));
    await tester.pumpAndSettle();
    if (Platform.isAndroid) {
      await binding.convertFlutterSurfaceToImage();
      await tester.pump();
    }
    await tester.tap(find.text('Add server'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await wait(tester, 8);
    expect(find.byType(PacketScreen), findsOneWidget);
    expect(find.byType(PacketBadge), findsWidgets);
    await screenshot('01-packets');
    await tester.tap(find.byType(PacketBadge).first);
    await wait(tester, 5);
    await screenshot('01-packet-expanded');
    for (
      var attempt = 0;
      attempt < 12 &&
          find.text('Open analyzer').hitTestable().evaluate().isEmpty;
      attempt++
    ) {
      await tester.ensureVisible(find.text('Open analyzer'));
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.text('Open analyzer').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Open analyzer'));
    await wait(tester, 4);
    expect(find.text('Packet analyzer'), findsOneWidget);
    await tester.tap(find.text('OBSERVATIONS'));
    await wait(tester, 1);
    await screenshot('analyzer-web-layout');
    expect(tester.takeException(), isNull);
    expect(find.text('SUMMARY'), findsOneWidget);
    expect(find.text('Map all paths'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
