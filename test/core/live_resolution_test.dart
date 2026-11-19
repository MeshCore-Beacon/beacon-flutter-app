import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:beacon/core/live.dart';
import 'package:flutter_test/flutter_test.dart';

class RealHttp extends HttpOverrides {}

void main() {
  test('ordinary live listeners request no resolved path payload', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final configured = Completer<Map>();
      WebSocket? peer;
      server.listen((request) async {
        peer = await WebSocketTransformer.upgrade(request);
        peer!.add(jsonEncode({'v': 1, 'type': 'hello'}));
        peer!.listen((raw) {
          final message = jsonDecode(raw as String) as Map;
          if (message['type'] == 'configure' && !configured.isCompleted) {
            configured.complete(message);
          }
        });
      });
      final live = LiveConnection(
        Uri.parse('ws://127.0.0.1:${server.port}/ws'),
        {'iatas': 'YKF'},
      );
      live.start();
      final config = await configured.future.timeout(
        const Duration(seconds: 5),
      );
      live.dispose();
      await peer?.close();
      await server.close(force: true);
      expect(config['resolvePath'], isFalse);
      expect(config['includeRepeats'], isFalse);
    }, RealHttp());
  });
  test(
    'resolution follows shared listeners across reconnect and disposal',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final sockets = <WebSocket>[];
        final configs = <Map>[];
        final subscriptions = <Map>[];
        Future<void> until(bool Function() ready) async {
          final limit = Stopwatch()..start();
          while (!ready()) {
            if (limit.elapsed > const Duration(seconds: 5)) {
              fail('Timed out waiting for transport');
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        }

        server.listen((request) async {
          final socket = await WebSocketTransformer.upgrade(request);
          sockets.add(socket);
          socket.add(jsonEncode({'v': 1, 'type': 'hello'}));
          socket.listen((raw) {
            final message = jsonDecode(raw as String) as Map;
            if (message['type'] == 'configure') configs.add(message);
            if (message['type'] == 'subscribe') {
              subscriptions.add(message);
              socket.add(jsonEncode({'v': 1, 'type': 'subscribed'}));
            }
          });
        });
        final live = LiveConnection(
          Uri.parse('ws://127.0.0.1:${server.port}/ws'),
          {'iatas': 'YKF,YYZ'},
        );
        final baseEvents = <Map>[];
        final base = live.events.listen(baseEvents.add);
        final resolvedEvents = <Map>[];
        final first = live.resolvedEvents.listen(resolvedEvents.add);
        live.start();
        await until(() => configs.length == 1 && subscriptions.length == 1);
        expect(configs.last['resolvePath'], isTrue);
        expect(subscriptions.last['scope']['iatas'], ['YKF', 'YYZ']);
        sockets.single.add(
          jsonEncode({
            'v': 1,
            'type': 'event',
            'event': 'packetObservation',
            'data': {
              'observation': {
                'resolvedPath': [
                  {'confidence': 'high'},
                ],
              },
            },
          }),
        );
        await until(
          () => resolvedEvents.any((e) => e['event'] == 'packetObservation'),
        );
        expect(baseEvents.last['data'], resolvedEvents.last['data']);
        final second = live.resolvedEvents.listen((_) {});
        await first.cancel();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(configs, hasLength(1));
        await second.cancel();
        await until(() => configs.length == 2);
        expect(configs.last['resolvePath'], isFalse);
        sockets.single.add(
          jsonEncode({
            'v': 1,
            'type': 'event',
            'event': 'nodeUpdate',
            'data': {'nodeId': 'base-still-live'},
          }),
        );
        await until(() => baseEvents.any((e) => e['event'] == 'nodeUpdate'));
        expect(sockets, hasLength(1));

        final active = live.resolvedEvents.listen(resolvedEvents.add);
        await until(() => configs.length == 3);
        expect(configs.last['resolvePath'], isTrue);
        await sockets.single.close();
        await until(() => sockets.length == 2 && configs.length == 4);
        expect(configs.last['resolvePath'], isTrue);
        live.stop();
        live.start();
        live.stop();
        live.start();
        await until(() => sockets.length == 3 && configs.length == 5);
        expect(configs.last['resolvePath'], isTrue);
        expect(
          sockets.where((s) => s.readyState == WebSocket.open),
          hasLength(1),
        );
        await active.cancel();
        await until(() => configs.length == 6);
        expect(configs.last['resolvePath'], isFalse);
        final closing = Completer<void>();
        live.resolvedEvents.listen((_) {}, onDone: closing.complete);
        await until(() => configs.length == 7);
        live.dispose();
        await closing.future.timeout(const Duration(seconds: 5));
        await live.resolvedEvents.drain<void>();
        await base.cancel();
        for (final socket in sockets) {
          await socket.close();
        }
        await server.close(force: true);
        expect(configs.map((c) => c['resolvePath']), [
          true,
          false,
          true,
          true,
          true,
          false,
          true,
        ]);
        expect(configs.every((c) => c['includeRepeats'] == false), isTrue);
      }, RealHttp());
    },
  );
}
