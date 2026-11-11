import 'package:beacon/app.dart';
import 'package:beacon/core/api.dart';
import 'package:beacon/core/instance.dart';
import 'package:beacon/core/preferences.dart';
import 'package:beacon/core/strings.dart';
import 'package:beacon/core/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await BeaconTheme.load();
    await loadStrings();
  });

  Future<Finder> launch(WidgetTester tester, Size size, double scale) async {
    tester.view.physicalSize = size * 3;
    tester.view.devicePixelRatio = 3;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    final prefs = await Preferences.load();
    await prefs.saveServer(
      BeaconInstance.create('Dev', 'https://beacon.example.com'),
    );
    await tester.pumpWidget(
      BeaconApp(
        preferences: prefs,
        connectLive: false,
        apiFactory: (base) => ApiClient(
          base,
          client: MockClient(
            (r) async => http.Response('{"items":[],"hasMore":false}', 200),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    return find.byType(FeedScope);
  }

  for (final (name, size) in [
    ('portrait', const Size(360, 800)),
    ('landscape', const Size(800, 360)),
  ]) {
    testWidgets('region selector opens the picker in $name', (tester) async {
      await tester.tap(await launch(tester, size, 1));
      await tester.pumpAndSettle();
      expect(find.byType(RegionSheet), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('region selector keeps its room in $name with large text', (
      tester,
    ) async {
      final scope = await launch(tester, size, 2);
      // Room for at least the live dot and the chevron.
      expect(tester.getSize(scope).width, greaterThanOrEqualTo(45));
      expect(scope.hitTestable(), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
