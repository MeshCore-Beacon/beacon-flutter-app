import 'dart:async';
import 'dart:io';

import 'package:beacon/core/live.dart';
import 'package:flutter_test/flutter_test.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  for (final stop in [true, false]) {
    test(
      stop
          ? 'stopping closes the pending WebSocket handshake'
          : 'timing out closes the pending WebSocket handshake',
      () => HttpOverrides.runWithHttpOverrides(() async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final received = Completer<void>();
        final closed = Completer<void>();
        final sockets = <Socket>[];
        server.listen((socket) {
          sockets.add(socket);
          socket.listen(
            (_) {
              if (!received.isCompleted) received.complete();
              // Deliberately leave the HTTP upgrade unanswered.
            },
            onDone: () {
              if (!closed.isCompleted) closed.complete();
            },
            onError: (Object _) {
              if (!closed.isCompleted) closed.complete();
            },
          );
        });
        final live = LiveConnection(
          Uri.parse('ws://127.0.0.1:${server.port}/ws'),
          {'iatas': 'YOW'},
        );
        try {
          live.start();
          await received.future.timeout(const Duration(seconds: 5));
          if (stop) live.stop();
          await closed.future.timeout(Duration(seconds: stop ? 2 : 24));
          if (stop) expect(live.status, 'offline');
        } finally {
          live.dispose();
          for (final socket in sockets) {
            socket.destroy();
          }
          await server.close();
        }
      }, _RealHttp()),
      timeout: const Timeout(Duration(seconds: 35)),
    );
  }
}
