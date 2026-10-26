import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/core/page_pacer.dart';
import 'package:beacon/features/map/map_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('map uses server-supported 200-node batches', () async {
    final api = ApiClient(
      Uri.parse('https://example.org'),
      client: MockClient((r) async {
        expect(r.url.queryParameters['limit'], '200');
        return http.Response('{"items":[],"hasMore":false}', 200);
      }),
    );
    await loadMapNodes(api, {}).drain<void>();
    api.close();
  });
  test(
    'rate limit preserves loaded nodes and retries the same cursor',
    () async {
      final requests = <String?>[];
      final api = ApiClient(
        Uri.parse('https://example.org'),
        client: MockClient((r) async {
          requests.add(r.url.queryParameters['cursor']);
          if (requests.length == 1) {
            return http.Response(
              '{"items":[{"id":"a"}],"hasMore":true,"nextCursor":"a"}',
              200,
            );
          }
          if (requests.length == 2) {
            return http.Response(
              '{"error":{"message":"Rate limited"}}',
              429,
              headers: {'retry-after': '1'},
            );
          }
          return http.Response('{"items":[{"id":"b"}],"hasMore":false}', 200);
        }),
      );
      final pages = await loadMapNodes(api, {}).toList();
      expect(requests, [null, 'a', 'a']);
      expect(pages.first.single['id'], 'a');
      expect(pages.last.map((n) => n['id']), ['a', 'b']);
      api.close();
    },
  );
  test('loads every cursor page and merges duplicated node ids', () async {
    final api = ApiClient(
      Uri.parse('https://example.org/api'),
      client: MockClient(
        (request) async => http.Response(
          jsonEncode(
            request.url.queryParameters['cursor'] == null
                ? {
                    'items': [
                      {'id': 'a'},
                      {'id': 'b'},
                    ],
                    'hasMore': true,
                    'nextCursor': 'tie-b',
                  }
                : {
                    'items': [
                      {'id': 'b', 'name': 'updated'},
                      {'id': 'c'},
                    ],
                    'hasMore': false,
                  },
          ),
          200,
        ),
      ),
    );
    final pages = await loadMapNodes(api, {}).toList();
    expect(pages.last.map((n) => n['id']), ['a', 'b', 'c']);
    expect(pages.last[1]['name'], 'updated');
    api.close();
  });
  test('superseded map load stops before requesting another page', () async {
    var current = true;
    var calls = 0;
    final api = ApiClient(
      Uri.parse('https://example.org'),
      client: MockClient((r) async {
        calls++;
        return http.Response(
          '{"items":[{"id":"a"}],"hasMore":true,"nextCursor":"a"}',
          200,
        );
      }),
    );
    await for (final _ in loadMapNodes(api, {}, isCurrent: () => current)) {
      current = false;
    }
    expect(calls, 1);
    api.close();
  });
  test('explicit empty selection sends no request', () async {
    final api = ApiClient(
      Uri.parse('https://example.org/api'),
      client: MockClient((_) async => throw StateError('Unexpected request')),
    );
    expect(await loadMapNodes(api, {'iatas': <String>[]}).toList(), [isEmpty]);
    api.close();
  });
  test(
    'repeated cursor raises an error instead of silently omitting pages',
    () async {
      final api = ApiClient(
        Uri.parse('https://example.org/api'),
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'items': [
                {'id': 'a'},
              ],
              'hasMore': true,
              'nextCursor': 'same',
            }),
            200,
          ),
        ),
      );
      await expectLater(loadMapNodes(api, {}).drain<void>(), throwsStateError);
      api.close();
    },
  );
  // No pacing delay, so the long paging tests stay fast.
  PagePacer unpaced() => PagePacer(interval: Duration.zero);
  test('loads every node of a mesh far past 50,000 nodes', () async {
    var requests = 0;
    final api = ApiClient(
      Uri.parse('https://example.org'),
      client: MockClient((r) async {
        final n = ++requests;
        return http.Response(
          jsonEncode({
            'items': [
              for (var i = 0; i < 200; i++) {'id': 'n$n-$i'},
            ],
            'hasMore': n < 400,
            'nextCursor': 'c$n',
          }),
          200,
        );
      }),
    );
    final pages = await loadMapNodes(api, {}, pacer: unpaced()).toList();
    expect(requests, 400);
    expect(pages.last, hasLength(80000));
    api.close();
  });
  test(
    'a server looping back to an old cursor errors past 250 pages',
    () async {
      var requests = 0;
      final api = ApiClient(
        Uri.parse('https://example.org'),
        client: MockClient((r) async {
          requests++;
          return http.Response(
            jsonEncode({
              'items': [
                {'id': 'n$requests'},
              ],
              'hasMore': true,
              'nextCursor': 'c${requests % 300}',
            }),
            200,
          );
        }),
      );
      await expectLater(
        loadMapNodes(api, {}, pacer: unpaced()).drain<void>(),
        throwsStateError,
      );
      expect(requests, 301);
      api.close();
    },
  );
  test('a server that never stops paging errors at the bound', () async {
    var requests = 0;
    final api = ApiClient(
      Uri.parse('https://example.org'),
      client: MockClient((r) async {
        requests++;
        return http.Response(
          jsonEncode({
            'items': [
              {'id': 'n$requests'},
            ],
            // ends just past the bound, so a missing bound fails instead of hanging
            'hasMore': requests <= mapNodePageCap,
            'nextCursor': 'c$requests',
          }),
          200,
        );
      }),
    );
    final pages = <List<Map<String, dynamic>>>[];
    await expectLater(
      loadMapNodes(api, {}, pacer: unpaced()).forEach(pages.add),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('incomplete'),
        ),
      ),
    );
    expect(requests, mapNodePageCap);
    // the screen keeps every node that did arrive
    expect(pages.last, hasLength(mapNodePageCap));
    api.close();
  });

  const pc = 'v1:5000:00000000-0000-0000-0000-00000000000a';
  test('sends both cursors when the server returns both', () async {
    final seen = <Map<String, String>>[];
    final api = ApiClient(
      Uri.parse('https://example.org'),
      client: MockClient((r) async {
        seen.add(r.url.queryParameters);
        return http.Response(
          jsonEncode(
            seen.length == 1
                ? {
                    'items': [
                      {'id': 'a'},
                    ],
                    'hasMore': true,
                    'nextCursor': 5,
                    'nextPageCursor': pc,
                  }
                : {
                    'items': [
                      {'id': 'b'},
                    ],
                    'hasMore': false,
                  },
          ),
          200,
        );
      }),
    );
    await loadMapNodes(api, {'iatas': 'AAA'}).drain<void>();
    expect(seen[1]['cursor'], '5');
    expect(seen[1]['pageCursor'], pc);
    expect(seen[1]['iatas'], 'AAA');
    api.close();
  });
  test('pages by cursor alone on a server without nextPageCursor', () async {
    final seen = <Map<String, String>>[];
    final api = ApiClient(
      Uri.parse('https://example.org'),
      client: MockClient((r) async {
        seen.add(r.url.queryParameters);
        return http.Response(
          jsonEncode(
            seen.length == 1
                ? {
                    'items': [
                      {'id': 'a'},
                    ],
                    'hasMore': true,
                    'nextCursor': 5,
                  }
                : {
                    'items': [
                      {'id': 'b'},
                    ],
                    'hasMore': false,
                  },
          ),
          200,
        );
      }),
    );
    await loadMapNodes(api, {}).drain<void>();
    expect(seen[1].containsKey('pageCursor'), false);
    expect(seen[1]['cursor'], '5');
    api.close();
  });
  test('pages forward when the server ignores pageCursor', () async {
    // answers by cursor only, as a rolled-back server does
    final api = ApiClient(
      Uri.parse('https://example.org'),
      client: MockClient(
        (r) async => http.Response(
          jsonEncode(
            r.url.queryParameters['cursor'] == null
                ? {
                    'items': [
                      {'id': 'a'},
                      {'id': 'b'},
                    ],
                    'hasMore': true,
                    'nextCursor': 5,
                    'nextPageCursor': pc,
                  }
                : {
                    'items': [
                      {'id': 'b'},
                      {'id': 'c'},
                    ],
                    'hasMore': false,
                  },
          ),
          200,
        ),
      ),
    );
    final pages = await loadMapNodes(api, {}).toList();
    expect(pages.last.map((n) => n['id']), ['a', 'b', 'c']);
    api.close();
  });
  test('a busy 503 keeps loaded nodes and retries the same cursors', () async {
    final seen = <Map<String, String>>[];
    final api = ApiClient(
      Uri.parse('https://example.org'),
      client: MockClient((r) async {
        seen.add(r.url.queryParameters);
        return switch (seen.length) {
          1 => http.Response(
            jsonEncode({
              'items': [
                {'id': 'a'},
              ],
              'hasMore': true,
              'nextCursor': 5,
              'nextPageCursor': pc,
            }),
            200,
          ),
          2 => http.Response(
            '{"error":{"code":"deadline_exceeded","message":"busy"}}',
            503,
            headers: {'retry-after': '1'},
          ),
          _ => http.Response('{"items":[{"id":"b"}],"hasMore":false}', 200),
        };
      }),
    );
    final pages = await loadMapNodes(api, {}).toList();
    expect(seen.length, 3);
    expect(seen[2], seen[1]);
    expect(pages.last.map((n) => n['id']), ['a', 'b']);
    api.close();
  });

  test('an invalid pageCursor falls back to cursor alone', () async {
    final seen = <Map<String, String>>[];
    final api = ApiClient(
      Uri.parse('https://example.org'),
      client: MockClient((r) async {
        seen.add(r.url.queryParameters);
        return switch (seen.length) {
          1 => http.Response(
            jsonEncode({
              'items': [
                {'id': 'a'},
              ],
              'hasMore': true,
              'nextCursor': 5,
              'nextPageCursor': pc,
            }),
            200,
          ),
          2 => http.Response(
            '{"error":{"code":"bad_request","message":"invalid pageCursor"}}',
            400,
          ),
          _ => http.Response('{"items":[{"id":"b"}],"hasMore":false}', 200),
        };
      }),
    );
    final pages = await loadMapNodes(api, {}).toList();
    expect(seen.length, 3);
    expect(seen[1]['pageCursor'], pc);
    expect(seen[2].containsKey('pageCursor'), false);
    expect(seen[2]['cursor'], '5');
    expect(pages.last.map((n) => n['id']), ['a', 'b']);
    api.close();
  });
  testWidgets(
    'pages past a region-sized burst wait for the shared page budget',
    (tester) async {
      final start = tester.binding.clock.now();
      final sentAt = <Duration>[];
      final api = ApiClient(
        Uri.parse('https://example.org'),
        client: MockClient((r) async {
          sentAt.add(tester.binding.clock.now().difference(start));
          final n = sentAt.length;
          return http.Response(
            jsonEncode({
              'items': [
                {'id': '$n'},
              ],
              'hasMore': n < 45,
              'nextCursor': '$n',
            }),
            200,
          );
        }),
      );
      final done = loadMapNodes(
        api,
        {},
        pacer: PagePacer(now: tester.binding.clock.now),
      ).drain<void>();
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await done;
      expect(sentAt, hasLength(45));
      expect(sentAt.take(41), everyElement(Duration.zero));
      expect(sentAt.skip(41), [
        const Duration(milliseconds: 300),
        const Duration(milliseconds: 600),
        const Duration(milliseconds: 900),
        const Duration(milliseconds: 1200),
      ]);
      api.close();
    },
  );
}
