import 'dart:async';
import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/core/auth_api.dart';
import 'package:beacon/core/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _base = 'https://beacon.example.com';

http.Response _json(int status, Object? body, {Map<String, String>? headers}) =>
    http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json', ...?headers},
    );

http.Response _error(int status, String code, [String message = 'nope']) =>
    _json(status, {
      'error': {'code': code, 'message': message},
    });

void main() {
  late MemoryTokenStore tokens;
  late List<http.Request> seen;

  AuthApi make(http.Response Function(http.Request) handler) {
    seen = [];
    return AuthApi(
      _base,
      tokens,
      client: MockClient((request) async {
        seen.add(request);
        return handler(request);
      }),
    );
  }

  setUp(() => tokens = MemoryTokenStore());

  test(
    'account responses have a byte bound and do not clear the session',
    () async {
      await tokens.write(_base, 'kept');
      final api = make((_) => http.Response('x' * (1024 * 1024 + 1), 200));
      await expectLater(api.send('GET', '/me'), throwsA(isA<ApiException>()));
      expect(await tokens.read(_base), 'kept');
    },
  );

  group('headers', () {
    test(
      'no Authorization without a token, none of the unsafe headers',
      () async {
        final api = make((_) => _json(200, {'user': {}}));
        await api.send('GET', '/me');
        final h = seen.single.headers;
        expect(seen.single.url.toString(), '$_base/api/v1/me');
        expect(h.containsKey('authorization'), false);
        expect(h.containsKey('cookie'), false);
        expect(h.containsKey('x-beacon-csrf'), false);
        expect(h.containsKey('user-agent'), false);
        expect(h.containsKey('content-type'), false);
      },
    );

    test('Bearer is sent when a token is stored for this server', () async {
      await tokens.write(_base, 'abc');
      await tokens.write('https://other.test', 'zzz');
      final api = make((_) => _json(200, {}));
      await api.send('GET', '/me');
      expect(seen.single.headers['authorization'], 'Bearer abc');
    });

    test('a body is sent as JSON', () async {
      final api = make((_) => _json(200, {}));
      await api.send('POST', '/auth/logout', body: {'a': 1});
      expect(seen.single.method, 'POST');
      expect(
        seen.single.headers['content-type'],
        startsWith('application/json'),
      );
      expect(jsonDecode(seen.single.body), {'a': 1});
    });

    test('a trailing slash on the base does not double up', () async {
      seen = [];
      final api = AuthApi(
        '$_base/',
        tokens,
        client: MockClient((r) async {
          seen.add(r);
          return _json(200, {});
        }),
      );
      await api.send('GET', '/me');
      expect(seen.single.url.toString(), '$_base/api/v1/me');
    });
  });

  group('errors', () {
    test(
      'ApiException carries status, code, message and Retry-After',
      () async {
        final api = make(
          (_) => _json(
            429,
            {
              'error': {'code': 'too_many_attempts', 'message': 'slow down'},
            },
            headers: {'retry-after': '30'},
          ),
        );
        await expectLater(
          api.send('POST', '/me/password', body: {}),
          throwsA(
            isA<ApiException>()
                .having((e) => e.status, 'status', 429)
                .having((e) => e.code, 'code', 'too_many_attempts')
                .having((e) => e.message, 'message', 'slow down')
                .having(
                  (e) => e.retryAfter,
                  'retryAfter',
                  const Duration(seconds: 30),
                ),
          ),
        );
      },
    );

    test('a 401 not_signed_in clears the token and tells the state', () async {
      await tokens.write(_base, 'abc');
      var signedOut = 0;
      final api = make((_) => _error(401, 'not_signed_in'))
        ..onSignedOut = () => signedOut++;
      await expectLater(
        api.send('GET', '/me/sessions'),
        throwsA(isA<ApiException>()),
      );
      expect(await tokens.read(_base), isNull);
      expect(signedOut, 1);
    });

    for (final c in [
      (401, 'invalid_credentials'),
      (403, 'csrf_rejected'),
      (422, 'weak_password'),
      (500, 'internal'),
      (503, 'read_only'),
    ]) {
      test('${c.$1} ${c.$2} keeps the token', () async {
        await tokens.write(_base, 'abc');
        var signedOut = 0;
        final api = make((_) => _error(c.$1, c.$2))
          ..onSignedOut = () => signedOut++;
        await expectLater(
          api.send('POST', '/me/password', body: {}),
          throwsA(isA<ApiException>()),
        );
        expect(await tokens.read(_base), 'abc');
        expect(signedOut, 0);
      });
    }

    test(
      'a network failure becomes an ApiException and keeps the token',
      () async {
        await tokens.write(_base, 'abc');
        final api = AuthApi(
          _base,
          tokens,
          client: MockClient((_) async => throw http.ClientException('down')),
        );
        await expectLater(api.send('GET', '/me'), throwsA(isA<ApiException>()));
        expect(await tokens.read(_base), 'abc');
      },
    );
  });

  group('stale sessions', () {
    test('a late 401 for an old token leaves a newer token alone', () async {
      await tokens.write(_base, 'A');
      final late = Completer<http.Response>();
      var signedOut = 0;
      final old = AuthApi(_base, tokens, client: MockClient((_) => late.future))
        ..onSignedOut = () => signedOut++;
      final signIn = AuthApi(
        _base,
        tokens,
        client: MockClient((_) async => _json(200, {'token': 'B', 'user': {}})),
      );
      final pending = old.me();
      await Future<void>.delayed(Duration.zero);
      await signIn.exchangeAppCode('c', 'v');
      late.complete(_error(401, 'not_signed_in'));
      await expectLater(pending, throwsA(isA<ApiException>()));
      expect(await tokens.read(_base), 'B');
      expect(signedOut, 0);
    });

    test('a 503 never deletes the token', () async {
      await tokens.write(_base, 'abc');
      var signedOut = 0;
      final api = make((_) => _error(503, 'unavailable'))
        ..onSignedOut = () => signedOut++;
      await expectLater(api.me(), throwsA(isA<ApiException>()));
      await expectLater(
        api.send('GET', '/me/sessions'),
        throwsA(isA<ApiException>()),
      );
      expect(await tokens.read(_base), 'abc');
      expect(signedOut, 0);
    });
  });

  group('503 service_unavailable', () {
    test('keeps the token, reads Retry-After and never signs out', () async {
      await tokens.write(_base, 'abc');
      var signedOut = 0;
      final api = make(
        (_) => _json(
          503,
          {
            'error': {
              'code': 'service_unavailable',
              'message': 'Try again in a moment.',
            },
          },
          headers: {'retry-after': '5'},
        ),
      )..onSignedOut = () => signedOut++;
      await expectLater(
        api.me(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'service_unavailable')
              .having(
                (e) => e.retryAfter,
                'retryAfter',
                const Duration(seconds: 5),
              ),
        ),
      );
      expect(await tokens.read(_base), 'abc');
      expect(signedOut, 0);
    });
  });

  group('me', () {
    test('is null without a token and sends nothing', () async {
      final api = make((_) => _json(200, {'user': {}}));
      expect(await api.me(), isNull);
      expect(seen, isEmpty);
    });

    test('returns the user', () async {
      await tokens.write(_base, 'abc');
      final api = make(
        (_) => _json(200, {
          'user': {'username': 'ridge'},
        }),
      );
      expect((await api.me())!['username'], 'ridge');
    });

    test('is null on 404 accounts_disabled', () async {
      await tokens.write(_base, 'abc');
      final api = make((_) => _error(404, 'accounts_disabled'));
      expect(await api.me(), isNull);
    });

    test('is null on a 401 and the token is gone', () async {
      await tokens.write(_base, 'abc');
      final api = make((_) => _error(401, 'not_signed_in'));
      expect(await api.me(), isNull);
      expect(await tokens.read(_base), isNull);
    });

    test('other failures throw', () async {
      await tokens.write(_base, 'abc');
      final api = make((_) => _error(500, 'internal'));
      await expectLater(api.me(), throwsA(isA<ApiException>()));
    });
  });

  group('routes', () {
    setUp(() => tokens.write(_base, 'abc'));

    test('setDisplayName', () async {
      final api = make(
        (_) => _json(200, {
          'user': {'displayName': 'R'},
        }),
      );
      final user = await api.setDisplayName('R');
      expect(seen.single.method, 'PATCH');
      expect(seen.single.url.path, '/api/v1/me');
      expect(jsonDecode(seen.single.body), {'displayName': 'R'});
      expect(user['displayName'], 'R');
    });

    test('changePassword', () async {
      final api = make((_) => http.Response('', 204));
      await api.changePassword('old', 'new');
      expect(seen.single.method, 'POST');
      expect(seen.single.url.path, '/api/v1/me/password');
      expect(jsonDecode(seen.single.body), {
        'currentPassword': 'old',
        'newPassword': 'new',
      });
    });

    test('changeEmail', () async {
      final api = make((_) => _json(202, {'status': 'check_email'}));
      await api.changeEmail('a@b.c', 'pw');
      expect(seen.single.url.path, '/api/v1/me/email');
      expect(jsonDecode(seen.single.body), {
        'email': 'a@b.c',
        'currentPassword': 'pw',
      });
    });

    test('deleteAccount drops the token', () async {
      var signedOut = 0;
      final api = make((_) => http.Response('', 204))
        ..onSignedOut = () => signedOut++;
      await api.deleteAccount(currentPassword: 'pw');
      expect(seen.single.method, 'DELETE');
      expect(seen.single.url.path, '/api/v1/me');
      expect(jsonDecode(seen.single.body), {'currentPassword': 'pw'});
      expect(await tokens.read(_base), isNull);
      expect(signedOut, 1);
    });

    test('deleteAccount in portal mode sends the typed username', () async {
      final api = make((_) => http.Response('', 204));
      await api.deleteAccount(confirmUsername: 'ridgewalker');
      expect(jsonDecode(seen.single.body), {'confirmUsername': 'ridgewalker'});
      expect(await tokens.read(_base), isNull);
    });

    test('a failed deleteAccount keeps the token', () async {
      final api = make((_) => _error(401, 'invalid_credentials'));
      await expectLater(
        api.deleteAccount(currentPassword: 'bad'),
        throwsA(isA<ApiException>()),
      );
      expect(await tokens.read(_base), 'abc');
    });

    test('sessions, endSession, endOtherSessions', () async {
      final api = make(
        (r) => r.method == 'GET'
            ? _json(200, {
                'sessions': [
                  {'id': 'a', 'current': true},
                  {'id': 'b'},
                ],
              })
            : http.Response('', 204),
      );
      final list = await api.sessions();
      expect(list.map((s) => s['id']), ['a', 'b']);
      await api.endSession('b/../x');
      expect(seen.last.method, 'DELETE');
      expect(seen.last.url.path, '/api/v1/me/sessions/b%2F..%2Fx');
      await api.endOtherSessions();
      expect(seen.last.method, 'DELETE');
      expect(seen.last.url.path, '/api/v1/me/sessions');
    });
  });

  group('signOut', () {
    test('posts logout then deletes the token', () async {
      await tokens.write(_base, 'abc');
      var signedOut = 0;
      final api = make((_) => http.Response('', 204))
        ..onSignedOut = () => signedOut++;
      await api.signOut();
      expect(seen.single.method, 'POST');
      expect(seen.single.url.path, '/api/v1/auth/logout');
      expect(seen.single.headers['authorization'], 'Bearer abc');
      expect(await tokens.read(_base), isNull);
      expect(signedOut, 1);
    });

    test('deletes the token even when the request fails', () async {
      await tokens.write(_base, 'abc');
      final api = AuthApi(
        _base,
        tokens,
        client: MockClient((_) async => throw http.ClientException('down')),
      );
      await api.signOut();
      expect(await tokens.read(_base), isNull);
    });
  });

  group('exchangeAppCode', () {
    test(
      'posts code and verifier, stores the token, sends no Bearer',
      () async {
        await tokens.write(_base, 'stale');
        final api = make(
          (_) => _json(200, {
            'token': 'fresh',
            'expiresAt': 1,
            'user': {'username': 'ridge'},
          }),
        );
        final result = await api.exchangeAppCode('c', 'v');
        expect(seen.single.url.path, '/api/v1/auth/app/token');
        expect(jsonDecode(seen.single.body), {
          'code': 'c',
          'codeVerifier': 'v',
        });
        expect(seen.single.headers.containsKey('authorization'), false);
        expect(result['user']['username'], 'ridge');
        expect(await tokens.read(_base), 'fresh');
      },
    );

    test('a failure leaves the stored token alone', () async {
      await tokens.write(_base, 'stale');
      final api = make((_) => _error(400, 'token_invalid'));
      await expectLater(
        api.exchangeAppCode('c', 'v'),
        throwsA(isA<ApiException>()),
      );
      expect(await tokens.read(_base), 'stale');
    });
  });

  group('Telemetry requests', () {
    Future<AuthApi> signedIn(http.Response Function(http.Request) h) async {
      await tokens.write(_base, 'abc');
      return make(h);
    }

    test('telemetryRequests() reads the list with the Bearer token', () async {
      final api = await signedIn(
        (_) => _json(200, {'limit': 3, 'requests': []}),
      );
      expect((await api.telemetryRequests())['limit'], 3);
      expect(seen.single.method, 'GET');
      expect(seen.single.url.path, '/api/v1/me/telemetry-requests');
      expect(seen.single.headers['authorization'], 'Bearer abc');
    });

    test('create sends the node, and a password only when given', () async {
      final api = await signedIn((_) => _json(201, {'id': 'r1'}));
      await api.createTelemetryRequest('n1', password: 'guest');
      await api.createTelemetryRequest('n1');
      await api.createTelemetryRequest('n1', password: '');
      expect(seen.map((r) => r.method), ['POST', 'POST', 'POST']);
      expect(seen.first.url.path, '/api/v1/me/telemetry-requests');
      expect(jsonDecode(seen[0].body), {'nodeId': 'n1', 'password': 'guest'});
      expect(jsonDecode(seen[1].body), {'nodeId': 'n1'});
      expect(jsonDecode(seen[2].body), {'nodeId': 'n1'});
    });

    test(
      'update sends a new password, null to remove it, or enabled',
      () async {
        final api = await signedIn((_) => _json(200, {'id': 'r1'}));
        await api.updateTelemetryRequest(
          'r1',
          withPassword: true,
          password: 'x',
        );
        await api.updateTelemetryRequest(
          'r1',
          withPassword: true,
          password: '',
        );
        await api.updateTelemetryRequest('r1', enabled: true);
        expect(seen.map((r) => r.method), ['PATCH', 'PATCH', 'PATCH']);
        expect(seen.first.url.path, '/api/v1/me/telemetry-requests/r1');
        expect(jsonDecode(seen[0].body), {'password': 'x'});
        expect(jsonDecode(seen[1].body), {'password': null});
        expect(jsonDecode(seen[2].body), {'enabled': true});
      },
    );

    test('delete removes the request', () async {
      final api = await signedIn((_) => http.Response('', 204));
      await api.deleteTelemetryRequest('r/1');
      expect(seen.single.method, 'DELETE');
      expect(seen.single.url.path, '/api/v1/me/telemetry-requests/r%2F1');
    });

    test('a refusal keeps its code', () async {
      final api = await signedIn((_) => _error(409, 'request_limit'));
      await expectLater(
        api.createTelemetryRequest('n1'),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'request_limit'),
        ),
      );
    });
  });

  group('alerts', () {
    Future<AuthApi> signedIn(http.Response Function(http.Request) h) async {
      await tokens.write(_base, 'abc');
      return make(h);
    }

    test('alerts() reads with the Bearer token', () async {
      final api = await signedIn(
        (_) => _json(200, {'delivery': 'push', 'targets': []}),
      );
      expect((await api.alerts())['delivery'], 'push');
      expect(seen.single.method, 'GET');
      expect(seen.single.url.path, '/api/v1/me/alerts');
      expect(seen.single.headers['authorization'], 'Bearer abc');
    });

    test(
      'putAlertRule sends the target, kind, thresholds and enabled',
      () async {
        final api = await signedIn((_) => _json(200, {'id': 'u1'}));
        await api.putAlertRule(
          targetKind: 'node',
          publicKey: 'aabb',
          kind: 'temperature',
          threshold: null,
          thresholdHigh: 455,
          enabled: true,
        );
        expect(seen.single.method, 'PUT');
        expect(seen.single.url.path, '/api/v1/me/alerts/rules');
        expect(jsonDecode(seen.single.body), {
          'target': {'kind': 'node', 'publicKey': 'aabb'},
          'kind': 'temperature',
          'threshold': null,
          'thresholdHigh': 455,
          'enabled': true,
        });
      },
    );

    test('deleteAlertRule escapes the id', () async {
      final api = await signedIn((_) => http.Response('', 204));
      await api.deleteAlertRule('a/b');
      expect(seen.single.method, 'DELETE');
      expect(seen.single.url.path, '/api/v1/me/alerts/rules/a%2Fb');
    });

    test(
      'registerDevice posts the platform and token, removeDevice deletes',
      () async {
        final api = await signedIn((_) => http.Response('', 204));
        await api.registerDevice('android', 'tok-1');
        await api.removeDevice();
        expect(seen[0].method, 'POST');
        expect(seen[0].url.path, '/api/v1/me/devices');
        expect(jsonDecode(seen[0].body), {
          'platform': 'android',
          'pushToken': 'tok-1',
        });
        expect(seen[1].method, 'DELETE');
        expect(seen[1].url.path, '/api/v1/me/devices');
        expect(seen[1].body, isEmpty);
      },
    );

    test('a not_on_atlas answer keeps its code', () async {
      final api = await signedIn((_) => _error(409, 'not_on_atlas'));
      await expectLater(
        api.putAlertRule(
          targetKind: 'node',
          publicKey: 'aa',
          kind: 'rebooted',
          threshold: null,
          thresholdHigh: null,
          enabled: true,
        ),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'not_on_atlas'),
        ),
      );
    });
  });

  group('Atlas', () {
    test(
      'atlas() reads the account collection with the Bearer token',
      () async {
        await tokens.write(_base, 'abc');
        final api = make((_) => _json(200, {'revision': 2, 'pins': []}));
        expect((await api.atlas())['revision'], 2);
        expect(seen.single.method, 'GET');
        expect(seen.single.url.path, '/api/v1/me/atlas');
        expect(seen.single.headers['authorization'], 'Bearer abc');
      },
    );

    test('putAtlas sends the revision, range and pins', () async {
      await tokens.write(_base, 'abc');
      final api = make((_) => _json(200, {'revision': 8, 'pins': []}));
      final pins = [
        {'kind': 'observer', 'observerId': 'o', 'name': 'Roof'},
      ];
      final doc = await api.putAtlas(7, '3d', pins);
      expect(doc['revision'], 8);
      expect(seen.single.method, 'PUT');
      expect(seen.single.url.path, '/api/v1/me/atlas');
      expect(jsonDecode(seen.single.body), {
        'baseRevision': 7,
        'range': '3d',
        'pins': pins,
      });
    });

    test('a 409 surfaces the current document', () async {
      await tokens.write(_base, 'abc');
      final api = make(
        (_) => _json(409, {
          'error': {'code': 'atlas_conflict', 'message': 'changed'},
          'current': {'revision': 9, 'pins': []},
        }),
      );
      await expectLater(
        api.putAtlas(7, '24h', []),
        throwsA(
          isA<AtlasConflict>().having((e) => e.current?['revision'], 'rev', 9),
        ),
      );
    });

    test('a 409 without the document still reads as a conflict', () async {
      await tokens.write(_base, 'abc');
      final api = make((_) => _error(409, 'atlas_conflict'));
      await expectLater(
        api.putAtlas(7, '24h', []),
        throwsA(isA<AtlasConflict>().having((e) => e.current, 'current', null)),
      );
    });

    test('other failures stay ApiExceptions', () async {
      await tokens.write(_base, 'abc');
      final api = make((_) => _error(422, 'invalid_input'));
      await expectLater(
        api.putAtlas(7, '24h', []),
        throwsA(isA<ApiException>().having((e) => e.status, 'status', 422)),
      );
    });
  });

  test('authenticated responses never enter ApiClient\'s cache', () async {
    await tokens.write(_base, 'abc');
    final api = make(
      (_) => _json(200, {
        'user': {'username': 'ridge'},
      }),
    );
    await api.me();
    final reads = ApiClient(
      Uri.parse(_base),
      client: MockClient((_) async => _json(200, {})),
    );
    expect(reads.peekCache('/me'), isNull);
  });
}
