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
      transientRetries: 0,
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
      transientRetries: 0,
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
        transientRetries: 0,
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

  test(
    'a 503 Retry-After waits at most 30 s; a 429 keeps its 300 s cap',
    () async {
      final slow = busy([], 503, {'retry-after': '120'});
      await expectLater(
        slow.get('/packets'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.retryAfter,
            'retryAfter',
            const Duration(seconds: 30),
          ),
        ),
      );
      final limited = busy([], 429, {'retry-after': '120'});
      await expectLater(
        limited.get('/packets'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.retryAfter,
            'retryAfter',
            const Duration(seconds: 120),
          ),
        ),
      );
      slow.close();
      limited.close();
    },
  );

  group('withPageCursorFallback', () {
    const invalid = ApiException('invalid pageCursor', status: 400);
    test(
      'retries once with cursor alone after an invalid pageCursor',
      () async {
        final sent = <Map<String, dynamic>>[];
        final result = await withPageCursorFallback(
          {'limit': 50, 'cursor': 5, 'pageCursor': 'v1:x'},
          (p) async {
            sent.add(p);
            if (sent.length == 1) throw invalid;
            return 'page';
          },
        );
        expect(result, 'page');
        expect(sent, [
          {'limit': 50, 'cursor': 5, 'pageCursor': 'v1:x'},
          {'limit': 50, 'cursor': 5},
        ]);
      },
    );
    test('shows the error when the legacy request also fails', () async {
      const other = ApiException('boom', status: 500);
      var n = 0;
      await expectLater(
        withPageCursorFallback<String>({'cursor': 5, 'pageCursor': 'v1:x'}, (
          p,
        ) async {
          n++;
          throw n == 1 ? invalid : other;
        }),
        throwsA(same(other)),
      );
      expect(n, 2);
    });
    test(
      'leaves other errors, and pageCursor without a cursor, alone',
      () async {
        for (final (params, error) in [
          (
            <String, dynamic>{'cursor': 5, 'pageCursor': 'v1:x'},
            const ApiException('invalid cursor', status: 400),
          ),
          (<String, dynamic>{'pageCursor': 'v1:x'}, invalid),
          (<String, dynamic>{'cursor': 5}, invalid),
        ]) {
          var n = 0;
          await expectLater(
            withPageCursorFallback<String>(params, (p) async {
              n++;
              throw error;
            }),
            throwsA(same(error)),
          );
          expect(n, 1);
        }
      },
    );
  });

  test(
    'an unparsable Retry-After makes a 503 final but a 429 waits 10 s',
    () async {
      final unavailable = busy([], 503, {'retry-after': 'soon'});
      await expectLater(
        unavailable.get('/packets'),
        throwsA(
          isA<ApiException>().having((e) => e.retryAfter, 'retryAfter', isNull),
        ),
      );
      final limited = busy([], 429, {'retry-after': 'soon'});
      await expectLater(
        limited.get('/packets'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.retryAfter,
            'retryAfter',
            const Duration(seconds: 10),
          ),
        ),
      );
      unavailable.close();
      limited.close();
    },
  );
  test(
    'withPageCursorFallback skips the legacy request once superseded',
    () async {
      var n = 0;
      final result = await withPageCursorFallback<String>(
        {'cursor': 5, 'pageCursor': 'v1:x'},
        (p) async {
          n++;
          throw const ApiException('invalid pageCursor', status: 400);
        },
        isCurrent: () => false,
      );
      expect(result, isNull);
      expect(n, 1);
    },
  );

  group('ApiClient waits out a busy server', () {
    ApiClient scripted(
      List<http.Response> answers,
      List<Duration> waits, {
      int retries = 3,
      List<Uri>? seen,
    }) {
      var clock = DateTime(2026);
      return ApiClient(
        Uri.parse('https://test'),
        now: () => clock,
        wait: (d) async {
          waits.add(d);
          clock = clock.add(d);
        },
        transientRetries: retries,
        client: MockClient((r) async {
          seen?.add(r.url);
          return answers.removeAt(0);
        }),
      );
    }

    http.Response busy(int status, [String? after]) => http.Response(
      '{"error":{"message":"busy"}}',
      status,
      headers: {'retry-after': ?after},
    );
    http.Response ok() => http.Response('{"items":[]}', 200);

    test('a 503 with Retry-After is retried after the wait', () async {
      final waits = <Duration>[];
      final api = scripted([busy(503, '10'), ok()], waits);
      expect(await api.get('/packets'), {'items': []});
      expect(waits, [const Duration(seconds: 10)]);
    });
    test('a 429 waits out the cooldown it set, then retries', () async {
      final waits = <Duration>[];
      final seen = <Uri>[];
      final api = scripted([busy(429, '1'), ok()], waits, seen: seen);
      expect(await api.get('/packets', {'limit': 5}), {'items': []});
      expect(waits, [const Duration(seconds: 1)]);
      expect(seen, hasLength(2));
    });
    test('reference reads retry too', () async {
      final waits = <Duration>[];
      final api = scripted([busy(503, '30'), ok()], waits);
      expect(await api.getCached('/iatas'), {'items': []});
      expect(waits, [const Duration(seconds: 30)]);
    });
    test('gives up after three retries', () async {
      final waits = <Duration>[];
      final api = scripted(List.generate(4, (_) => busy(503, '10')), waits);
      await expectLater(
        api.get('/packets'),
        throwsA(isA<ApiException>().having((e) => e.status, 'status', 503)),
      );
      expect(waits, hasLength(3));
    });
    test('a 503 without Retry-After and other errors are final', () async {
      for (final answer in [busy(503), busy(404), busy(500)]) {
        final waits = <Duration>[];
        final api = scripted([answer], waits);
        await expectLater(api.get('/packets'), throwsA(isA<ApiException>()));
        expect(waits, isEmpty);
      }
    });
    test('stops without another request once superseded', () async {
      final waits = <Duration>[];
      final seen = <Uri>[];
      var current = true;
      final api = scripted([busy(503, '10'), ok()], waits, seen: seen);
      final result = api.get('/packets', const {}, () => current);
      current = false;
      expect(await result, isNull);
      expect(seen, hasLength(1));
    });
    test('transientRetries 0 throws the first busy answer', () async {
      final waits = <Duration>[];
      final api = scripted([busy(503, '10')], waits, retries: 0);
      await expectLater(api.get('/info'), throwsA(isA<ApiException>()));
      expect(waits, isEmpty);
    });
  });
}
