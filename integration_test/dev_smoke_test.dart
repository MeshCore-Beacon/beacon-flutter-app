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

  testWidgets('live dev server native mobile journeys', (tester) async {
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
    await screenshot('02-packet-analyzer');
    await tester.pageBack();
    await wait(tester, 1);
    for (final name in ['Channels', 'Nodes']) {
      await tester.tap(find.text(name).last);
      await wait(tester, 5);
      expect(
        tester.takeException(),
        isNull,
        reason: '$name must render without exceptions',
      );
      await screenshot('03-${name.toLowerCase()}');
    }
    await tester.tap(find.text('Map').last);
    await wait(tester, 12);
    expect(tester.takeException(), isNull, reason: 'MapLibre must render');
    await screenshot('04-map');
    for (final name in ['Observers', 'Routes', 'Traces', 'Analytics']) {
      await tester.tap(find.text('More').last);
      await tester.pumpAndSettle();
      await screenshot('menu-more');
      await tester.tap(find.text(name).last);
      await wait(tester, 8);
      expect(
        tester.takeException(),
        isNull,
        reason: '$name must render without exceptions',
      );
      await screenshot('05-${name.toLowerCase()}');
    }
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('APPEARANCE'), findsOneWidget);
    expect(find.text('Language'), findsOneWidget);
    await screenshot('06-settings');
    await tester.tap(find.byKey(const ValueKey('language-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Français'));
    await tester.pumpAndSettle();
    expect(preferences.language, 'fr');
    expect(find.text('Réglages'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('language-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await wait(tester, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
