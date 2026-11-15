import 'dart:async';

import 'package:beacon/core/api.dart';
import 'package:beacon/core/theme.dart';
import 'package:beacon/features/account/account_section.dart';
import 'package:beacon/features/account/sign_in.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'harness.dart';

void main() {
  setUp(loadAssets);

  ApiClient apiWith(Future<http.Response> Function() info) =>
      ApiClient(Uri.parse(server), client: MockClient((r) => info()));

  ApiClient accountsOn(String mode) => apiWith(
    () async => json(200, {
      'features': {'accounts': mode},
    }),
  );

  Future<List<Uri>> pump(
    WidgetTester tester,
    Harness h,
    ApiClient api, {
    SignInFlow? flow,
  }) async {
    final launched = <Uri>[];
    final signIn =
        flow ??
        SignInFlow(
          apiFor: (url) => h.account.api,
          launch: (uri) async {
            launched.add(uri);
            return true;
          },
          now: DateTime.now,
        );
    await tester.pumpWidget(
      SignInScope(
        flow: signIn,
        child: MaterialApp(
          theme: BeaconTheme.all.first.data,
          home: Scaffold(
            body: ListView(
              children: [
                AccountSection(
                  account: h.account,
                  api: api,
                  serverName: 'Home mesh',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return launched;
  }

  testWidgets('shows nothing when the server has accounts off', (tester) async {
    final h = Harness((_) => json(200, {}), signedIn: false);
    await pump(tester, h, accountsOn('off'));
    expect(find.text('Sign in'), findsNothing);
    expect(find.textContaining('Account on'), findsNothing);
  });

  testWidgets('shows nothing while the features load', (tester) async {
    final h = Harness((_) => json(200, {}), signedIn: false);
    final gate = Completer<http.Response>();
    await tester.pumpWidget(
      SignInScope(
        flow: SignInFlow(
          apiFor: (_) => h.account.api,
          launch: (_) async => true,
          now: DateTime.now,
        ),
        child: MaterialApp(
          home: Scaffold(
            body: AccountSection(
              account: h.account,
              api: apiWith(() => gate.future),
              serverName: 'Home mesh',
            ),
          ),
        ),
      ),
    );
    expect(find.text('Sign in'), findsNothing);
    gate.complete(
      json(200, {
        'features': {'accounts': 'local'},
      }),
    );
    await tester.pumpAndSettle();
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('signed out offers Sign in with a line about the browser', (
    tester,
  ) async {
    final h = Harness((_) => json(200, {}), signedIn: false);
    final launched = await pump(tester, h, accountsOn('local'));
    expect(find.text('ACCOUNT ON HOME MESH'), findsOneWidget);
    expect(find.textContaining('browser'), findsOneWidget);
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(launched.single.origin, server);
    expect(launched.single.queryParameters['view'], 'signin');
  });

  testWidgets('portal mode offers Sign in with MeshMapper', (tester) async {
    final h = Harness((_) => json(200, {}), signedIn: false);
    final launched = await pump(tester, h, accountsOn('portal'));
    expect(find.text('Sign in'), findsNothing);
    expect(find.text('Sign in with MeshMapper'), findsOneWidget);
    await tester.tap(find.text('Sign in with MeshMapper'));
    await tester.pumpAndSettle();
    expect(launched.single.queryParameters['view'], 'signin');
    expect(launched.single.queryParameters['app'], '1');
  });

  testWidgets('a failed sign in shows its message inline', (tester) async {
    final h = Harness((_) => json(200, {}), signedIn: false);
    final flow = SignInFlow(
      apiFor: (url) => h.account.api,
      launch: (_) async => false,
      now: DateTime.now,
    );
    await pump(tester, h, accountsOn('local'), flow: flow);
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Could not open the browser.'), findsOneWidget);
  });

  testWidgets('signed in shows the name, username, Profile and Sign out', (
    tester,
  ) async {
    final h = Harness((_) => http.Response('', 204));
    await pump(tester, h, accountsOn('local'));
    expect(find.text('Ridge Walker'), findsOneWidget);
    expect(find.text('ridgewalker'), findsOneWidget);
    expect(find.text('Profile'), findsOneWidget);
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(await h.tokens.read(server), isNull);
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('the section follows the account state', (tester) async {
    final h = Harness((_) => json(200, {}), signedIn: false);
    await pump(tester, h, accountsOn('local'));
    expect(find.text('Sign in'), findsOneWidget);
    h.account.adopt(user());
    await tester.pumpAndSettle();
    expect(find.text('Ridge Walker'), findsOneWidget);
  });
}
