import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:beacon/core/api.dart';
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
    await sockets[2].close();
    // The healthy link's drop hides behind the reconnect grace, so watch the backoff instead.
    for (var i = 0; i < 100 && live.attempts != 1; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(live.attempts, 1);
    live.dispose();
    await server.close(force: true);
    await subscribed.close();
  });
  test(
    'sends a ticket when it gets one and connects without otherwise',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final tickets = <String?>[];
      final sockets = <WebSocket>[];
      server.listen((request) async {
        tickets.add(request.headers.value('x-beacon-ticket'));
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.add(jsonEncode({'v': 1, 'type': 'hello'}));
        socket.listen((raw) {
          if ((jsonDecode(raw as String) as Map)['type'] == 'subscribe') {
            socket.add(jsonEncode({'v': 1, 'type': 'subscribed'}));
          }
        });
      });
      Future<void> connectWith(Future<String> Function() ticket) async {
        final live = LiveConnection(
          Uri.parse('ws://127.0.0.1:${server.port}/ws'),
          {'iatas': 'YOW'},
          ticket: ticket,
        );
        final ready = Completer<void>();
        live.addListener(() {
          if (live.status == 'live' && !ready.isCompleted) ready.complete();
        });
        live.start();
        await ready.future.timeout(const Duration(seconds: 5));
        live.dispose();
      }

      await connectWith(() async => 'abc');
      await connectWith(
        () async => throw const ApiException('Not found', status: 404),
      );
      expect(tickets, ['abc', null]);
      for (final socket in sockets) {
        await socket.close();
      }
      await server.close(force: true);
    },
  );
  group('reconnect grace', () {
    late HttpServer server;
    late List<WebSocket> sockets;
    late int subscribes;
    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      sockets = [];
      subscribes = 0;
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.add(jsonEncode({'v': 1, 'type': 'hello'}));
        socket.listen((raw) {
          if ((jsonDecode(raw as String) as Map)['type'] == 'subscribe') {
            subscribes++;
            socket.add(jsonEncode({'v': 1, 'type': 'subscribed'}));
          }
        });
      });
    });
    tearDown(() async {
      for (final socket in sockets) {
        await socket.close();
      }
      await server.close(force: true);
    });

    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 100 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(done(), true);
    }

    // Returns the connection, live, with its clock and later statuses recorded.
    Future<(LiveConnection, List<String>, void Function(Duration))> live({
      Duration grace = const Duration(seconds: 3),
    }) async {
      var clock = DateTime(2026);
      final live = LiveConnection(
        Uri.parse('ws://127.0.0.1:${server.port}/ws'),
        {'iatas': 'YOW'},
        now: () => clock,
        reconnectGrace: grace,
      );
      final seen = <String>[];
      live.addListener(() => seen.add(live.status));
      live.start();
      await until(() => live.status == 'live');
      seen.clear();
      return (live, seen, (Duration d) => clock = clock.add(d));
    }

    test('a quick reconnect after a healthy link keeps showing live', () async {
      final (connection, seen, advance) = await live();
      advance(const Duration(minutes: 1));
      await sockets.first.close();
      await until(() => subscribes == 2);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(seen.where((s) => s != 'live'), isEmpty);
      expect(connection.status, 'live');
      connection.dispose();
    });

    test('a reconnect that outlasts the grace shows connecting', () async {
      final (connection, seen, advance) = await live(
        grace: const Duration(milliseconds: 100),
      );
      advance(const Duration(minutes: 1));
      await sockets.first.close();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(connection.status, 'live');
      await until(() => connection.status == 'connecting');
      connection.dispose();
    });

    test('a drop soon after subscribing shows connecting at once', () async {
      final (connection, seen, _) = await live();
      await sockets.first.close();
      await until(() => seen.contains('connecting'));
      connection.dispose();
    });
  });
}
