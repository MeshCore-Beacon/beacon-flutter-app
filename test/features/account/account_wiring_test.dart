import 'package:beacon/app.dart';
import 'package:beacon/core/account.dart';
import 'package:beacon/core/api.dart';
import 'package:beacon/core/auth_api.dart';
import 'package:beacon/core/instance.dart';
import 'package:beacon/core/preferences.dart';
import 'package:beacon/core/push.dart';
import 'package:beacon/core/token_store.dart';
import 'package:beacon/features/account/sign_in.dart';
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

  http.Response serve(http.Request r) {
    final path = r.url.path.replaceFirst('/api/v1', '');
    if (path == '/info') {
      return json(200, {
        'features': {
          'accounts': 'local',
          if (pushMode) ...{'alerts': true, 'alertDelivery': 'push'},
        },
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

  Future<SignInFlow> pumpApp(WidgetTester tester, {FakePush? push}) async {
    final prefs = await Preferences.load();
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
        push: push,
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
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
    await tester.pumpAndSettle();
  }

  setUp(() {
    tokens = MemoryTokenStore();
    registry = AccountRegistry();
    launched = [];
    meCalls = 0;
    pushMode = false;
    deviceCalls = [];
  });

  testWidgets('a browser sign-in shows the user without a restart', (
    tester,
  ) async {
    final flow = await pumpApp(tester);
    expect(meCalls, 0);
    await openSettings(tester);
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
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
  });
}
