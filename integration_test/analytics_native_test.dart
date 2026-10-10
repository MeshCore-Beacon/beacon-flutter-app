import 'dart:io';

import 'package:beacon/core/api.dart';
import 'package:beacon/core/strings.dart';
import 'package:beacon/core/theme.dart';
import 'package:beacon/features/analytics/analytics_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'test_server.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('all nine analytics sections render live regional data', (
    tester,
  ) async {
    await Future.wait([BeaconTheme.load(), loadStrings()]);
    final api = ApiClient(Uri.parse(testServer));
    var converted = false;
    for (final tab in [
      'Mesh',
      'Traffic',
      'Signal',
      'Paths',
      'Scopes',
      'Talkers',
      'Clock Drift',
      'Compare Observers',
      'Neighbour Graph',
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: BeaconTheme.resolve('neutral-blue'),
          home: Scaffold(
            body: SafeArea(
              child: AnalyticsScreen(
                key: ValueKey(tab),
                api: api,
                region: const {'iatas': 'YOW'},
                initialTab: tab,
                onOpen: (_, _) {},
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      if (Platform.isAndroid && !converted) {
        await binding.convertFlutterSurfaceToImage();
        await tester.pump();
        converted = true;
      }
      expect(
        tester.takeException(),
        isNull,
        reason: '$tab renders without layout failures',
      );
      expect(
        find.text('Retry'),
        findsNothing,
        reason: '$tab must load successfully',
      );
      await binding.takeScreenshot(
        '${Platform.operatingSystem}-analytics-${tab.toLowerCase().replaceAll(' ', '-')}',
      );
      if (tab != 'Neighbour Graph') {
        final lists = find.byType(ListView);
        if (lists.evaluate().isNotEmpty) {
          await tester.drag(lists.first, const Offset(0, -650));
          await tester.pump(const Duration(seconds: 1));
          expect(
            tester.takeException(),
            isNull,
            reason: '$tab lower charts render without overflow',
          );
        }
      }
    }
    await tester.pumpWidget(const SizedBox());
    api.close();
  });
}
