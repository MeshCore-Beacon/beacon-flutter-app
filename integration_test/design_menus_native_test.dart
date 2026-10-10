import 'dart:convert';
import 'dart:io';

import 'package:beacon/app.dart';
import 'package:beacon/core/api.dart';
import 'package:beacon/core/instance.dart';
import 'package:beacon/core/preferences.dart';
import 'package:beacon/core/strings.dart';
import 'package:beacon/core/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;
  testWidgets('menus follow dark cyan and light palettes', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await Future.wait([BeaconTheme.load(), loadStrings()]);
    // Exercise light contrast without changing the production theme catalog.
    final palettes =
        jsonDecode(await rootBundle.loadString('assets/themes.json')) as List;
    final light =
        palettes.firstWhere((t) => t['id'] == 'meshmapper_light') as Map;
    BeaconTheme.all.add(
      BeaconTheme(
        light['id'] as String,
        light['name'] as String,
        Map<String, dynamic>.from(light['vars'] as Map),
      ),
    );
    final prefs = await Preferences.load();
    await prefs.saveServer(
      BeaconInstance.create('Beacon Dev', 'https://example.test'),
    );
    await tester.pumpWidget(
      BeaconApp(
        preferences: prefs,
        connectLive: false,
        apiFactory: (base) => ApiClient(
          base,
          client: MockClient(
            (request) async => http.Response(
              jsonEncode(
                request.url.path.endsWith('/scopes')
                    ? <String>[]
                    : {'items': []},
              ),
              200,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (Platform.isAndroid) {
      await binding.convertFlutterSurfaceToImage();
      await tester.pump();
    }
    for (final theme in ['neutral-blue', 'cyberpunk', 'meshmapper_light']) {
      await prefs.setTheme(theme);
      await tester.pumpAndSettle();
      await tester.tap(find.text('More').last);
      await tester.pumpAndSettle();
      await binding.takeScreenshot('${Platform.operatingSystem}-$theme-more');
      await tester.tap(find.text('Observers').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await binding.takeScreenshot(
        '${Platform.operatingSystem}-$theme-settings',
      );
      await tester.tap(find.byKey(const ValueKey('theme-picker')));
      await tester.pumpAndSettle();
      await binding.takeScreenshot(
        '${Platform.operatingSystem}-$theme-theme-menu',
      );
      final choice = find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text(
          BeaconTheme.all.firstWhere((t) => t.id == theme).name,
        ),
      );
      await tester.scrollUntilVisible(
        choice,
        250,
        scrollable: find.byType(Scrollable).last,
      );
      await Scrollable.ensureVisible(tester.element(choice), alignment: 0.5);
      await tester.pumpAndSettle();
      await tester.tap(choice);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('language-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('English').last);
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
  });
}
