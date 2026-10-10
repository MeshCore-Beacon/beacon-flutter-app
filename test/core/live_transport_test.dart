import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:beacon/core/live.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('empty configured region opens no all-regions socket', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var connections = 0;
    server.listen((request) {
      connections++;
      request.response.close();
    });
    final live = LiveConnection(Uri.parse('ws://127.0.0.1:${server.port}/ws'), {
      'region': 'empty',
      'iatas': '',
    });
    live.start();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(connections, 0);
    live.dispose();
    await server.close(force: true);
  });
  test(
    'foreground socket subscribes, streams, closes and resubscribes',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final received = <Map<String, dynamic>>[];
      final sockets = <WebSocket>[];
      final subscriptions = StreamController<int>.broadcast();
      int connections = 0;
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        connections++;
        socket.add(jsonEncode({'v': 1, 'type': 'hello'}));
        socket.listen((raw) {
          final m = Map<String, dynamic>.from(jsonDecode(raw as String) as Map);
          received.add(m);
          if (m['type'] == 'subscribe') {
            socket.add(jsonEncode({'v': 1, 'type': 'subscribed'}));
            socket.add(
              jsonEncode({
                'v': 1,
                'type': 'event',
                'event': 'nodeUpdate',
                'data': {'nodeId': 'sample'},
              }),
            );
            subscriptions.add(connections);
          }
        });
      });
      final live = LiveConnection(
        Uri.parse('ws://127.0.0.1:${server.port}/ws'),
        {'iatas': 'YOW,YYZ'},
      );
      final event = live.events.firstWhere((e) => e['event'] == 'nodeUpdate');
      live.start();
      expect(
        (await event.timeout(const Duration(seconds: 5)))['data']['nodeId'],
        'sample',
      );
      expect(live.status, 'live');
      expect(
        received.firstWhere((e) => e['type'] == 'subscribe')['scope']['iatas'],
        ['YOW', 'YYZ'],
      );
      live.stop();
      expect(live.status, 'offline');
      final second = subscriptions.stream.firstWhere((n) => n == 2);
      live.start();
      await second.timeout(const Duration(seconds: 5));
      expect(connections, 2);
      live.dispose();
      for (final socket in sockets) {
        await socket.close();
      }
      await server.close(force: true);
      await subscriptions.close();
    },
  );
  test('backoff resets only after a connection stays up', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <WebSocket>[];
    final subscribed = StreamController<int>.broadcast();
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      final n = sockets.length;
      socket.add(jsonEncode({'v': 1, 'type': 'hello'}));
      socket.listen((raw) {
        if ((jsonDecode(raw as String) as Map)['type'] != 'subscribe') return;
        socket.add(jsonEncode({'v': 1, 'type': 'subscribed'}));
        // A flapping proxy: drop the first two right after subscribe.
        if (n <= 2) socket.close();
        subscribed.add(n);
      });
    });
    var now = DateTime(2026);
    final live = LiveConnection(Uri.parse('ws://127.0.0.1:${server.port}/ws'), {
      'iatas': 'YOW',
    }, now: () => now);
    final third = subscribed.stream.firstWhere((n) => n == 3);
    live.start();
    await third.timeout(const Duration(seconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(live.attempts, 2);
    now = now.add(const Duration(seconds: 31));
    final dropped = Completer<void>();
    live.addListener(() {
      if (live.status == 'connecting' && !dropped.isCompleted) {
        dropped.complete();
      }
    });
    await sockets[2].close();
    await dropped.future.timeout(const Duration(seconds: 5));
    expect(live.attempts, 1);
    live.dispose();
    await server.close(force: true);
    await subscribed.close();
  });
}
