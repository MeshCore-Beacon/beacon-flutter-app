import 'dart:convert';

import 'package:beacon/core/account.dart';
import 'package:beacon/core/auth_api.dart';
import 'package:beacon/core/strings.dart';
import 'package:beacon/core/theme.dart';
import 'package:beacon/core/token_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const server = 'https://beacon.example.com';

http.Response json(int status, Object? body, {Map<String, String>? headers}) =>
    http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json', ...?headers},
    );

http.Response failure(
  int status,
  String code,
  String message, {
  Map<String, String>? headers,
}) => json(status, {
  'error': {'code': code, 'message': message},
}, headers: headers);

Map<String, dynamic> user({
  String name = 'Ridge Walker',
  String? pendingEmail,
  bool verified = true,
  String provider = 'local',
}) => {
  'id': 'u1',
  'username': 'ridgewalker',
  'displayName': name,
  'email': 'a@example.org',
  'emailVerified': verified,
  'pendingEmail': pendingEmail,
  'provider': provider,
  'createdAt': 1794700000000,
};

Map<String, dynamic> session(
  String id, {
  String kind = 'web',
  bool current = false,
}) => {
  'id': id,
  'kind': kind,
  'label': 'Device $id',
  'current': current,
  'createdAt': 1794700000000,
  'lastUsedAt': 1794703600000,
  'expiresAt': 1797292000000,
};

Future<void> loadAssets() async {
  await Future.wait([BeaconTheme.load(), loadStrings()]);
  language = 'en';
}

/// A signed-in (or signed-out) account on [server] backed by [handler].
class Harness {
  Harness(this.handler, {bool signedIn = true}) {
    if (signedIn) tokens.write(server, 'tok');
    account = AccountState(
      AuthApi(
        server,
        tokens,
        client: MockClient((r) async {
          requests.add(r);
          final held = hold?.call(r);
          return held != null ? await held : handler(r);
        }),
      ),
    );
    if (signedIn) account.adopt(user());
  }
  final http.Response Function(http.Request) handler;
  final tokens = MemoryTokenStore();

  /// Returns a future to keep a request pending until the test releases it.
  Future<http.Response>? Function(http.Request)? hold;
  final requests = <http.Request>[];
  late final AccountState account;

  Iterable<http.Request> calls(String method, String path) =>
      requests.where((r) => r.method == method && r.url.path == '/api/v1$path');
}
