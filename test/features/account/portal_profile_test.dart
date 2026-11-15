import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/core/theme.dart';
import 'package:beacon/features/account/profile_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'harness.dart';

void main() {
  setUp(loadAssets);

  Future<Harness> open(
    WidgetTester tester, {
    String mode = 'portal',
    String? portalUrl = 'https://portal.example',
    http.Response Function(http.Request)? onDelete,
  }) async {
    tester.view.physicalSize = const Size(600, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final h = Harness((r) {
      if (r.method == 'GET' && r.url.path.endsWith('/me/sessions')) {
        return json(200, {'sessions': []});
      }
      if (r.method == 'DELETE' && r.url.path.endsWith('/me')) {
        return onDelete == null ? http.Response('', 204) : onDelete(r);
      }
      return json(404, {});
    });
    final api = ApiClient(
      Uri.parse(server),
      transientRetries: 0,
      client: MockClient(
        (_) async => json(200, {
          'features': {'accounts': mode, 'portalUrl': ?portalUrl},
        }),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: BeaconTheme.all.first.data,
        home: ProfileScreen(account: h.account, api: api),
      ),
    );
    await tester.pumpAndSettle();
    return h;
  }

  testWidgets('portal mode hides the password and email forms', (tester) async {
    await open(tester);
    expect(find.byKey(const ValueKey('pw-save')), findsNothing);
    expect(find.byKey(const ValueKey('email-save')), findsNothing);
    expect(find.byKey(const ValueKey('email-new')), findsNothing);
    expect(find.byKey(const ValueKey('display-name')), findsOneWidget);
    expect(
      find.text('Your sign-in is managed at the MeshMapper portal.'),
      findsOneWidget,
    );
    expect(find.textContaining('https://portal.example'), findsOneWidget);
  });

  testWidgets('without a portal URL the line stands alone', (tester) async {
    await open(tester, portalUrl: null);
    expect(
      find.text('Your sign-in is managed at the MeshMapper portal.'),
      findsOneWidget,
    );
    expect(find.textContaining('https://'), findsNothing);
  });

  testWidgets('local mode keeps the forms and shows no portal line', (
    tester,
  ) async {
    await open(tester, mode: 'local');
    expect(find.byKey(const ValueKey('pw-save')), findsOneWidget);
    expect(find.byKey(const ValueKey('email-save')), findsOneWidget);
    expect(find.textContaining('MeshMapper portal'), findsNothing);
  });

  testWidgets('portal delete asks for the username and sends no password', (
    tester,
  ) async {
    final h = await open(tester);
    h.account.adopt(user(provider: 'portal'));
    await tester.pump();
    expect(find.byKey(const ValueKey('delete-password')), findsNothing);
    FilledButton button() => tester.widget<FilledButton>(
      find.byKey(const ValueKey('delete-confirm')),
    );
    expect(button().onPressed, isNull);
    final field = find.byKey(const ValueKey('delete-username'));
    await tester.ensureVisible(field);
    await tester.enterText(field, 'ridgewalker');
    await tester.pump();
    expect(button().onPressed, isNotNull);
    await tester.tap(find.byKey(const ValueKey('delete-confirm')));
    await tester.pumpAndSettle();
    expect(jsonDecode(h.calls('DELETE', '/me').single.body), {
      'confirmUsername': 'ridgewalker',
    });
    expect(await h.tokens.read(server), isNull);
  });

  testWidgets('a wrong username shows that it is not the username', (
    tester,
  ) async {
    final h = await open(
      tester,
      onDelete: (_) =>
          failure(422, 'invalid_input', 'Check the values you entered.'),
    );
    h.account.adopt(user(provider: 'portal'));
    await tester.pump();
    final field = find.byKey(const ValueKey('delete-username'));
    await tester.ensureVisible(field);
    await tester.enterText(field, 'ridgewalker');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('delete-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('That is not your username.'), findsOneWidget);
  });

  testWidgets('the delete form follows the account, not the server mode', (
    tester,
  ) async {
    await open(tester);
    // A local account on a portal server still confirms with its password.
    expect(find.byKey(const ValueKey('delete-password')), findsOneWidget);
  });
}
