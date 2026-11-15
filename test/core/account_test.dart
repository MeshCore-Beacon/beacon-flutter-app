import 'dart:convert';

import 'package:beacon/core/account.dart';
import 'package:beacon/core/auth_api.dart';
import 'package:beacon/core/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _base = 'https://beacon.example.com';

http.Response _json(int status, Object? body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  late MemoryTokenStore tokens;
  setUp(() => tokens = MemoryTokenStore());

  AccountState make(http.Response Function(http.Request) handler) =>
      AccountState(
        AuthApi(_base, tokens, client: MockClient((r) async => handler(r))),
      );

  test('starts signed out', () {
    final state = make((_) => _json(200, {}));
    expect(state.signedIn, false);
    expect(state.user, isNull);
  });

  test('refresh loads the user and notifies', () async {
    await tokens.write(_base, 'abc');
    final state = make(
      (_) => _json(200, {
        'user': {'username': 'ridge'},
      }),
    );
    var notified = 0;
    state.addListener(() => notified++);
    await state.refresh();
    expect(state.signedIn, true);
    expect(state.user!['username'], 'ridge');
    expect(notified, 1);
  });

  test('a 401 signs out and clears the token', () async {
    await tokens.write(_base, 'abc');
    final state = make(
      (r) => r.method == 'GET' && r.url.path.endsWith('/me')
          ? _json(200, {
              'user': {'username': 'ridge'},
            })
          : _json(401, {
              'error': {'code': 'not_signed_in', 'message': 'x'},
            }),
    );
    await state.refresh();
    await expectLater(state.api.sessions(), throwsA(anything));
    expect(state.signedIn, false);
    expect(await tokens.read(_base), isNull);
  });

  test('another error does not sign out', () async {
    await tokens.write(_base, 'abc');
    final state = make((r) {
      if (r.url.path.endsWith('/me')) {
        return _json(200, {
          'user': {'username': 'ridge'},
        });
      }
      return _json(500, {
        'error': {'code': 'internal', 'message': 'x'},
      });
    });
    await state.refresh();
    await expectLater(state.api.sessions(), throwsA(anything));
    expect(state.signedIn, true);
    expect(await tokens.read(_base), 'abc');
  });

  test('a failed refresh keeps the current user', () async {
    await tokens.write(_base, 'abc');
    var fail = false;
    final state = make(
      (_) => fail
          ? _json(500, {
              'error': {'code': 'internal', 'message': 'x'},
            })
          : _json(200, {
              'user': {'username': 'ridge'},
            }),
    );
    await state.refresh();
    fail = true;
    await state.refresh();
    expect(state.signedIn, true);
  });

  test('signIn exchanges the code and sets the user', () async {
    final state = make(
      (_) => _json(200, {
        'token': 't',
        'expiresAt': 1,
        'user': {'username': 'ridge'},
      }),
    );
    await state.signIn('c', 'v');
    expect(state.signedIn, true);
    expect(await tokens.read(_base), 't');
  });

  test('signOut clears user and token', () async {
    await tokens.write(_base, 'abc');
    final state = make((_) => http.Response('', 204));
    state.adopt({'username': 'ridge'});
    await state.signOut();
    expect(state.signedIn, false);
    expect(await tokens.read(_base), isNull);
  });
}
