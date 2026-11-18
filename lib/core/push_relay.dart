import 'dart:convert';

import 'package:http/http.dart' as http;

class PushRelayException implements Exception {
  const PushRelayException(this.status, [this.code = '']);
  final int status;
  final String code;
  @override
  String toString() => 'PushRelayException($status $code)';
}

/// The app's side of the push server API (beacon-push `/v1/handles`).
class PushRelay {
  PushRelay({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;
  static const _timeout = Duration(seconds: 15);

  Uri _url(Uri server, [String? handle]) => server.replace(
    path:
        '${server.path.replaceFirst(RegExp(r'/+$'), '')}/v1/handles'
        '${handle == null ? '' : '/${Uri.encodeComponent(handle)}'}',
  );

  Future<http.Response> _send(String method, Uri url, Object body) async {
    final request = http.Request(method, url)
      ..headers['content-type'] = 'application/json'
      ..body = jsonEncode(body);
    final streamed = await _client.send(request).timeout(_timeout);
    return http.Response.fromStream(streamed).timeout(_timeout);
  }

  static PushRelayException _error(http.Response r) {
    var code = '';
    try {
      final error = (jsonDecode(r.body) as Map)['error'];
      if (error is Map && error['code'] is String) {
        code = error['code'] as String;
      }
    } catch (_) {}
    return PushRelayException(r.statusCode, code);
  }

  /// A handle for [pushId]'s server only, and the secret that manages it.
  Future<(String, String)> createHandle(
    Uri server, {
    required String pushId,
    required String platform,
    required String token,
    String? apnsEnvironment,
  }) async {
    final r = await _send('POST', _url(server), {
      'pushId': pushId,
      'platform': platform,
      'token': token,
      'apnsEnvironment': ?apnsEnvironment,
    });
    if (r.statusCode < 200 || r.statusCode > 299) throw _error(r);
    try {
      final json = jsonDecode(r.body) as Map;
      final handle = json['handle'], secret = json['handleSecret'];
      if (handle is String && handle.isNotEmpty && secret is String) {
        if (secret.isNotEmpty) return (handle, secret);
      }
    } catch (_) {}
    throw PushRelayException(r.statusCode, 'bad_answer');
  }

  /// Moves the handle to a refreshed token. iOS sends its APNs environment
  /// every time; Android sends none.
  Future<void> updateHandle(
    Uri server,
    String handle, {
    required String handleSecret,
    required String token,
    String? apnsEnvironment,
  }) async {
    final r = await _send('PUT', _url(server, handle), {
      'handleSecret': handleSecret,
      'token': token,
      'apnsEnvironment': ?apnsEnvironment,
    });
    if (r.statusCode < 200 || r.statusCode > 299) throw _error(r);
  }

  /// Stops the handle; one the push server no longer knows is already gone.
  Future<void> deleteHandle(
    Uri server,
    String handle, {
    required String handleSecret,
  }) async {
    final r = await _send('DELETE', _url(server, handle), {
      'handleSecret': handleSecret,
    });
    if (r.statusCode == 404) return;
    if (r.statusCode < 200 || r.statusCode > 299) throw _error(r);
  }
}
