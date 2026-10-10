import 'dart:io';

import 'package:beacon/core/api.dart';
import 'package:beacon/features/map/map_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_server.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native map renders live API markers and survives style switch', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final api = ApiClient(Uri.parse(testServer));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: SafeArea(
            child: MapScreen(api: api, region: const {}, onOpen: (_, _) {}),
          ),
        ),
      ),
    );
    Future<void> wait(int seconds) async {
      for (var i = 0; i < seconds * 2; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
    }

    await wait(20);
    if (Platform.isAndroid) {
      await binding.convertFlutterSurfaceToImage();
      await tester.pumpAndSettle();
    }
    final labels = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .toList();
    debugPrint('MAP LABELS $labels');
    await binding.takeScreenshot(
      '${Platform.operatingSystem}-map-native-initial',
    );
    expect(tester.takeException(), isNull);
    expect(
      labels.any(
        (label) => RegExp(r' · [1-9][0-9]* visible').hasMatch(label ?? ''),
      ),
      true,
      reason: 'Native renderer must contain visible node/cluster features',
    );
    await tester.tap(find.text('Map Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Light'));
    await wait(12);
    await binding.takeScreenshot(
      '${Platform.operatingSystem}-map-native-light',
    );
    expect(tester.takeException(), isNull);
    final after = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .join(' ');
    expect(after, contains(RegExp(r' · [1-9][0-9]* visible')));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    api.close();
  });
}
