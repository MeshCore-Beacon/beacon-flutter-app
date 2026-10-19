import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'json.dart';

class ApiException implements Exception {
  const ApiException(this.message, {this.status, this.retryAfter});
  final String message;
  final int? status;
  final Duration? retryAfter;
  @override
  String toString() => message;
}

/// Query params for the next page of /packets, /nodes or /observers: both cursors when the
/// server sent both, so a server that ignores pageCursor still advances. Empty when done.
Map<String, Object> nextPageParams(Map<String, dynamic> page) {
  if (page['hasMore'] != true) return {};
  final Object? cursor = page['nextCursor'];
  final pageCursor = page['nextPageCursor'];
  return {
    'cursor': ?cursor,
    if (pageCursor is String && pageCursor.isNotEmpty) 'pageCursor': pageCursor,
  };
}

/// A 429, or a 503 that said when to come back.
bool isTransient(Object error) =>
    error is ApiException &&
    (error.status == 429 || (error.status == 503 && error.retryAfter != null));

Future<void> _sleep(Duration d) => Future<void>.delayed(d);

/// Runs [request] again after a transient error, waiting its retryAfter (10 s if absent),
/// at most [retries] times; rethrows anything else. Returns null once [isCurrent] turns false.
Future<T?> retryTransient<T>(
  Future<T> Function() request, {
  bool Function()? isCurrent,
  int retries = 3,
  Future<void> Function(Duration) wait = _sleep,
}) async {
  for (var attempt = 0; ; attempt++) {
    try {
      return await request();
    } catch (error) {
      if (!isTransient(error) || attempt >= retries) rethrow;
      await wait(
        (error as ApiException).retryAfter ?? const Duration(seconds: 10),
      );
      if (isCurrent != null && !isCurrent()) return null;
    }
  }
}

/// Reads a GET body, giving up once it passes [maxBytes] so a hostile
/// server can't exhaust memory.
Future<http.Response> getLimited(
  http.Client client,
  Uri url,
  int maxBytes,
) async {
  final request = http.Request('GET', url);
  final response = await client.send(request);
  const tooLarge = ApiException('Server response is too large.');
  if ((response.contentLength ?? 0) > maxBytes) {
    unawaited(response.stream.listen(null).cancel());
    throw tooLarge;
  }
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in response.stream) {
    bytes.add(chunk);
    if (bytes.length > maxBytes) throw tooLarge;
  }
  return http.Response.bytes(
    bytes.takeBytes(),
    response.statusCode,
    request: request,
    headers: response.headers,
    isRedirect: response.isRedirect,
    persistentConnection: response.persistentConnection,
    reasonPhrase: response.reasonPhrase,
  );
}

class ApiClient {
  ApiClient(
    this.base, {
    http.Client? client,
    DateTime Function()? now,
    this.maxResponseBytes = 16 * 1024 * 1024,
  }) : _client = client ?? http.Client(),
       _now = now ?? DateTime.now;
  final int maxResponseBytes;
  final DateTime Function() _now;
  final _cache = <String, _CachedResponse>{};
  final _pending = <String, Future<dynamic>>{};
  final _cacheTokens = <String, Object>{};
  int _cacheBytes = 0;
  final Uri base;
  final http.Client _client;
  bool _closed = false;
  DateTime? _limitedUntil;
  Uri uri(String path, [Map<String, dynamic> params = const {}]) =>
      Uri.parse(
        '${base.toString().replaceFirst(RegExp(r'/+$'), '')}/api/v1${path.startsWith('/') ? path : '/$path'}',
      ).replace(
        queryParameters: {
          for (final entry in params.entries)
            if (entry.value != null) entry.key: entry.value.toString(),
        },
      );
  String _key(String path, Map<String, dynamic> params) {
    final sorted = SplayTreeMap<String, dynamic>.from(params);
    return uri(path, sorted).toString();
  }

  bool _reference(String path) =>
      {'/iatas', '/regions', '/scopes', '/brokers'}.contains(path) ||
      RegExp(r'^/iatas/[^/]+/border$').hasMatch(path);

  Duration _ttl(String path, Map<String, dynamic> params) {
    if (path.endsWith('/border')) return const Duration(hours: 1);
    if (_reference(path)) return const Duration(minutes: 5);
    if (path == '/nodes' && '${params['neighbors']}' == 'true') {
      return const Duration(minutes: 5);
    }
    return const Duration(seconds: 30);
  }

  /// Each client belongs to one server. Queries include region, filters and cursor.
  dynamic peekCache(String path, [Map<String, dynamic> params = const {}]) {
    if (_closed) return null;
    final value = _cache[_key(path, params)];
    return value == null ? null : jsonDecode(value.body);
  }

  Future<dynamic> getCached(
    String path, [
    Map<String, dynamic> params = const {},
  ]) async {
    if (_closed) throw const ApiException('Connection changed.');
    final key = _key(path, params);
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      if (_now().difference(cached.saved) < _ttl(path, params)) {
        return jsonDecode(cached.body);
      }
    }
    return _readAndStore(path, params);
  }

  Future<dynamic> _readAndStore(
    String path,
    Map<String, dynamic> params,
  ) async {
    final key = _key(path, params);
    final token = _cacheTokens.putIfAbsent(key, Object.new);
    try {
      final value = await _sharedGet(path, params);
      if (!_closed && identical(token, _cacheTokens[key])) {
        _store(key, path, jsonEncode(value));
      }
      return value;
    } finally {
      if (!_cache.containsKey(key) && identical(token, _cacheTokens[key])) {
        _cacheTokens.remove(key);
      }
    }
  }

  void _store(String key, String path, String body) {
    _cacheBytes -= _cache.remove(key)?.body.length ?? 0;
    // Bound both entry count and encoded character storage for large map datasets.
    if (body.length > 8 * 1024 * 1024) return;
    _cache[key] = _CachedResponse(path, body, _now());
    _cacheBytes += body.length;
    while (_cache.length > 256 || _cacheBytes > 8 * 1024 * 1024) {
      final evicted = _cache.keys.first;
      _cacheBytes -= _cache.remove(evicted)!.body.length;
      _cacheTokens.remove(evicted);
    }
  }

  void invalidateCache({String? prefix}) {
    bool matches(String key) {
      final path = Uri.parse(key).path;
      final target = prefix == null ? null : uri(prefix).path;
      return target == null || path == target || path.startsWith('$target/');
    }

    for (final key in _cache.keys.where(matches).toList()) {
      _cacheBytes -= _cache.remove(key)!.body.length;
    }
    _cacheTokens.removeWhere((key, _) => matches(key));
    _pending.removeWhere((key, _) => matches(key));
  }

  void handleLiveEvent(Json event) {
    if (event['type'] == 'refresh') {
      final paths = {
        ..._cache.values.map((v) => v.path),
        ..._pending.keys.map(
          (key) => Uri.parse(key).path.substring(uri('/').path.length - 1),
        ),
      };
      for (final path in paths) {
        if (!_reference(path)) invalidateCache(prefix: path);
      }
      return;
    }
    final data = object(event['data']);
    switch (event['event']) {
      case 'nodeUpdate':
        _patchList('/nodes', textOf(data['nodeId']), data);
      case 'observerStatus':
        _patchList('/observers', textOf(data['observerId']), data);
      case 'channelMessage':
        invalidateCache(prefix: '/channels');
      case 'packetObservation':
        final hash = textOf(data['packetHash']);
        if (hash.isNotEmpty) invalidateCache(prefix: '/packets/$hash');
    }
  }

  void _patchList(String path, String id, Json data) {
    if (id.isEmpty) return;
    var found = false;
    for (final entry in _cache.entries.toList()) {
      if (entry.value.path != path) continue;
      final params = Uri.parse(entry.key).queryParameters;
      // Filter membership can change. Such queries need authoritative results.
      if (params.keys.any(
        (k) => !{
          'iatas',
          'region',
          'neighbors',
          'limit',
          'cursor',
          'pageCursor',
        }.contains(k),
      )) {
        _cacheBytes -= _cache.remove(entry.key)!.body.length;
        _cacheTokens.remove(entry.key);
        continue;
      }
      final value = jsonDecode(entry.value.body);
      final list = rows(value);
      final index = list.indexWhere((r) => textOf(r['id']) == id);
      if (index < 0) continue;
      if ((params.containsKey('iatas') || params.containsKey('region')) &&
          data.containsKey('iatas') &&
          jsonEncode(list[index]['iatas']) != jsonEncode(data['iatas'])) {
        _cacheBytes -= _cache.remove(entry.key)!.body.length;
        _cacheTokens.remove(entry.key);
        _pending.remove(entry.key);
        continue;
      }
      found = true;
      // Don't let an older request overwrite this live update in the cache.
      _cacheTokens.remove(entry.key);
      _pending.remove(entry.key);
      final patch = {...data}
        ..remove('nodeId')
        ..remove('observerId');
      if (textOf(patch['name']).isEmpty) patch.remove('name');
      if (path == '/observers' && patch['online'] is bool) {
        patch['status'] = patch['online'] == true ? 'online' : 'offline';
      }
      list[index] = {...list[index], ...patch, 'id': id};
      final updated = value is List ? list : {...object(value), 'items': list};
      final body = jsonEncode(updated);
      _cacheBytes += body.length - entry.value.body.length;
      _cache[entry.key] = _CachedResponse(path, body, entry.value.saved);
    }
    if (!found) {
      invalidateCache(prefix: path);
    } else {
      invalidateCache(prefix: '$path/$id');
    }
  }

  Future<dynamic> get(String path, [Map<String, dynamic> params = const {}]) =>
      _reference(path) ? getCached(path, params) : _readAndStore(path, params);

  Future<dynamic> _sharedGet(String path, Map<String, dynamic> params) async {
    if (_closed) throw const ApiException('Connection changed.');
    final key = _key(path, params);
    var request = _pending[key];
    if (request == null) {
      request = _fetch(path, params);
      _pending[key] = request;
    }
    try {
      final value = await request;
      // Callers can merge live events without mutating other screens' snapshots.
      return value == null ? null : jsonDecode(jsonEncode(value));
    } finally {
      if (identical(_pending[key], request)) unawaited(_pending.remove(key));
    }
  }

  Future<dynamic> _fetch(
    String path, [
    Map<String, dynamic> params = const {},
  ]) async {
    if (_closed) {
      throw const ApiException('Connection changed. Refresh to try again.');
    }
    if (_limitedUntil != null && _now().isBefore(_limitedUntil!)) {
      throw ApiException(
        'Server is busy. Try again shortly.',
        status: 429,
        retryAfter: _limitedUntil!.difference(_now()),
      );
    }
    try {
      final response = await getLimited(
        _client,
        uri(path, params),
        maxResponseBytes,
      ).timeout(const Duration(seconds: 25));
      if (_closed) throw const ApiException('Connection changed.');
      if ((response.headers['cache-control'] ?? '').toLowerCase().contains(
        'no-store',
      )) {
        final key = _key(path, params);
        _cacheBytes -= _cache.remove(key)?.body.length ?? 0;
        _cacheTokens.remove(key);
      }
      if (response.statusCode == 204) return null;
      dynamic body;
      try {
        body = jsonDecode(response.body);
      } catch (_) {
        body = null;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        Duration? delay;
        final header = response.headers['retry-after'];
        if (response.statusCode == 429) {
          delay = _retryAfter(header) ?? const Duration(seconds: 10);
          _limitedUntil = _now().add(delay);
        } else if (response.statusCode == 503) {
          // A busy 503 is per request, so it must not block other screens.
          delay = _retryAfter(header);
        }
        throw ApiException(
          textOf(
            object(object(body)['error'])['message'],
            'Server returned HTTP ${response.statusCode}.',
          ),
          status: response.statusCode,
          retryAfter: delay,
        );
      }
      if (body == null) {
        throw const ApiException(
          'This address did not return Beacon API data. Check the server URL.',
        );
      }
      return body;
    } on TimeoutException {
      throw const ApiException(
        'The server took too long to respond. Try again.',
      );
    } on http.ClientException {
      throw const ApiException(
        'Could not connect to this server. Check your connection and URL.',
      );
    } on SocketException {
      throw const ApiException(
        'Could not reach this server. Check your connection.',
      );
    }
  }

  Duration? _retryAfter(String? header) {
    if (header == null) return null;
    final seconds = int.tryParse(header);
    DateTime? date;
    if (seconds == null) {
      try {
        date = HttpDate.parse(header);
      } catch (_) {}
    }
    return Duration(
      seconds: (seconds ?? date?.difference(_now()).inSeconds ?? 10).clamp(
        1,
        300,
      ),
    );
  }

  void close() {
    _closed = true;
    invalidateCache();
    _client.close();
  }
}

class _CachedResponse {
  const _CachedResponse(this.path, this.body, this.saved);
  final String path, body;
  final DateTime saved;
}
