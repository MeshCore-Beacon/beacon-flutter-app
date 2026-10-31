import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:beacon/core/api.dart';
import 'package:beacon/core/live.dart';
import 'package:beacon/core/runtime_config.dart';
import 'package:flutter_test/flutter_test.dart';

// The test binding fakes every HttpClient; the base class hands out dart:io's real one.
class _RealHttp extends HttpOverrides {}

// The analyzer's scrape block lets the app through only on a User-Agent starting "Dart/".
void main() {
  test('REST, config.js and the live socket send a Dart/ User-Agent', () {
    return HttpOverrides.runWithHttpOverrides(_checkAgents, _RealHttp());
  });
}

Future<void> _checkAgents() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final agents = <String, String?>{};
  final socketSeen = Completer<void>();
  server.listen((request) async {
    agents[request.uri.path] = request.headers.value(
      HttpHeaders.userAgentHeader,
    );
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      final socket = await WebSocketTransformer.upgrade(request);
      if (!socketSeen.isCompleted) socketSeen.complete();
      await socket.close();
      return;
    }
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'serverVersion': '0.0.0'}));
    await request.response.close();
  });
  final base = Uri.parse('http://127.0.0.1:${server.port}');
  final api = ApiClient(base);
  final live = LiveConnection(Uri.parse('ws://127.0.0.1:${server.port}/ws'), {
    'iatas': 'YOW',
  });
  try {
    await api.get('/info');
    await RuntimeConfig.load(base);
    live.start();
    await socketSeen.future.timeout(const Duration(seconds: 5));
  } finally {
    live.dispose();
    api.close();
    await server.close(force: true);
  }
  expect(agents.keys, containsAll(['/api/v1/info', '/config.js', '/ws']));
  for (final entry in agents.entries) {
    expect(entry.value, startsWith('Dart/'), reason: entry.key);
  }
}
