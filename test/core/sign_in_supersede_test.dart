import 'dart:async';
import 'dart:convert';

import 'package:beacon/core/account.dart';
import 'package:beacon/core/auth_api.dart';
import 'package:beacon/core/token_store.dart';
import 'package:beacon/features/account/sign_in.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const base = 'https://beacon.example.com';

http.Response reply(String token) => http.Response(
  jsonEncode({
    'token': token,
    'user': {'id': token, 'username': token},
  }),
  200,
);

Uri callback(String state, String code) =>
    Uri.parse('meshcorebeacon://auth?state=$state&code=$code');

/// Holds one read (counted from 1) until released.
class HeldReadStore extends MemoryTokenStore {
  HeldReadStore(this.holdRead);
  final int holdRead;
  int reads = 0;
  final held = Completer<void>();
  final release = Completer<void>();
  @override
  Future<String?> read(String url) async {
    final value = await super.read(url);
    if (++reads == holdRead) {
      held.complete();
      await release.future;
    }
    return value;
  }
}

/// Holds every delete until released, to open the check-then-delete window.
class HeldDeleteStore extends MemoryTokenStore {
  final held = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> delete(String url) async {
    if (!held.isCompleted) held.complete();
    await release.future;
    await super.delete(url);
  }

  @override
  Future<void> deleteIfEquals(String url, String token) async {
    if (!held.isCompleted) held.complete();
    await release.future;
    await super.deleteIfEquals(url, token);
  }
}

void main() {
  test('an older exchange does not overwrite a later sign-in', () async {
    final tokens = MemoryTokenStore();
    final delayed = Completer<http.Response>();
    final sent = Completer<void>();
    final paths = <String>[];
    final api = AuthApi(
      base,
      tokens,
      client: MockClient((r) async {
        paths.add(r.url.path);
        if (r.url.path.endsWith('/logout')) return http.Response('', 204);
        if (jsonDecode(r.body)['code'] == 'A') {
          sent.complete();
          return delayed.future;
        }
        return reply('B');
      }),
    );
    final account = AccountState(api);
    final flow = SignInFlow(
      apiFor: (_) => api,
      accountFor: (_) => account,
      launch: (_) async => true,
      now: DateTime.now,
    );
    await flow.start(base);
    final older = flow.handleCallback(callback(flow.pending!.state, 'A'));
    await sent.future;
    await flow.start(base);
    await flow.handleCallback(callback(flow.pending!.state, 'B'));
    delayed.complete(reply('A'));
    final result = await older;
    expect(result.outcome, SignInOutcome.ignored);
    expect(await tokens.read(base), 'B');
    expect(account.user!['id'], 'B');
    // The discarded session is ended on the server.
    expect(paths.where((p) => p.endsWith('/logout')), hasLength(1));
  });

  test('an older exchange does not sign back in after logout', () async {
    final tokens = MemoryTokenStore();
    final delayed = Completer<http.Response>();
    final sent = Completer<void>();
    final api = AuthApi(
      base,
      tokens,
      client: MockClient((r) async {
        if (r.url.path.endsWith('/logout')) return http.Response('', 204);
        if (jsonDecode(r.body)['code'] == 'A') {
          sent.complete();
          return delayed.future;
        }
        return reply('B');
      }),
    );
    final account = AccountState(api);
    final flow = SignInFlow(
      apiFor: (_) => api,
      accountFor: (_) => account,
      launch: (_) async => true,
      now: DateTime.now,
    );
    await flow.start(base);
    final older = flow.handleCallback(callback(flow.pending!.state, 'A'));
    await sent.future;
    await flow.start(base);
    await flow.handleCallback(callback(flow.pending!.state, 'B'));
    await account.signOut();
    delayed.complete(reply('A'));
    await older;
    expect(account.signedIn, false);
    expect(await tokens.read(base), isNull);
  });

  test('the generation is shared by separate AuthApi objects', () async {
    final tokens = MemoryTokenStore();
    final delayed = Completer<http.Response>();
    final sent = Completer<void>();
    final slow = AuthApi(
      base,
      tokens,
      client: MockClient((r) async {
        if (r.url.path.endsWith('/info')) return http.Response('{}', 200);
        sent.complete();
        return delayed.future;
      }),
    );
    final other = AuthApi(
      base,
      tokens,
      client: MockClient((_) async => reply('B')),
    );
    final older = slow.exchangeAppCode('A', 'v');
    final expectation = expectLater(older, throwsA(isA<SignInSuperseded>()));
    await sent.future;
    await other.exchangeAppCode('B', 'v');
    delayed.complete(reply('A'));
    await expectation;
    expect(await tokens.read(base), 'B');
  });

  test('a signed-out refresh does not clear a new sign-in', () async {
    final tokens = HeldReadStore(1);
    final api = AuthApi(
      base,
      tokens,
      client: MockClient((_) async => reply('B')),
    );
    final account = AccountState(api);
    final pending = account.refresh();
    await tokens.held.future;
    await account.signIn('B', 'v');
    expect(account.user!['id'], 'B');
    tokens.release.complete();
    await pending;
    expect(account.user?['id'], 'B');
    expect(await tokens.read(base), 'B');
  });

  test('a 401 for an old token does not delete a newer one', () async {
    final tokens = HeldDeleteStore();
    await tokens.write(base, 'A');
    final api = AuthApi(
      base,
      tokens,
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'error': {'code': 'not_signed_in'},
          }),
          401,
        ),
      ),
    );
    final pending = expectLater(api.sessions(), throwsA(anything));
    await tokens.held.future;
    await tokens.write(base, 'B');
    tokens.release.complete();
    await pending;
    expect(await tokens.read(base), 'B');
  });
}
