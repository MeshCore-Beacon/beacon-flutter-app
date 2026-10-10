import 'dart:async';

import 'package:beacon/app.dart';
import 'package:beacon/core/api.dart';
import 'package:beacon/core/instance.dart';
import 'package:beacon/core/preferences.dart';
import 'package:beacon/core/strings.dart';
import 'package:beacon/core/theme.dart';
import 'package:beacon/core/version_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Fake Beacon servers keyed by host. `/api/v1/info` answers from [info]
/// (a status code, a body, or an exception); every other path returns an
/// empty list and is recorded in [reads] so tests can prove a blocked server
/// got no traffic beyond the check.
class FakeServers {
  final info = <String, Object>{};
  final reads = <String, List<String>>{};
  final infoCalls = <String, int>{};
  ApiClient call(Uri base) => ApiClient(
    base,
    client: MockClient((request) async {
      final host = request.url.host;
      if (request.url.path.endsWith('/api/v1/info')) {
        infoCalls[host] = (infoCalls[host] ?? 0) + 1;
        final answer = info[host] ?? 404;
        if (answer is Exception) throw answer;
        if (answer is Future<http.Response>) return answer;
        if (answer is int) return http.Response('{}', answer);
        return http.Response(answer as String, 200);
      }
      (reads[host] ??= []).add(request.url.path);
      return http.Response('{"items":[],"hasMore":false}', 200);
    }),
  );
}

void main() {
  late Preferences prefs;
  late FakeServers servers;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await BeaconTheme.load();
    await loadStrings();
    prefs = await Preferences.load();
    servers = FakeServers()
      ..info['blocked.test'] = '{"minAppVersion":"0.2.0"}'
      ..info['open.test'] = '{"minAppVersion":"0.1.0","serverVersion":"1.0.0"}'
      ..info['old.test'] = 404
      ..info['down.test'] = http.ClientException('Connection refused');
  });

  Future<void> launch(
    WidgetTester tester,
    String active, {
    bool settle = true,
  }) async {
    for (final host in ['open', 'old', 'down', 'blocked']) {
      await prefs.saveServer(
        BeaconInstance.create(
          '${host[0].toUpperCase()}${host.substring(1)}',
          'https://$host.test',
        ),
      );
    }
    await prefs.selectServer('https://$active.test');
    await tester.pumpWidget(
      BeaconApp(
        preferences: prefs,
        connectLive: false,
        apiFactory: servers.call,
        versionGate: VersionGate(
          fetchInfo: VersionGate.apiFetcher(servers.call),
          appVersion: () async => '0.1.0',
          installerStore: () async => 'com.android.vending',
        ),
      ),
    );
    settle ? await tester.pumpAndSettle() : await tester.pump();
  }

  Future<void> switchTo(WidgetTester tester, String name) async {
    await tester.tap(find.text('Use another server'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(name).last);
    await tester.pumpAndSettle();
  }

  void expectBlocked() {
    expect(find.text('Update BEACON to continue'), findsOneWidget);
    expect(
      find.text(
        'This server needs a newer version of the app. Update BEACON if you want to continue connecting to this server:',
      ),
      findsOneWidget,
    );
    expect(find.text('https://blocked.test'), findsOneWidget);
    expect(find.text('Your version: 0.1.0 · Needed: 0.2.0'), findsOneWidget);
    expect(find.text('Update BEACON'), findsOneWidget);
    expect(find.byType(BeaconHome), findsNothing);
    expect(find.text('Packets'), findsNothing);
  }

  void expectContent() {
    expect(find.text('Update BEACON to continue'), findsNothing);
    expect(find.byType(BeaconHome), findsOneWidget);
    for (final label in ['Packets', 'Channels', 'Map', 'Nodes']) {
      expect(find.text(label), findsWidgets);
    }
  }

  testWidgets('blocked server shows the update screen and switching '
      'between servers re-applies the block', (tester) async {
    await launch(tester, 'blocked');
    expectBlocked();
    expect(servers.reads['blocked.test'], isNull);

    await switchTo(tester, 'Open');
    expectContent();
    expect(servers.reads['open.test'], isNotEmpty);

    await tester.tap(find.byTooltip('Servers: Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Blocked').last);
    await tester.pumpAndSettle();
    expectBlocked();
    expect(servers.reads['blocked.test'], isNull);
    expect(servers.infoCalls['blocked.test'], greaterThanOrEqualTo(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('servers without the endpoint or unreachable are not blocked', (
    tester,
  ) async {
    await launch(tester, 'old');
    expectContent();
    await tester.tap(find.byTooltip('Servers: Old'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Down').last);
    await tester.pumpAndSettle();
    expectContent();
    expect(servers.infoCalls['down.test'], 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a slow check shows a loading state, then fails open', (
    tester,
  ) async {
    final never = Completer<http.Response>();
    servers.info['open.test'] = never.future;
    await launch(tester, 'open', settle: false);
    expect(find.byType(ServerCheckScreen), findsOneWidget);
    expect(find.byType(BeaconHome), findsNothing);
    await tester.pump(const Duration(seconds: 3));
    expect(find.byType(ServerCheckScreen), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expectContent();
    await tester.pumpWidget(const SizedBox());
    // Let the abandoned request's own timeout expire.
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('resume re-checks the active server', (tester) async {
    await launch(tester, 'open');
    expectContent();
    servers.info['open.test'] = '{"minAppVersion":"1.0.0"}';
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
    expect(find.text('Update BEACON to continue'), findsOneWidget);
    expect(find.byType(BeaconHome), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('adding a blocked server skips the API probe and blocks it', (
    tester,
  ) async {
    await launch(tester, 'open');
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add server'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Fresh');
    await tester.enterText(fields.at(1), 'https://fresh.test');
    servers.info['fresh.test'] = '{"minAppVersion":"0.3.0"}';
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Update BEACON to continue'), findsOneWidget);
    expect(
      find.text(
        'This server needs a newer version of the app. Update BEACON if you want to continue connecting to this server:',
      ),
      findsOneWidget,
    );
    expect(servers.reads['fresh.test'], isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('update screen is translated', (tester) async {
    await prefs.setLanguage('sv');
    await launch(tester, 'blocked');
    expect(find.text('Uppdatera BEACON för att fortsätta'), findsOneWidget);
    expect(
      find.text(
        'Den här servern kräver en nyare version av appen. Uppdatera BEACON om du vill fortsätta ansluta till den här servern:',
      ),
      findsOneWidget,
    );
    expect(find.text('Använd en annan server'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    language = 'en';
  });
}
