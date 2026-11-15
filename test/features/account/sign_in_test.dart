import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:beacon/core/account.dart';
import 'package:beacon/core/auth_api.dart';
import 'package:beacon/core/pkce.dart';
import 'package:beacon/core/token_store.dart';
import 'package:beacon/features/account/sign_in.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _server = 'https://beacon.example.com';
const _other = 'https://other.example.org/beacon';

http.Response _json(int status, Object? body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  late MemoryTokenStore tokens;
  late List<Uri> launched;
  late List<http.Request> requests;
  late http.Response Function(http.Request) exchange;
  late DateTime now;
  late Map<String, AccountState> accounts;
  late bool launchOk;

  SignInFlow make() => SignInFlow(
    apiFor: (url) => AuthApi(
      url,
      tokens,
      client: MockClient((r) async {
        requests.add(r);
        return exchange(r);
      }),
    ),
    launch: (uri) async {
      launched.add(uri);
      return launchOk;
    },
    now: () => now,
    random: Random(7),
    accountFor: (url) => accounts[url],
  );

  setUp(() {
    tokens = MemoryTokenStore();
    launched = [];
    requests = [];
    launchOk = true;
    now = DateTime.utc(2026, 11, 15, 12);
    accounts = {};
    exchange = (_) => _json(200, {
      'token': 'tok',
      'expiresAt': 1,
      'user': {'username': 'ridge'},
    });
  });

  Uri callback(String state, {String code = 'the-code'}) =>
      Uri.parse('meshcorebeacon://auth?code=$code&state=$state');

  test(
    'start opens the web sign-in page with exactly the expected query',
    () async {
      final flow = make();
      await flow.start(_server);
      final url = launched.single;
      expect(url.origin, _server);
      expect(url.path, '/');
      expect(url.queryParameters.keys.toSet(), {
        'view',
        'app',
        'code_challenge',
        'state',
      });
      expect(url.queryParameters['view'], 'signin');
      expect(url.queryParameters['app'], '1');
      final pending = flow.pending!;
      expect(pending.serverUrl, _server);
      expect(url.queryParameters['state'], pending.state);
      expect(
        url.queryParameters['code_challenge'],
        pkceChallenge(pending.verifier),
      );
      expect(pending.verifier.length, 43);
      expect(pending.state.length, 22);
      expect(pending.expiresAt, now.add(const Duration(minutes: 10)));
    },
  );

  test('a server path is kept and an existing query is not lost', () async {
    final flow = make();
    await flow.start('$_other?x=1');
    final url = launched.single;
    expect(url.path, '/beacon/');
    expect(url.queryParameters['x'], '1');
    expect(url.queryParameters['view'], 'signin');
  });

  test('a launch that fails clears the pending sign-in and throws', () async {
    launchOk = false;
    final flow = make();
    await expectLater(flow.start(_server), throwsA(anything));
    expect(flow.pending, isNull);
  });

  test('a good callback stores the token for the pending server', () async {
    final flow = make();
    await flow.start(_other);
    final pending = flow.pending!;
    final result = await flow.handleCallback(callback(pending.state));
    expect(result.outcome, SignInOutcome.success);
    expect(await tokens.read(_other), 'tok');
    expect(await tokens.read(_server), isNull);
    expect(requests.single.url.toString(), '$_other/api/v1/auth/app/token');
    expect(jsonDecode(requests.single.body), {
      'code': 'the-code',
      'codeVerifier': pending.verifier,
    });
    expect(flow.pending, isNull);
  });

  test('the active server account is told about the new user', () async {
    final account = AccountState(AuthApi(_server, tokens));
    accounts[_server] = account;
    final flow = make();
    await flow.start(_server);
    await flow.handleCallback(callback(flow.pending!.state));
    expect(account.user?['username'], 'ridge');
  });

  test('a server that is not active has no account to tell', () async {
    final account = AccountState(AuthApi(_server, tokens));
    accounts[_server] = account;
    final flow = make();
    await flow.start(_other);
    final result = await flow.handleCallback(callback(flow.pending!.state));
    expect(result.outcome, SignInOutcome.success);
    expect(account.signedIn, false);
  });

  test('a wrong state is ignored and keeps the pending sign-in', () async {
    final flow = make();
    await flow.start(_server);
    final result = await flow.handleCallback(callback('nope'));
    expect(result.outcome, SignInOutcome.ignored);
    expect(requests, isEmpty);
    expect(await tokens.read(_server), isNull);
    expect(flow.pending, isNotNull);
  });

  test('an expired sign-in is ignored and cleared', () async {
    final flow = make();
    await flow.start(_server);
    final state = flow.pending!.state;
    now = now.add(const Duration(minutes: 10, seconds: 1));
    final result = await flow.handleCallback(callback(state));
    expect(result.outcome, SignInOutcome.ignored);
    expect(requests, isEmpty);
    expect(flow.pending, isNull);
  });

  test('a repeated callback does nothing', () async {
    final flow = make();
    await flow.start(_server);
    final link = callback(flow.pending!.state);
    expect((await flow.handleCallback(link)).outcome, SignInOutcome.success);
    expect((await flow.handleCallback(link)).outcome, SignInOutcome.ignored);
    expect(requests, hasLength(1));
  });

  test('an unsolicited callback does nothing', () async {
    final flow = make();
    final result = await flow.handleCallback(callback('anything'));
    expect(result.outcome, SignInOutcome.ignored);
    expect(requests, isEmpty);
    expect(await tokens.read(_server), isNull);
  });

  test(
    'a link for another scheme or host, or without a code, is ignored',
    () async {
      final flow = make();
      await flow.start(_server);
      final state = flow.pending!.state;
      for (final link in [
        'https://auth/?code=c&state=$state',
        'meshcorebeacon://other?code=c&state=$state',
        'meshcorebeacon://auth?state=$state',
        'meshcorebeacon://auth?code=c',
      ]) {
        expect(
          (await flow.handleCallback(Uri.parse(link))).outcome,
          SignInOutcome.ignored,
          reason: link,
        );
      }
      expect(requests, isEmpty);
      expect(flow.pending, isNotNull);
    },
  );

  test('starting again replaces the pending sign-in', () async {
    final flow = make();
    await flow.start(_server);
    final first = flow.pending!;
    await flow.start(_other);
    expect(flow.pending!.serverUrl, _other);
    final result = await flow.handleCallback(callback(first.state));
    expect(result.outcome, SignInOutcome.ignored);
    expect(requests, isEmpty);
  });

  test('a failed exchange leaves the app signed out with a message', () async {
    exchange = (_) => _json(400, {
      'error': {'code': 'token_invalid', 'message': 'That code is no good.'},
    });
    final account = AccountState(AuthApi(_server, tokens));
    accounts[_server] = account;
    final flow = make();
    await flow.start(_server);
    final result = await flow.handleCallback(callback(flow.pending!.state));
    expect(result.outcome, SignInOutcome.failed);
    expect(result.message, 'That code is no good.');
    expect(await tokens.read(_server), isNull);
    expect(account.signedIn, false);
    expect(flow.pending, isNull);
  });

  test('the last result is kept and listeners hear about it', () async {
    final flow = make();
    var heard = 0;
    flow.addListener(() => heard++);
    await flow.handleCallback(callback('x'));
    expect(flow.lastResult, isNull);
    await flow.start(_server);
    await flow.handleCallback(callback(flow.pending!.state));
    expect(flow.lastResult?.outcome, SignInOutcome.success);
    expect(heard, 1);
  });

  group('SignInLinks', () {
    test('handles the cold start link and later links, then stops', () async {
      final flow = make();
      await flow.start(_server);
      final state = flow.pending!.state;
      final source = _FakeSource(initial: callback(state));
      final links = SignInLinks(flow, source);
      await links.listen();
      expect(await tokens.read(_server), 'tok');

      await flow.start(_server);
      source.controller.add(callback(flow.pending!.state, code: 'second'));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(requests, hasLength(2));

      await links.dispose();
      expect(source.controller.hasListener, false);
      await source.close();
    });

    test('a failing link plugin does not break start up', () async {
      final source = _FakeSource(failInitial: true);
      final links = SignInLinks(make(), source);
      await links.listen();
      await links.dispose();
      await source.close();
    });
  });
}

class _FakeSource implements LinkSource {
  _FakeSource({this.initial, this.failInitial = false});
  final Uri? initial;
  final bool failInitial;
  final controller = StreamController<Uri>();
  Future<void> close() => controller.close();
  @override
  Future<Uri?> initialLink() async {
    if (failInitial) throw StateError('no plugin');
    return initial;
  }

  @override
  Stream<Uri> get links => controller.stream;
}
