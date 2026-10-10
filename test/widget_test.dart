import 'dart:async';

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
  testWidgets('first launch offers server setup and settings', (tester) async {
    final prefs = await Preferences.load();
    await tester.pumpWidget(BeaconApp(preferences: prefs, connectLive: false));
    await tester.pumpAndSettle();
    expect(find.text('Connect to your mesh'), findsOneWidget);
    await tester.tap(find.text('Add server'));
    await tester.pumpAndSettle();
    final urlField = tester
        .widgetList<TextField>(find.byType(TextField))
        .singleWhere(
          (field) => field.decoration?.hintText == 'https://beacon-server.com',
        );
    expect(urlField.controller?.text, isEmpty);
  });
  testWidgets('mobile primary navigation and More expose all eight sections', (
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
    await tester.pump(const Duration(milliseconds: 500));
    for (final label in ['Packets', 'Channels', 'Map', 'Nodes', 'More']) {
      expect(find.text(label), findsOneWidget);
    }
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    for (final label in ['Observers', 'Routes', 'Traces', 'Analytics']) {
      expect(find.text(label), findsOneWidget);
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
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

  testWidgets('switching instance discards delayed old server response', (
    tester,
  ) async {
    final prefs = await Preferences.load();
    await prefs.saveServer(BeaconInstance.create('Old', 'https://old.test'));
    await prefs.saveServer(BeaconInstance.create('New', 'https://new.test'));
    await prefs.selectServer('https://old.test');
    final old = Completer<http.Response>();
    await tester.pumpWidget(
      BeaconApp(
        preferences: prefs,
        connectLive: false,
        apiFactory: (base) => ApiClient(
          base,
          client: MockClient((request) async {
            // Answer the version check so the old server's screens mount.
            if (request.url.path.endsWith('/info')) {
              return http.Response('{}', 404);
            }
            if (base.host == 'old.test') return old.future;
            return http.Response(
              '{"items":[{"packetHash":"new00000","payloadType":4,"lastHeardAt":1}],"hasMore":false}',
              200,
            );
          }),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(BeaconHome), findsOneWidget);
    await prefs.selectServer('https://new.test');
    await tester.pumpAndSettle();
    old.complete(
      http.Response(
        '{"items":[{"packetHash":"old00000","payloadType":4,"lastHeardAt":1}],"hasMore":false}',
        200,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('NEW00000'), findsOneWidget);
    expect(find.text('OLD00000'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
