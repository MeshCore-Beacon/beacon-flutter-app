import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'json.dart';

Json? decodeLiveEvent(String source) {
  try {
    final message = object(jsonDecode(source));
    if (message['v'] != 1 ||
        message['type'] != 'event' ||
        message['data'] is! Map) {
      return null;
    }
    return message;
  } catch (_) {
    return null;
  }
}

class LiveConnection extends ChangeNotifier {
  LiveConnection(
    this.uri,
    this.region, {
    DateTime Function()? now,
    this.ticket,
    this.reconnectGrace = const Duration(seconds: 3),
  }) : _now = now ?? DateTime.now;
  final DateTime Function() _now;

  /// A healthy link that drops keeps showing live this long, so a server reload goes unseen.
  final Duration reconnectGrace;
  Timer? _grace;

  /// Fetches a /ws ticket before each connect; null, or a failure, connects without one.
  final Future<String> Function()? ticket;
  final Uri uri;
  final Map<String, dynamic> region;
  final _events = StreamController<Json>.broadcast();
  Stream<Json> get events => _events.stream;
  String status = 'offline';
  WebSocket? _socket;
  Timer? _heartbeat;
  Timer? _retry;
  int _attempts = 0;
  @visibleForTesting
  int get attempts => _attempts;
  DateTime? _subscribedAt;
  int _generation = 0;
  bool _running = false;
  bool _disposed = false;
  DateTime _lastReceived = DateTime.now();
  void _status(String value) {
    if (_disposed) return;
    if (_grace != null && value == 'connecting') return;
    _grace?.cancel();
    _grace = null;
    status = value;
    notifyListeners();
  }

  // A server older than tickets answers 404; it needs none, so connect without one.
  Future<String?> _ticket() async {
    final fetch = ticket;
    if (fetch == null) return null;
    try {
      final value = await fetch().timeout(const Duration(seconds: 10));
      return value.isEmpty ? null : value;
    } catch (_) {
      return null;
    }
  }

  void start() {
    if (_running || _disposed) return;
    if (region['iatas'] == '' ||
        (region['region'] != null && region['iatas'] == null)) {
      return;
    }
    _running = true;
    _connect();
  }

  Future<void> _connect() async {
    if (!_running || _disposed) return;
    final generation = ++_generation;
    _status('connecting');
    try {
      final pass = await _ticket();
      if (!_running || _disposed || generation != _generation) return;
      // Keep dart:io's "Dart/" UA here too: the scrape block lets it in.
      final socket = await WebSocket.connect(
        uri.toString(),
        headers: pass == null ? null : {'X-Beacon-Ticket': pass},
      ).timeout(const Duration(seconds: 20));
      if (!_running || _disposed || generation != _generation) {
        await socket.close();
        return;
      }
      _socket = socket;
      _lastReceived = DateTime.now();
      socket.listen(
        (dynamic raw) {
          if (_disposed || generation != _generation || raw is! String) return;
          _lastReceived = DateTime.now();
          Json message;
          try {
            message = object(jsonDecode(raw));
          } catch (_) {
            return;
          }
          if (message['v'] != 1) return;
          if (message['type'] == 'hello') {
            final iatas = textOf(region['iatas'])
                .split(',')
                .where((e) => e.isNotEmpty)
                .toList();
            _send({
              'type': 'configure',
              'resolvePath': true,
              'includeRepeats': false,
            });
            _send({
              'type': 'subscribe',
              'id': 'active',
              'scope': {
                if (iatas.isNotEmpty) 'iatas': iatas,
                if (region['region'] != null) 'regionSlugs': [region['region']],
                'events': [
                  'packetObservation',
                  'channelMessage',
                  'nodeUpdate',
                  'observerStatus',
                ],
              },
            });
          } else if (message['type'] == 'subscribed') {
            _subscribedAt = _now();
            _status('live');
            _events.add({'type': 'refresh'});
          } else if (message['type'] == 'lagged') {
            _events.add({'type': 'refresh'});
          } else {
            final event = decodeLiveEvent(raw);
            if (event != null) _events.add(event);
          }
        },
        onDone: () => _disconnected(generation),
        onError: (Object error) => _disconnected(generation),
        cancelOnError: true,
      );
      _heartbeat?.cancel();
      _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) {
        if (DateTime.now().difference(_lastReceived).inSeconds > 75) {
          _disconnected(generation);
        } else {
          _send({'type': 'ping'});
        }
      });
    } catch (_) {
      _disconnected(generation);
    }
  }

  void _send(Json message) {
    _socket?.add(jsonEncode({'v': 1, ...message}));
  }

  void _disconnected(int generation) {
    if (generation != _generation || !_running || _disposed) return;
    ++_generation;
    _heartbeat?.cancel();
    _socket?.close();
    _socket = null;
    _retry?.cancel();
    // Only a connection that stayed up resets backoff; a socket dropped right
    // after subscribe would otherwise reconnect and refresh every second.
    final since = _subscribedAt;
    _subscribedAt = null;
    if (since != null &&
        _now().difference(since) >= const Duration(seconds: 30)) {
      _attempts = 0;
      if (status == 'live') {
        _grace ??= Timer(reconnectGrace, () {
          _grace = null;
          _status('connecting');
        });
      }
    }
    _status('connecting');
    final seconds = min(30, pow(2, min(_attempts++, 5)).toInt());
    _retry = Timer(
      Duration(milliseconds: seconds * 1000 + Random().nextInt(800)),
      _connect,
    );
  }

  void stop() {
    _running = false;
    _subscribedAt = null;
    ++_generation;
    _retry?.cancel();
    _heartbeat?.cancel();
    _socket?.close();
    _socket = null;
    _status('offline');
  }

  @override
  void dispose() {
    stop();
    _disposed = true;
    _events.close();
    super.dispose();
  }
}
