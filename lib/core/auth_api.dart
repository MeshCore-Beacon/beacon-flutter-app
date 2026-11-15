import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api.dart';
import 'json.dart';
import 'token_store.dart';

/// Signed-in calls for one server. Separate from [ApiClient] so a token never
/// rides on a cached read: no cache, no shared state, default User-Agent.
class AuthApi {
  /// [base] is the saved server URL, which is also the token's key.
  AuthApi(this.base, this.tokens, {http.Client? client})
    : _client = client ?? http.Client();
  final String base;
  final TokenStore tokens;
  final http.Client _client;

  /// Called when the server says the session is gone, after the token is deleted.
  void Function()? onSignedOut;

  Uri _uri(String path) => Uri.parse(
    '${base.replaceFirst(RegExp(r'/+$'), '')}/api/v1${path.startsWith('/') ? path : '/$path'}',
  );

  /// Sends the stored token as Bearer; never a cookie or the CSRF header.
  Future<Json> send(String method, String path, {Json? body}) =>
      _request(method, path, body: body, authorize: true);

  Future<Json> _request(
    String method,
    String path, {
    Json? body,
    required bool authorize,
  }) async {
    final request = http.Request(method, _uri(path));
    if (authorize) {
      final token = await tokens.read(base);
      if (token != null) request.headers['Authorization'] = 'Bearer $token';
    }
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    http.Response response;
    try {
      response = await http.Response.fromStream(
        await _client.send(request).timeout(const Duration(seconds: 25)),
      ).timeout(const Duration(seconds: 25));
    } on TimeoutException {
      throw const ApiException(
        'The server took too long to respond. Try again.',
      );
    } on http.ClientException {
      throw const ApiException(
        'Could not connect to this server. Check your connection and URL.',
      );
    }
    dynamic decoded;
    try {
      decoded = response.body.isEmpty ? null : jsonDecode(response.body);
    } catch (_) {
      decoded = null;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = object(object(decoded)['error']);
      final code = error['code'] is String ? error['code'] as String : null;
      if (authorize && response.statusCode == 401 && code == 'not_signed_in') {
        await _forget();
      }
      final seconds = int.tryParse(response.headers['retry-after'] ?? '');
      throw ApiException(
        textOf(
          error['message'],
          'Server returned HTTP ${response.statusCode}.',
        ),
        status: response.statusCode,
        retryAfter: seconds == null ? null : Duration(seconds: seconds),
        code: code,
      );
    }
    return object(decoded);
  }

  Future<void> _forget() async {
    try {
      await tokens.delete(base);
    } catch (_) {}
    onSignedOut?.call();
  }

  /// The signed-in user; null when signed out or the server has no accounts.
  Future<Json?> me() async {
    if (await tokens.read(base) == null) return null;
    try {
      final user = (await send('GET', '/me'))['user'];
      return user is Map ? object(user) : null;
    } on ApiException catch (e) {
      if (e.code == 'accounts_disabled' || e.code == 'not_signed_in') {
        return null;
      }
      rethrow;
    }
  }

  /// Trades the sign-in code for a session token and stores it.
  Future<Json> exchangeAppCode(String code, String verifier) async {
    final result = await _request(
      'POST',
      '/auth/app/token',
      body: {'code': code, 'codeVerifier': verifier},
      authorize: false,
    );
    final token = result['token'];
    if (token is! String || token.isEmpty) {
      throw const ApiException('The server sent no session token.');
    }
    await tokens.write(base, token);
    return result;
  }

  /// Ends the session on the server, but signs out here whatever the answer.
  Future<void> signOut() async {
    try {
      await send('POST', '/auth/logout');
    } on ApiException {
      // An offline or expired session still has to sign out locally.
    } finally {
      await _forget();
    }
  }

  Future<Json> setDisplayName(String name) async =>
      object((await send('PATCH', '/me', body: {'displayName': name}))['user']);

  Future<void> changePassword(String current, String next) async {
    await send(
      'POST',
      '/me/password',
      body: {'currentPassword': current, 'newPassword': next},
    );
  }

  Future<Json> changeEmail(String email, String currentPassword) => send(
    'POST',
    '/me/email',
    body: {'email': email, 'currentPassword': currentPassword},
  );

  Future<void> deleteAccount(String currentPassword) async {
    await send('DELETE', '/me', body: {'currentPassword': currentPassword});
    await _forget();
  }

  Future<List<Json>> sessions() async =>
      rows((await send('GET', '/me/sessions'))['sessions']);

  Future<void> endSession(String id) async {
    await send('DELETE', '/me/sessions/${Uri.encodeComponent(id)}');
  }

  Future<void> endOtherSessions() async {
    await send('DELETE', '/me/sessions');
  }
}
