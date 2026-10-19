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
}
