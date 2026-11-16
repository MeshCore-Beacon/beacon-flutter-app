import 'dart:async';
import 'dart:io';

import 'package:beacon/core/api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

void main() {
  test('a superseded screen does not start another read', () async {
    var reads = 0;
    expect(
      await retryTransient(() async => ++reads, isCurrent: () => false),
      isNull,
    );
    expect(reads, 0);
  });

  test(
    'a body timeout cancels its real connection and preserves the shared client',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = IOClient();
      final stalled = Completer<HttpResponse>();
      final closed = Completer<void>();
      server.listen((request) async {
        if (request.uri.path == '/stall') {
          request.response.write('[');
          await request.response.flush();
          stalled.complete(request.response);
          unawaited(
            request.response.done
                .then((_) {
                  if (!closed.isCompleted) closed.complete();
                })
                .catchError((Object _) {
                  if (!closed.isCompleted) closed.complete();
                }),
          );
        } else {
          request.response.write('{}');
          await request.response.close();
        }
      });
      addTearDown(() async {
        client.close();
        await server.close(force: true);
      });
      final base = Uri.parse('http://127.0.0.1:${server.port}');
      final read = getLimited(
        client,
        base.resolve('/stall'),
        1024,
        timeout: const Duration(milliseconds: 200),
      );
      await expectLater(read, throwsA(isA<TimeoutException>()));
      expect((await getLimited(client, base.resolve('/ok'), 1024)).body, '{}');
      // Writing after the peer cancellation makes the server observe the close.
      final response = await stalled.future;
      response.write(']');
      try {
        await response.close();
      } catch (_) {}
      await closed.future.timeout(const Duration(seconds: 2));
    }, _RealNetwork()),
  );

  test(
    'an oversized streamed response cancels before consuming the whole body',
    () async {
      var cancelled = false;
      final stream = StreamController<List<int>>(
        onCancel: () {
          cancelled = true;
        },
      );
      final client = _StreamClient(stream.stream);
      final result = getLimited(client, Uri.parse('https://example.test'), 4);
      stream.add([1, 2, 3, 4, 5]);
      await expectLater(result, throwsA(isA<ApiException>()));
      expect(cancelled, isTrue);
      await stream.close();
    },
  );
}

class _StreamClient extends http.BaseClient {
  _StreamClient(this.stream);
  final Stream<List<int>> stream;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(stream, 200);
}

// The suite's widget binding otherwise replaces HttpClient with a fake 400.
class _RealNetwork extends HttpOverrides {}
