import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api.dart';
import 'features.dart';
import 'json.dart';
import 'token_store.dart';

/// A write on a stale revision; [current] is the collection the server holds,
/// null when the answer did not carry it.
class AtlasConflict implements Exception {
  const AtlasConflict(this.current);
  final Json? current;
  @override
  String toString() => 'Atlas was changed elsewhere';
}

/// A sign-in exchange that a newer sign-in attempt, a completed sign-in or a
/// sign-out overtook; its session was dropped and nothing should be reported.
class SignInSuperseded implements Exception {
  const SignInSuperseded();
  @override
  String toString() => 'Sign-in was superseded';
}

/// Signed-in calls for one server. Separate from [ApiClient] so a token never
/// rides on a cached read: no cache, no shared state, default User-Agent.
class AuthApi {
  /// [base] is the saved server URL, which is also the token's key.
  AuthApi(this.base, this.tokens, {http.Client? client})
    : _client = client ?? http.Client();
  final String base;
  final TokenStore tokens;
  final http.Client _client;

  // One generation per server, shared by every AuthApi for it.
  static final _generations = <String, int>{};
  int get _generation => _generations[base] ?? 0;
  void _bump() => _generations[base] = _generation + 1;

  /// Makes any exchange still in flight for this server give up. Called when
  /// a new sign-in starts.
  void supersedeSignIn() => _bump();

  /// Called when the server says the session is gone, after the token is deleted.
  void Function()? onSignedOut;

  Uri _uri(String path) => Uri.parse(
    '${base.replaceFirst(RegExp(r'/+$'), '')}/api/v1${path.startsWith('/') ? path : '/$path'}',
  );

  /// Sends the stored token as Bearer; never a cookie or the CSRF header.
  Future<Json> send(String method, String path, {Json? body}) =>
      _request(method, path, body: body, authorize: true);

  /// The answer to a request sent with a token that is no longer this server's
  /// session; its result must not be acted on.
  static const sessionChangedCode = 'session_changed';

  Future<Json> _request(
    String method,
    String path, {
    Json? body,
    required bool authorize,
    String? sentToken,
    bool tokenKnown = false,
  }) async {
    // The stored token is the session generation: a request owns the one it
    // sent, whichever AuthApi of this server made it.
    final token = !authorize
        ? null
        : (tokenKnown ? sentToken : await tokens.read(base));
    http.Response response;
    try {
      response = await requestLimited(
        _client,
        method,
        _uri(path),
        1024 * 1024,
        headers: {
          if (token != null) 'Authorization': 'Bearer $token',
          if (body != null) 'Content-Type': 'application/json',
        },
        body: body == null ? null : jsonEncode(body),
      );
    } on TimeoutException {
      throw const ApiException(
        'The server took too long to respond. Try again.',
      );
    } on http.ClientException {
      throw const ApiException(
        'Could not connect to this server. Check your connection and URL.',
      );
    }
    if (authorize && await tokens.read(base) != token) {
      throw const ApiException(
        'The session changed while this was in progress.',
        code: sessionChangedCode,
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
        await _forget(token);
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
        body: decoded is Map ? object(decoded) : null,
      );
    }
    return object(decoded);
  }

  /// Deletes the stored token only while it is still [token], the one the
  /// failed or ending request used.
  Future<void> _forget(String? token) async {
    try {
      if (token != null) await tokens.deleteIfEquals(base, token);
    } catch (_) {}
    onSignedOut?.call();
  }

  /// The signed-in user; null when signed out or the server has no accounts.
  Future<Json?> me() async {
    final token = await tokens.read(base);
    if (token == null) return null;
    try {
      final user = (await _request(
        'GET',
        '/me',
        authorize: true,
        sentToken: token,
        tokenKnown: true,
      ))['user'];
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
    final generation = _generation;
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
    if (generation != _generation) {
      await _endDiscarded(token);
      throw const SignInSuperseded();
    }
    await tokens.write(base, token);
    if (generation != _generation) {
      // Overtaken while saving: take our token back out and end it.
      await tokens.deleteIfEquals(base, token);
      await _endDiscarded(token);
      throw const SignInSuperseded();
    }
    _bump();
    return result;
  }

  /// Best effort: asks the server to end a session this device will not use.
  Future<void> _endDiscarded(String token) async {
    try {
      await _client
          .post(
            _uri('/auth/logout'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  /// Ends the session on the server, but signs out here whatever the answer.
  Future<void> signOut() async {
    _bump();
    final token = await tokens.read(base);
    try {
      await _request(
        'POST',
        '/auth/logout',
        authorize: true,
        sentToken: token,
        tokenKnown: true,
      );
    } on ApiException {
      // An offline or expired session still has to sign out locally.
    } finally {
      await _forget(token);
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

  /// Local accounts confirm with their password; portal accounts have none and
  /// confirm with the typed username.
  Future<void> deleteAccount({
    String? currentPassword,
    String? confirmUsername,
  }) async {
    final token = await tokens.read(base);
    await _request(
      'DELETE',
      '/me',
      body: {
        'currentPassword': ?currentPassword,
        'confirmUsername': ?confirmUsername,
      },
      authorize: true,
      sentToken: token,
      tokenKnown: true,
    );
    await _forget(token);
  }

  Future<List<Json>> sessions() async =>
      rows((await send('GET', '/me/sessions'))['sessions']);

  Future<void> endSession(String id) async {
    await send('DELETE', '/me/sessions/${Uri.encodeComponent(id)}');
  }

  Future<void> endOtherSessions() async {
    await send('DELETE', '/me/sessions');
  }

  /// The user's telemetry requests and their limit.
  Future<Json> telemetryRequests() => send('GET', '/me/telemetry-requests');

  /// A blank password is left out, which asks for a request without one.
  Future<Json> createTelemetryRequest(String nodeId, {String? password}) =>
      send(
        'POST',
        '/me/telemetry-requests',
        body: {
          'nodeId': nodeId,
          if (password != null && password.isNotEmpty) 'password': password,
        },
      );

  /// [withPassword] with an empty [password] removes the stored one.
  Future<Json> updateTelemetryRequest(
    String id, {
    bool withPassword = false,
    String? password,
    bool? enabled,
  }) => send(
    'PATCH',
    '/me/telemetry-requests/${Uri.encodeComponent(id)}',
    body: {
      if (withPassword)
        'password': password == null || password.isEmpty ? null : password,
      'enabled': ?enabled,
    },
  );

  Future<void> deleteTelemetryRequest(String id) async {
    await send('DELETE', '/me/telemetry-requests/${Uri.encodeComponent(id)}');
  }

  /// Alert targets, their available kinds and rules.
  Future<Json> alerts() => send('GET', '/me/alerts');

  /// Upserts the rule for (target, kind); thresholds are in the kind's own unit.
  Future<Json> putAlertRule({
    required String targetKind,
    required String publicKey,
    required String kind,
    required int? threshold,
    required int? thresholdHigh,
    required bool enabled,
  }) => send(
    'PUT',
    '/me/alerts/rules',
    body: {
      'target': {'kind': targetKind, 'publicKey': publicKey},
      'kind': kind,
      'threshold': threshold,
      'thresholdHigh': thresholdHigh,
      'enabled': enabled,
    },
  );

  Future<void> deleteAlertRule(String id) async {
    await send('DELETE', '/me/alerts/rules/${Uri.encodeComponent(id)}');
  }

  /// Registers this session's push token; [platform] is ios or android.
  Future<void> registerDevice(String platform, String pushToken) async {
    await send(
      'POST',
      '/me/devices',
      body: {'platform': platform, 'pushToken': pushToken},
    );
  }

  /// Removes the push token of this session.
  Future<void> removeDevice() async {
    await send('DELETE', '/me/devices');
  }

  bool? _atlasTelemetry;
  DateTime? _atlasTelemetryAt;

  /// Whether the server stores Telemetry tiles and views in the account Atlas.
  /// Read from `/info`, kept for a few minutes; any failure reads as no.
  Future<bool> atlasTelemetry() async {
    final at = _atlasTelemetryAt;
    if (at != null &&
        DateTime.now().difference(at) < const Duration(minutes: 5)) {
      return _atlasTelemetry ?? false;
    }
    try {
      final info = await _request('GET', '/info', authorize: false);
      _atlasTelemetry = ServerFeatures.fromInfo(info).atlasTelemetry;
      _atlasTelemetryAt = DateTime.now();
      return _atlasTelemetry!;
    } catch (_) {
      return false;
    }
  }

  /// The account Atlas as the server holds it.
  Future<Json> atlas() => send('GET', '/me/atlas');

  /// Replaces the whole collection; throws [AtlasConflict] on a stale revision.
  Future<Json> putAtlas(int baseRevision, String range, List<Json> pins) async {
    try {
      return await send(
        'PUT',
        '/me/atlas',
        body: {'baseRevision': baseRevision, 'range': range, 'pins': pins},
      );
    } on ApiException catch (e) {
      final body = e.body;
      if (e.status == 409 && e.code == 'atlas_conflict') {
        final current = body?['current'];
        throw AtlasConflict(current is Map ? object(current) : null);
      }
      rethrow;
    }
  }
}
