import 'dart:async';
import 'dart:convert';

import 'package:beacon/core/theme.dart';
import 'package:beacon/features/account/profile_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'harness.dart';

http.Response Function(http.Request) routes(
  Map<String, http.Response Function(http.Request)> table,
) => (r) {
  final handler =
      table['${r.method} ${r.url.path.replaceFirst('/api/v1', '')}'];
  return handler == null ? json(404, {}) : handler(r);
};

Future<void> open(WidgetTester tester, Harness h) async {
  tester.view.physicalSize = const Size(600, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: BeaconTheme.all.first.data,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => ProfileScreen(account: h.account),
              ),
            ),
            child: const Text('open profile'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open profile'));
  await tester.pumpAndSettle();
}

Future<void> typeInto(WidgetTester tester, String key, String text) async {
  final field = find.byKey(ValueKey(key));
  await tester.ensureVisible(field);
  await tester.enterText(field, text);
  await tester.pump();
}

Future<void> press(WidgetTester tester, String key) async {
  final button = find.byKey(ValueKey(key));
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  setUp(loadAssets);

  Harness make(Map<String, http.Response Function(http.Request)> extra) =>
      Harness(
        routes({
          'GET /me/sessions': (_) => json(200, {
            'sessions': [
              session('s1', current: true),
              session('s2', kind: 'app'),
            ],
          }),
          ...extra,
        }),
      );

  testWidgets('typed passwords are dropped when the account changes', (
    tester,
  ) async {
    final h = make({});
    await open(tester, h);
    await typeInto(tester, 'pw-current', 'A-secret');
    await typeInto(tester, 'email-password', 'A-secret');
    h.account.adopt({...user(), 'id': 'u2'});
    await tester.pumpAndSettle();
    for (final key in ['pw-current', 'email-password']) {
      final field = find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(TextField),
      );
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    }
  });

  testWidgets('shows the account, email state and devices', (tester) async {
    final h = make({});
    await open(tester, h);
    expect(find.text('Profile'), findsWidgets);
    expect(find.text('Ridge Walker'), findsOneWidget);
    expect(find.text('a@example.org'), findsOneWidget);
    expect(find.text('Verified'), findsOneWidget);
    expect(find.text('Device s1'), findsOneWidget);
    expect(find.text('Device s2'), findsOneWidget);
    expect(find.text('This device'), findsOneWidget);
    expect(find.text('Browser'), findsOneWidget);
    expect(find.text('App'), findsOneWidget);
  });

  testWidgets('a pending email shows its waiting state', (tester) async {
    final h = make({});
    h.account.adopt(user(pendingEmail: 'new@example.org'));
    await open(tester, h);
    expect(find.text('Waiting to verify new@example.org'), findsOneWidget);
  });

  testWidgets('saving a display name sends it and shows the result', (
    tester,
  ) async {
    final h = make({
      'PATCH /me': (r) => json(200, {
        'user': user(name: jsonDecode(r.body)['displayName'] as String),
      }),
    });
    await open(tester, h);
    await typeInto(tester, 'display-name', 'Ridge W');
    await press(tester, 'name-save');
    expect(jsonDecode(h.calls('PATCH', '/me').single.body), {
      'displayName': 'Ridge W',
    });
    expect(h.account.user!['displayName'], 'Ridge W');
    expect(find.text('Saved.'), findsOneWidget);
  });

  testWidgets('an invalid display name shows the input line', (tester) async {
    final h = make({
      'PATCH /me': (_) => failure(422, 'invalid_input', 'bad name'),
    });
    await open(tester, h);
    await typeInto(tester, 'display-name', ' ');
    await press(tester, 'name-save');
    expect(find.text('Check what you entered and try again.'), findsOneWidget);
    expect(find.text('Saved.'), findsNothing);
  });

  testWidgets('changing the email sends the password and says to check mail', (
    tester,
  ) async {
    final h = make({
      'POST /me/email': (_) => json(202, {'status': 'check_email'}),
    });
    await open(tester, h);
    await typeInto(tester, 'email-new', 'new@example.org');
    await typeInto(tester, 'email-password', 'hunter2hunter2');
    await press(tester, 'email-save');
    expect(jsonDecode(h.calls('POST', '/me/email').single.body), {
      'email': 'new@example.org',
      'currentPassword': 'hunter2hunter2',
    });
    expect(
      find.text('Check new@example.org for a link to confirm it.'),
      findsOneWidget,
    );
  });

  testWidgets('a wrong password on an email change shows its line', (
    tester,
  ) async {
    final h = make({
      'POST /me/email': (_) =>
          failure(401, 'invalid_credentials', 'Wrong password.'),
    });
    await open(tester, h);
    await typeInto(tester, 'email-new', 'new@example.org');
    await typeInto(tester, 'email-password', 'nope');
    await press(tester, 'email-save');
    expect(find.text('That password is not right.'), findsOneWidget);
    expect(h.tokens.read(server), completion('tok'));
  });

  testWidgets('a short new password cannot be sent and the rule is shown', (
    tester,
  ) async {
    final h = make({});
    await open(tester, h);
    expect(
      find.text('At least 12 characters, at most 128 bytes.'),
      findsOneWidget,
    );
    await typeInto(tester, 'pw-current', 'old-password-1');
    await typeInto(tester, 'pw-new', 'short-pw-11');
    FilledButton save() =>
        tester.widget<FilledButton>(find.byKey(const ValueKey('pw-save')));
    expect(save().onPressed, isNull);
    await typeInto(tester, 'pw-new', 'long-enough-12');
    expect(save().onPressed, isNotNull);
  });

  testWidgets('changing the password works and refreshes devices', (
    tester,
  ) async {
    final h = make({'POST /me/password': (_) => http.Response('', 204)});
    await open(tester, h);
    await typeInto(tester, 'pw-current', 'old-password-1');
    await typeInto(tester, 'pw-new', 'new-password-2');
    await press(tester, 'pw-save');
    expect(jsonDecode(h.calls('POST', '/me/password').single.body), {
      'currentPassword': 'old-password-1',
      'newPassword': 'new-password-2',
    });
    expect(
      find.text('Password changed. Your other devices were signed out.'),
      findsOneWidget,
    );
    expect(h.calls('GET', '/me/sessions').length, 2);
  });

  for (final which in ['password', 'email', 'name']) {
    testWidgets('leaving while the $which request is pending is safe', (
      tester,
    ) async {
      final route = {
        'password': 'POST /me/password',
        'email': 'POST /me/email',
        'name': 'PATCH /me',
      }[which]!;
      final h = make({
        route: (_) => which == 'name'
            ? json(200, {'user': user(name: 'New')})
            : which == 'email'
            ? json(202, {'status': 'check_email'})
            : http.Response('', 204),
      });
      final release = Completer<http.Response>();
      await open(tester, h);
      h.hold = (r) =>
          r.method == route.split(' ').first &&
              r.url.path == '/api/v1${route.split(' ').last}'
          ? release.future
          : null;
      if (which == 'password') {
        await typeInto(tester, 'pw-current', 'old-password-1');
        await typeInto(tester, 'pw-new', 'new-password-2');
        await tester.ensureVisible(find.byKey(const ValueKey('pw-save')));
        await tester.tap(find.byKey(const ValueKey('pw-save')));
      } else if (which == 'email') {
        await typeInto(tester, 'email-new', 'b@example.org');
        await typeInto(tester, 'email-password', 'hunter2hunter2');
        await tester.ensureVisible(find.byKey(const ValueKey('email-save')));
        await tester.tap(find.byKey(const ValueKey('email-save')));
      } else {
        await typeInto(tester, 'display-name', 'New');
        await tester.ensureVisible(find.byKey(const ValueKey('name-save')));
        await tester.tap(find.byKey(const ValueKey('name-save')));
      }
      await tester.pump();
      Navigator.of(tester.element(find.byType(ProfileScreen))).pop();
      await tester.pumpAndSettle();
      release.complete(
        which == 'name'
            ? json(200, {'user': user(name: 'New')})
            : which == 'email'
            ? json(202, {'status': 'check_email'})
            : http.Response('', 204),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a weak password shows the server reason', (tester) async {
    final h = make({
      'POST /me/password': (_) => failure(
        422,
        'weak_password',
        'That password is on a list of common passwords.',
      ),
    });
    await open(tester, h);
    await typeInto(tester, 'pw-current', 'old-password-1');
    await typeInto(tester, 'pw-new', 'password1234');
    await press(tester, 'pw-save');
    expect(
      find.text('That password is on a list of common passwords.'),
      findsOneWidget,
    );
  });

  testWidgets('rate limiting says when to retry', (tester) async {
    final h = make({
      'POST /me/password': (_) => failure(
        429,
        'too_many_attempts',
        'slow down',
        headers: {'retry-after': '120'},
      ),
    });
    await open(tester, h);
    await typeInto(tester, 'pw-current', 'old-password-1');
    await typeInto(tester, 'pw-new', 'new-password-2');
    await press(tester, 'pw-save');
    expect(
      find.text('Too many attempts. Try again in 2 minutes.'),
      findsOneWidget,
    );
  });

  testWidgets('password fields hide the text until shown', (tester) async {
    final h = make({});
    await open(tester, h);
    TextField field() => tester.widget<TextField>(
      find.descendant(
        of: find.byKey(const ValueKey('pw-new')),
        matching: find.byType(TextField),
      ),
    );
    expect(field().obscureText, true);
    expect(field().autofillHints, contains(AutofillHints.newPassword));
    final toggle = find.descendant(
      of: find.byKey(const ValueKey('pw-new')),
      matching: find.byType(IconButton),
    );
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pump();
    expect(field().obscureText, false);
  });

  testWidgets('ending another device removes only that row', (tester) async {
    var gone = false;
    final h = make({
      'GET /me/sessions': (_) => json(200, {
        'sessions': [
          session('s1', current: true),
          if (!gone) session('s2', kind: 'app'),
        ],
      }),
      'DELETE /me/sessions/s2': (_) {
        gone = true;
        return http.Response('', 204);
      },
    });
    await open(tester, h);
    await press(tester, 'session-end-s2');
    expect(h.calls('DELETE', '/me/sessions/s2'), hasLength(1));
    expect(find.text('Device s2'), findsNothing);
    expect(find.text('Device s1'), findsOneWidget);
  });

  testWidgets('sign out everywhere else ends the other sessions', (
    tester,
  ) async {
    final h = make({'DELETE /me/sessions': (_) => http.Response('', 204)});
    await open(tester, h);
    await press(tester, 'devices-others');
    expect(h.calls('DELETE', '/me/sessions'), hasLength(1));
    expect(find.text('Signed out everywhere else.'), findsOneWidget);
  });

  testWidgets('signing out this device returns and removes the token', (
    tester,
  ) async {
    final h = make({'POST /auth/logout': (_) => http.Response('', 204)});
    await open(tester, h);
    await press(tester, 'session-end-s1');
    expect(find.text('open profile'), findsOneWidget);
    expect(await h.tokens.read(server), isNull);
    expect(h.account.signedIn, false);
  });

  testWidgets('a 401 from any call signs out and leaves the screen', (
    tester,
  ) async {
    final h = make({
      'PATCH /me': (_) => failure(401, 'not_signed_in', 'Sign in first.'),
    });
    await open(tester, h);
    await typeInto(tester, 'display-name', 'Other');
    await press(tester, 'name-save');
    expect(find.text('open profile'), findsOneWidget);
    expect(await h.tokens.read(server), isNull);
  });

  testWidgets('delete needs the typed username and then removes the token', (
    tester,
  ) async {
    final h = make({'DELETE /me': (_) => http.Response('', 204)});
    await open(tester, h);
    await typeInto(tester, 'delete-password', 'old-password-1');
    FilledButton button() => tester.widget<FilledButton>(
      find.byKey(const ValueKey('delete-confirm')),
    );
    expect(button().onPressed, isNull);
    await typeInto(tester, 'delete-username', 'wrong');
    expect(button().onPressed, isNull);
    await typeInto(tester, 'delete-username', 'ridgewalker');
    expect(button().onPressed, isNotNull);
    await press(tester, 'delete-confirm');
    expect(jsonDecode(h.calls('DELETE', '/me').single.body), {
      'currentPassword': 'old-password-1',
    });
    expect(find.text('open profile'), findsOneWidget);
    expect(await h.tokens.read(server), isNull);
  });

  testWidgets('a failed delete shows its error and keeps the account', (
    tester,
  ) async {
    final h = make({
      'DELETE /me': (_) => failure(401, 'invalid_credentials', 'no'),
    });
    await open(tester, h);
    await typeInto(tester, 'delete-password', 'bad');
    await typeInto(tester, 'delete-username', 'ridgewalker');
    await press(tester, 'delete-confirm');
    expect(find.text('That password is not right.'), findsOneWidget);
    expect(h.account.signedIn, true);
  });

  testWidgets('an unknown error gets a generic line', (tester) async {
    final h = make({'PATCH /me': (_) => failure(500, 'boom', 'internal')});
    await open(tester, h);
    await typeInto(tester, 'display-name', 'Other');
    await press(tester, 'name-save');
    expect(find.text('Something went wrong. Try again.'), findsOneWidget);
  });

  group('a busy server (503 service_unavailable)', () {
    const busy = 'The server is busy. Try again in a moment.';
    http.Response Function(http.Request) refuse() =>
        (_) => failure(
          503,
          'service_unavailable',
          busy,
          headers: {'retry-after': '5'},
        );

    String typed(WidgetTester tester, String key) => tester
        .widget<TextField>(
          find.descendant(
            of: find.byKey(ValueKey(key)),
            matching: find.byType(TextField),
          ),
        )
        .controller!
        .text;

    testWidgets('a password change says busy and keeps what was typed', (
      tester,
    ) async {
      final h = make({'POST /me/password': refuse()});
      await open(tester, h);
      await typeInto(tester, 'pw-current', 'old-password-1');
      await typeInto(tester, 'pw-new', 'new-password-2');
      await press(tester, 'pw-save');
      expect(find.text(busy), findsOneWidget);
      expect(find.text('That password is not right.'), findsNothing);
      expect(typed(tester, 'pw-current'), 'old-password-1');
      expect(typed(tester, 'pw-new'), 'new-password-2');
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('pw-save')))
            .onPressed,
        isNotNull,
      );
      expect(h.account.signedIn, true);
      expect(await h.tokens.read(server), 'tok');
    });

    testWidgets('an email change says busy and keeps what was typed', (
      tester,
    ) async {
      final h = make({'POST /me/email': refuse()});
      await open(tester, h);
      await typeInto(tester, 'email-new', 'new@example.org');
      await typeInto(tester, 'email-password', 'old-password-1');
      await press(tester, 'email-save');
      expect(find.text(busy), findsOneWidget);
      expect(typed(tester, 'email-password'), 'old-password-1');
      expect(h.account.signedIn, true);
      expect(await h.tokens.read(server), 'tok');
    });

    testWidgets('a delete says busy, keeps the account and the password', (
      tester,
    ) async {
      final h = make({'DELETE /me': refuse()});
      await open(tester, h);
      await typeInto(tester, 'delete-password', 'old-password-1');
      await typeInto(tester, 'delete-username', 'ridgewalker');
      await press(tester, 'delete-confirm');
      expect(find.text(busy), findsOneWidget);
      expect(typed(tester, 'delete-password'), 'old-password-1');
      expect(h.account.signedIn, true);
      expect(await h.tokens.read(server), 'tok');
    });
  });
}
