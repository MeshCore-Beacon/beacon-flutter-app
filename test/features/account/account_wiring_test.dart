import 'dart:convert';

import 'package:beacon/app.dart';
import 'package:beacon/core/account.dart';
import 'package:beacon/core/api.dart';
import 'package:beacon/core/auth_api.dart';
import 'package:beacon/core/instance.dart';
import 'package:beacon/core/preferences.dart';
import 'package:beacon/core/push.dart';
import 'package:beacon/core/push_store.dart';
import 'package:beacon/core/token_store.dart';
import 'package:beacon/features/account/sign_in.dart';
import 'package:beacon/features/directory/entity_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../fake_push.dart';
import 'harness.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await loadAssets();
  });

  late MemoryTokenStore tokens;
  late AccountRegistry registry;
  late List<Uri> launched;
  late int meCalls;
  late bool pushMode;
  late List<String> deviceCalls;
  late List<http.Request> relaySeen;

  http.Response serve(http.Request r) {
    final path = r.url.path.replaceFirst('/api/v1', '');
    if (path == '/info') {
      return json(200, {
        'features': {
          'accounts': 'local',
          if (pushMode) ...{
            'alerts': true,
            'alertChannels': {'email': false, 'push': true},
            'push': {'server': 'https://push.example', 'pushId': 'inst_a'},
          },
        },
      });
    }
    if (path == '/me/alerts') {
      return json(200, {
        'channels': {
          'push': {'available': true, 'enabled': true, 'hasDevice': false},
        },
        'targets': [],
      });
    }
    if (path == '/me/devices') {
      deviceCalls.add(r.method);
      return http.Response('', 204);
    }
    if (path == '/me') {
      meCalls++;
      return json(200, {'user': user()});
    }
    if (path == '/auth/app/token') {
      return json(200, {'token': 'new-token', 'expiresAt': 1, 'user': user()});
    }
    return json(200, {'items': [], 'hasMore': false});
  }

  Future<SignInFlow> pumpApp(
    WidgetTester tester, {
    FakePush? push,
    PushStore? store,
    String? other,
  }) async {
    final prefs = await Preferences.load(tokens: tokens);
    if (other != null) {
      await prefs.saveServer(BeaconInstance.create('Other mesh', other));
    }
    await prefs.saveServer(BeaconInstance.create('Home mesh', server));
    final flow = SignInFlow(
      apiFor: (url) =>
          AuthApi(url, tokens, client: MockClient((r) async => serve(r))),
      launch: (uri) async {
        launched.add(uri);
        return true;
      },
      now: DateTime.now,
      accountFor: (url) => registry[url],
    );
    await tester.pumpWidget(
      BeaconApp(
        preferences: prefs,
        connectLive: false,
        tokens: tokens,
        accounts: registry,
        signInFlow: flow,
        push: push == null
            ? null
            : fakeHub(push, relaySeen: relaySeen, store: store),
        authFactory: (url, store) =>
            AuthApi(url, store, client: MockClient((r) async => serve(r))),
        apiFactory: (base) =>
            ApiClient(base, client: MockClient((r) async => serve(r))),
      ),
    );
    await tester.pumpAndSettle();
    return flow;
  }

  Future<void> openSettings(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('ACCOUNT ON HOME MESH'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  setUp(() {
    tokens = MemoryTokenStore();
    registry = AccountRegistry();
    launched = [];
    meCalls = 0;
    pushMode = false;
    deviceCalls = [];
    relaySeen = [];
  });

  testWidgets('a browser sign-in shows the user without a restart', (
    tester,
  ) async {
    final flow = await pumpApp(tester);
    expect(meCalls, 0);
    await openSettings(tester);
    await tester.tap(find.text('Sign in'));
    // The waiting spinner never settles.
    await tester.pump();
    expect(launched, hasLength(1));
    await flow.handleCallback(
      Uri.parse('meshcorebeacon://auth?code=c&state=${flow.pending!.state}'),
    );
    await tester.pumpAndSettle();
    expect(find.text('Ridge Walker'), findsOneWidget);
    expect(await tokens.read(server), 'new-token');
  });

  testWidgets('a saved token signs in at start and again on resume', (
    tester,
  ) async {
    await tokens.write(server, 'tok');
    await pumpApp(tester);
    expect(meCalls, 1);
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
    expect(meCalls, 2);
    await openSettings(tester);
    expect(find.text('Ridge Walker'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
  });

  testWidgets('each server row says which account it is signed in to', (
    tester,
  ) async {
    const other = 'https://other.example';
    await tokens.write(server, 'tok');
    await tokens.write(other, 'tok2');
    SharedPreferences.setMockInitialValues({
      'beacon.account.$other': 'Valley Runner',
    });
    await pumpApp(tester, other: other);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Signed in as Ridge Walker'), findsOneWidget);
    expect(find.text('Signed in as Valley Runner'), findsOneWidget);

    await tokens.delete(other);
    await tester.tap(find.text('Home mesh'));
    await tester.pumpAndSettle();
    expect(find.text('Signed in as Valley Runner'), findsNothing);
  });

  testWidgets(
    'a signed-in phone with push granted registers, then removes it',
    (tester) async {
      pushMode = true;
      await tokens.write(server, 'tok');
      final push = FakePush(state: PushPermission.granted);
      addTearDown(push.close);
      await pumpApp(tester, push: push);
      expect(deviceCalls, ['POST']);
      final account = registry[server]!;
      await account.signOut();
      await tester.pumpAndSettle();
      expect(deviceCalls, ['POST', 'DELETE']);
      expect([for (final r in relaySeen) r.method], ['POST', 'DELETE']);
    },
  );

  testWidgets('without Firebase configuration nothing is requested', (
    tester,
  ) async {
    pushMode = true;
    await tokens.write(server, 'tok');
    final push = FakePush(isAvailable: false);
    addTearDown(push.close);
    await pumpApp(tester, push: push);
    expect(deviceCalls, isEmpty);
    expect(push.calls, isNot(contains('request')));
    expect(push.calls, isNot(contains('token')));
    expect(relaySeen, isEmpty);
  });

  testWidgets('removing a server removes its push device and handle', (
    tester,
  ) async {
    pushMode = true;
    await tokens.write(server, 'tok');
    final push = FakePush(state: PushPermission.granted);
    addTearDown(push.close);
    await pumpApp(tester, push: push);
    expect(deviceCalls, ['POST']);
    // The app's own Preferences holds the hook; reach it through the widget.
    final app = tester.widget<BeaconApp>(find.byType(BeaconApp));
    await app.preferences.removeServer(server);
    await tester.pumpAndSettle();
    expect(deviceCalls, ['POST', 'DELETE']);
    expect([for (final r in relaySeen) r.method], ['POST', 'DELETE']);
    expect(app.preferences.servers, isEmpty);
  });

  testWidgets('a tap for another saved server switches to it and opens', (
    tester,
  ) async {
    const other = 'https://other.example.com';
    final store = MemoryPushStore();
    await store.write(
      PushEntry(
        pushId: 'inst_b',
        relay: Uri.parse('https://push.example'),
        handle: 'h_b',
        handleSecret: 's_b',
        key: base64.encode(List.filled(32, 1)),
        url: other,
        name: 'Other mesh',
      ),
    );
    final push = FakePush();
    addTearDown(push.close);
    await pumpApp(tester, push: push, store: store, other: other);
    final app = tester.widget<BeaconApp>(find.byType(BeaconApp));
    expect(app.preferences.active!.url, server);
    push.taps.add({
      'pushId': 'inst_b',
      'targetKind': 'node',
      'publicKey': 'aabb',
      'id': 'node-1',
    });
    await tester.pumpAndSettle();
    expect(app.preferences.active!.url, other);
    final opened = tester.widget<EntityDetailScreen>(
      find.byType(EntityDetailScreen),
    );
    expect((opened.kind, opened.id), ('node', 'node-1'));
  });
}
