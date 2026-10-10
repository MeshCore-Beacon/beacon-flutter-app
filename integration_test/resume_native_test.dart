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
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await BeaconTheme.load();
    await loadStrings();
  });
  testWidgets('analytics selection survives app background and resume', (
    tester,
  ) async {
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
    await tester.pumpAndSettle();
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Analytics'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Mesh'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('RF / Signal').last);
    await tester.pumpAndSettle();
    expect(find.text('RF / Signal'), findsOneWidget);
    await tester.tap(find.text('7d'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('24h').last);
    await tester.pumpAndSettle();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(find.text('RF / Signal'), findsOneWidget);
    expect(find.text('Mesh'), findsNothing);
    expect(find.text('24h'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
