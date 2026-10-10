import 'package:beacon/app.dart';
import 'package:beacon/core/preferences.dart';
import 'package:beacon/core/strings.dart';
import 'package:beacon/core/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'compact settings pickers fit narrow screens and persist choices',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      await Future.wait([BeaconTheme.load(), loadStrings()]);
      final prefs = await Preferences.load();
      await tester.pumpWidget(
        BeaconApp(preferences: prefs, connectLive: false),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('theme-picker')));
      await tester.pumpAndSettle();
      final choice = BeaconTheme.all.firstWhere((e) => e.id != prefs.themeId);
      await tester.ensureVisible(find.text(choice.name).last);
      await tester.tap(find.text(choice.name).last);
      await tester.pumpAndSettle();
      expect(prefs.themeId, choice.id);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('language-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Français'));
      await tester.pumpAndSettle();
      expect(prefs.language, 'fr');
      expect(find.text('Réglages'), findsOneWidget);
      final reloaded = await Preferences.load();
      expect(reloaded.language, 'fr');
      expect(reloaded.themeId, choice.id);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      language = 'en';
    },
  );
}
