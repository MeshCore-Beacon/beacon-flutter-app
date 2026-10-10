import 'dart:convert';

import 'package:beacon/core/api.dart';
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
  test('stops paging after the page cap', () async {
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
            'nextCursor': 'c$requests',
          }),
          200,
        );
      }),
    );
    // take() bounds the test if the cap is missing.
    final pages = await loadMapNodes(api, {}).take(300).toList();
    expect(requests, 250);
    expect(pages.last.length, 250);
    api.close();
  });
}
