import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('encodes query values and preserves base prefixes', () async {
    final api = ApiClient(
      Uri.parse('https://host/beacon'),
      client: MockClient((request) async {
        expect(request.url.path, '/beacon/api/v1/packets');
        expect(request.url.queryParameters['scope'], '#bc');
        expect(request.url.queryParameters.containsKey('cursor'), false);
        return http.Response(jsonEncode({'items': [], 'hasMore': false}), 200);
      }),
    );
    expect(await api.get('/packets', {'scope': '#bc', 'cursor': null}), {
      'items': [],
      'hasMore': false,
    });
  });
  test('empty borders are null and HTTP errors carry status', () async {
    final api = ApiClient(
      Uri.parse('https://host'),
      client: MockClient((r) async => http.Response('', 204)),
    );
    expect(await api.get('/iatas/YOW/border'), null);
    final broken = ApiClient(
      Uri.parse('https://host'),
      client: MockClient(
        (r) async =>
            http.Response('{"error":{"message":"packet not found"}}', 404),
      ),
    );
    expect(
      broken.get('/packets/absent'),
      throwsA(isA<ApiException>().having((e) => e.status, 'status', 404)),
    );
  });

  test('rate limit prevents retry storm and carries retry delay', () async {
    var calls = 0;
    final api = ApiClient(
      Uri.parse('https://test'),
      client: MockClient((r) async {
        calls++;
        return http.Response(
          '{"error":{"message":"Rate limited"}}',
          429,
          headers: {'retry-after': '60'},
        );
      }),
    );
    await expectLater(
      api.get('/packets'),
      throwsA(
        isA<ApiException>().having(
          (e) => e.retryAfter,
          'retry',
          const Duration(seconds: 60),
        ),
      ),
    );
    await expectLater(
      api.get('/packets'),
      throwsA(isA<ApiException>().having((e) => e.status, 'status', 429)),
    );
    expect(calls, 1);
  });
  test('oversized bodies are rejected while streaming', () async {
    var sent = 0;
    final api = ApiClient(
      Uri.parse('https://host'),
      maxResponseBytes: 1024,
      client: MockClient.streaming((request, _) async {
        Stream<List<int>> chunks() async* {
          yield utf8.encode('[');
          for (var i = 0; i < 100; i++) {
            sent++;
            yield List.filled(100, 0x20);
          }
          yield utf8.encode(']');
        }

        return http.StreamedResponse(chunks(), 200);
      }),
    );
    await expectLater(
      api.get('/packets'),
      throwsA(
        isA<ApiException>().having(
          (e) => e.message,
          'message',
          contains('too large'),
        ),
      ),
    );
    expect(sent, lessThan(100));
    api.close();
  });
  test('declared oversized content length is rejected up front', () async {
    final api = ApiClient(
      Uri.parse('https://host'),
      maxResponseBytes: 1024,
      client: MockClient.streaming(
        (request, _) async => http.StreamedResponse(
          Stream.value(utf8.encode('[]')),
          200,
          contentLength: 4096,
        ),
      ),
    );
    await expectLater(api.get('/packets'), throwsA(isA<ApiException>()));
    api.close();
  });
  test('bodies under the limit keep status and headers', () async {
    final api = ApiClient(
      Uri.parse('https://host'),
      maxResponseBytes: 1024,
      client: MockClient(
        (request) async => http.Response(
          '{"error":{"message":"slow down"}}',
          429,
          headers: {'retry-after': '7'},
        ),
      ),
    );
    await expectLater(
      api.get('/packets'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.status, 'status', 429)
            .having((e) => e.message, 'message', 'slow down')
            .having(
              (e) => e.retryAfter,
              'retryAfter',
              const Duration(seconds: 7),
            ),
      ),
    );
    api.close();
  });

  group('nextPageParams', () {
    test('sends both cursors when the server returns both', () {
      expect(
        nextPageParams({
          'items': [],
          'hasMore': true,
          'nextCursor': 5,
          'nextPageCursor': 'v1:5000:ab',
        }),
        {'cursor': 5, 'pageCursor': 'v1:5000:ab'},
      );
    });
    test(
      'sends cursor alone for an older server or an unusable pageCursor',
      () {
        expect(nextPageParams({'hasMore': true, 'nextCursor': 5}), {
          'cursor': 5,
        });
        expect(
          nextPageParams({
            'hasMore': true,
            'nextCursor': 5,
            'nextPageCursor': '',
          }),
          {'cursor': 5},
        );
        expect(
          nextPageParams({
            'hasMore': true,
            'nextCursor': 5,
            'nextPageCursor': 7,
          }),
          {'cursor': 5},
        );
      },
    );
    test('sends pageCursor alone when it is the only cursor', () {
      expect(nextPageParams({'hasMore': true, 'nextPageCursor': 'v1:1:ab'}), {
        'pageCursor': 'v1:1:ab',
      });
    });
    test('is empty unless hasMore is true, or when no cursor is present', () {
      expect(
        nextPageParams({
          'hasMore': false,
          'nextCursor': 5,
          'nextPageCursor': 'x',
        }),
        isEmpty,
      );
      expect(nextPageParams({'nextCursor': 5}), isEmpty);
      expect(nextPageParams({'hasMore': true}), isEmpty);
    });
  });

  ApiClient busy(List<int> calls, int status, Map<String, String> headers) =>
      ApiClient(
        Uri.parse('https://test'),
        client: MockClient((r) async {
          calls.add(status);
          return http.Response(
            '{"error":{"code":"deadline_exceeded","message":"The request ran past its database time limit. Retry later."}}',
            status,
            headers: headers,
          );
        }),
      );

  test('a 503 with Retry-After carries the delay and does not block later requests', () async {
    final calls = <int>[];
    final api = busy(calls, 503, {'retry-after': '5'});
    await expectLater(
      api.get('/packets'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.status, 'status', 503)
            .having(
              (e) => e.retryAfter,
              'retryAfter',
              const Duration(seconds: 5),
            )
            .having(
              (e) => e.message,
              'message',
              'The request ran past its database time limit. Retry later.',
            ),
      ),
    );
    await expectLater(
      api.get('/packets'),
      throwsA(isA<ApiException>().having((e) => e.status, 'status', 503)),
    );
    expect(calls, [
      503,
      503,
    ]); // a 429 would have answered the second call locally
    api.close();
  });
  test(
    'a 503 without Retry-After has no delay; Retry-After 0 clamps to 1 s',
    () async {
      final api = busy([], 503, {});
      await expectLater(
        api.get('/packets'),
        throwsA(
          isA<ApiException>().having((e) => e.retryAfter, 'retryAfter', isNull),
        ),
      );
      final zero = busy([], 503, {'retry-after': '0'});
      await expectLater(
        zero.get('/packets'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.retryAfter,
            'retryAfter',
            const Duration(seconds: 1),
          ),
        ),
      );
      api.close();
      zero.close();
    },
  );

  group('retryTransient', () {
    const deadline = ApiException(
      'busy',
      status: 503,
      retryAfter: Duration(seconds: 5),
    );
    test('waits Retry-After and returns the retried result', () async {
      final waits = <Duration>[];
      var n = 0;
      final result = await retryTransient(
        () async => n++ == 0 ? throw deadline : 'page',
        wait: (d) async => waits.add(d),
      );
      expect(result, 'page');
      expect(waits, [const Duration(seconds: 5)]);
    });
    test('gives up after three retries', () async {
      var n = 0;
      await expectLater(
        retryTransient<String>(() async {
          n++;
          throw deadline;
        }, wait: (_) async {}),
        throwsA(same(deadline)),
      );
      expect(n, 4);
    });
    test('does not retry a 500 or a 503 without Retry-After', () async {
      for (final e in const [
        ApiException('x', status: 500),
        ApiException('x', status: 503),
      ]) {
        var n = 0;
        await expectLater(
          retryTransient<String>(() async {
            n++;
            throw e;
          }, wait: (_) async {}),
          throwsA(same(e)),
        );
        expect(n, 1);
      }
    });
    test(
      'stops without another request once superseded during the wait',
      () async {
        var n = 0;
        var current = true;
        final result = await retryTransient<String>(
          () async {
            n++;
            throw deadline;
          },
          isCurrent: () => current,
          wait: (_) async => current = false,
        );
        expect(result, isNull);
        expect(n, 1);
      },
    );
    test('isTransient', () {
      expect(isTransient(const ApiException('x', status: 429)), true);
      expect(isTransient(deadline), true);
      expect(isTransient(const ApiException('x', status: 503)), false);
      expect(isTransient(StateError('x')), false);
    });
  });
}
