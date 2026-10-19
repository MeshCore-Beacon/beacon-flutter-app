import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/features/analytics/neighbour_graph.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
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
    final nodes = await loadNeighbourNodes(api, {'iatas': 'AAA'});
    expect(nodes!.map((n) => n['id']), ['a', 'b']);
    expect(seen[1]['cursor'], '5');
    expect(seen[1]['pageCursor'], pc);
    expect(seen[1]['iatas'], 'AAA');
    expect(seen[1]['neighbors'], 'true');
    expect(seen[1]['limit'], '500');
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
    final nodes = await loadNeighbourNodes(api, {});
    expect(nodes!.map((n) => n['id']), ['a', 'b']);
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
    final nodes = await loadNeighbourNodes(api, {});
    expect(nodes!.map((n) => n['id']), ['a', 'b', 'c']);
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
    final nodes = await loadNeighbourNodes(api, {});
    expect(seen.length, 3);
    expect(seen[2], seen[1]);
    expect(nodes!.map((n) => n['id']), ['a', 'b']);
    api.close();
  });
  test('stops after one request when hasMore comes without a cursor', () async {
    var calls = 0;
    final api = ApiClient(
      Uri.parse('https://example.org'),
      client: MockClient((r) async {
        calls++;
        return http.Response(
          jsonEncode({
            'items': [
              {'id': 'a'},
            ],
            'hasMore': true,
          }),
          200,
        );
      }),
    );
    final nodes = await loadNeighbourNodes(api, {});
    expect(nodes!.map((n) => n['id']), ['a']);
    expect(calls, 1);
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
    final nodes = await loadNeighbourNodes(api, {});
    expect(seen.length, 3);
    expect(seen[2].containsKey('pageCursor'), false);
    expect(seen[2]['cursor'], '5');
    expect(nodes!.map((n) => n['id']), ['a', 'b']);
    api.close();
  });
}
