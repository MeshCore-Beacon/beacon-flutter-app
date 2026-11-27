import 'dart:async';
import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('no-store responses are never retained', () async {
    var calls = 0;
    final api = ApiClient(
      Uri.parse('https://host'),
      client: MockClient((r) async {
        calls++;
        return http.Response('{}', 200, headers: {'cache-control': 'no-store'});
      }),
    );
    await api.getCached('/nodes');
    await api.getCached('/nodes');
    expect(calls, 2);
    expect(api.peekCache('/nodes'), isNull);
    api.close();
  });
  test(
    'cache evicts oldest entries rather than growing without bound',
    () async {
      var calls = 0;
      final api = ApiClient(
        Uri.parse('https://host'),
        client: MockClient((r) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      for (var i = 0; i < 260; i++) {
        await api.getCached('/nodes/$i');
      }
      expect(api.peekCache('/nodes/0'), isNull);
      expect(api.peekCache('/nodes/259'), isNotNull);
      await api.getCached('/nodes/259');
      expect(calls, 260);
      api.close();
    },
  );
  test(
    'fresh cache reuses canonical queries, isolates filters and expires',
    () async {
      var now = DateTime(2026);
      var calls = 0;
      final api = ApiClient(
        Uri.parse('https://host/beacon'),
        now: () => now,
        client: MockClient(
          (r) async => http.Response(jsonEncode({'call': ++calls}), 200),
        ),
      );
      await api.getCached('/nodes', {'iata': 'YOW', 'limit': 50});
      expect(await api.getCached('/nodes', {'limit': 50, 'iata': 'YOW'}), {
        'call': 1,
      });
      await api.getCached('/nodes', {'iata': 'YYZ', 'limit': 50});
      expect(calls, 2);
      now = now.add(const Duration(seconds: 31));
      expect(api.peekCache('/nodes', {'iata': 'YOW', 'limit': 50}), {
        'call': 1,
      });
      await api.getCached('/nodes', {'iata': 'YOW', 'limit': 50});
      expect(calls, 3);
      api.close();
    },
  );
  test(
    'concurrent reads share one request and return independent snapshots',
    () async {
      var calls = 0;
      final response = Completer<http.Response>();
      final api = ApiClient(
        Uri.parse('https://host'),
        client: MockClient((r) {
          calls++;
          return response.future;
        }),
      );
      final a = api.getCached('/nodes');
      final b = api.getCached('/nodes');
      response.complete(http.Response('{"items":[{"id":"a"}]}', 200));
      final results = await Future.wait([a, b]);
      expect(calls, 1);
      results.first['items'].clear();
      expect(results.last['items'], hasLength(1));
      expect((await api.getCached('/nodes'))['items'], hasLength(1));
      api.close();
    },
  );
  test('manual fresh read replaces cache and invalidated in-flight data is not cached', () async {
    var calls = 0;
    final pending = Completer<http.Response>();
    final api = ApiClient(
      Uri.parse('https://host'),
      client: MockClient((r) async {
        calls++;
        if (calls == 3) return pending.future;
        return http.Response('{"value":$calls}', 200);
      }),
    );
    await api.getCached('/nodes');
    expect(await api.get('/nodes'), {'value': 2});
    expect(await api.getCached('/nodes'), {'value': 2});
    api.invalidateCache(prefix: '/nodes');
    final old = api.getCached('/nodes');
    api.invalidateCache(prefix: '/nodes');
    pending.complete(http.Response('{"value":3}', 200));
    await old;
    expect(api.peekCache('/nodes'), isNull);
    expect(await api.getCached('/nodes'), {'value': 4});
    api.close();
  });
  test(
    'reference data survives reconnect while changing data is invalidated',
    () async {
      var calls = 0;
      final api = ApiClient(
        Uri.parse('https://host/base'),
        client: MockClient((r) async {
          calls++;
          return http.Response('[]', 200);
        }),
      );
      await api.get('/scopes');
      await api.getCached('/nodes');
      api.handleLiveEvent({'type': 'refresh'});
      await api.get('/scopes');
      await api.getCached('/nodes');
      expect(calls, 3);
      api.close();
    },
  );
  test(
    'live node patch preserves omitted fields and explicit null coordinates',
    () async {
      var calls = 0;
      final api = ApiClient(
        Uri.parse('https://host'),
        client: MockClient((r) async {
          calls++;
          return http.Response(
            '{"items":[{"id":"a","name":"old","lat":45,"lng":-75,"neighborIds":["b"]}],"hasMore":false}',
            200,
          );
        }),
      );
      await api.getCached('/nodes', {'neighbors': true});
      api.handleLiveEvent({
        'event': 'nodeUpdate',
        'data': {'nodeId': 'a', 'name': 'new', 'lat': null},
      });
      final item = (await api.getCached('/nodes', {
        'neighbors': true,
      }))['items'][0];
      expect(item['name'], 'new');
      expect(item['lat'], isNull);
      expect(item['lng'], -75);
      expect(item['neighborIds'], ['b']);
      expect(calls, 1);
      api.close();
    },
  );
  test('errors are not cached and servers never share entries', () async {
    var calls = 0;
    final api = ApiClient(
      Uri.parse('https://a'),
      client: MockClient((r) async {
        calls++;
        return http.Response(
          calls == 1 ? '{}' : '{"server":"a"}',
          calls == 1 ? 500 : 200,
        );
      }),
    );
    await expectLater(api.getCached('/nodes'), throwsA(isA<ApiException>()));
    expect(await api.getCached('/nodes'), {'server': 'a'});
    final other = ApiClient(
      Uri.parse('https://b'),
      client: MockClient((r) async => http.Response('{"server":"b"}', 200)),
    );
    expect(await other.getCached('/nodes'), {'server': 'b'});
    api.close();
    expect(api.peekCache('/nodes'), isNull);
    await expectLater(api.getCached('/nodes'), throwsA(isA<ApiException>()));
    other.close();
  });

  test('live node patch keeps pages fetched with pageCursor', () async {
    var calls = 0;
    final api = ApiClient(
      Uri.parse('https://host'),
      client: MockClient((r) async {
        calls++;
        return http.Response(
          '{"items":[{"id":"a","name":"old"}],"hasMore":false}',
          200,
        );
      }),
    );
    final params = {
      'neighbors': true,
      'limit': 200,
      'cursor': 5,
      'pageCursor': 'v1:5000:00000000-0000-0000-0000-00000000000a',
    };
    await api.getCached('/nodes', params);
    api.handleLiveEvent({
      'event': 'nodeUpdate',
      'data': {'nodeId': 'a', 'name': 'new'},
    });
    expect((await api.getCached('/nodes', params))['items'][0]['name'], 'new');
    expect(calls, 1);
    api.close();
  });
  for (final warmFilter in [false, true]) {
    test(
      'live changes retire filtered reads (cached snapshot: $warmFilter)',
      () async {
        var calls = 0;
        final obsoleteCall = warmFilter ? 3 : 2;
        final oldReply = Completer<http.Response>();
        final api = ApiClient(
          Uri.parse('https://host'),
          client: MockClient((r) async {
            calls++;
            if (calls == obsoleteCall) return oldReply.future;
            return http.Response(
              calls == obsoleteCall + 1
                  ? '{"items":[],"hasMore":false}'
                  : '{"items":[{"id":"a","name":"old"}],"hasMore":false}',
              200,
            );
          }),
        );
        const filter = {'name': 'old'};
        if (warmFilter) {
          await api.getCached('/nodes', filter);
        }
        await api.getCached('/nodes');
        final obsolete = api.get('/nodes', filter);
        await Future<void>.delayed(Duration.zero);
        expect(calls, obsoleteCall);
        api.handleLiveEvent({
          'event': 'nodeUpdate',
          'data': {'nodeId': 'a', 'name': 'new'},
        });
        final current = api.getCached('/nodes', filter);
        oldReply.complete(
          http.Response(
            '{"items":[{"id":"a","name":"old"}],"hasMore":false}',
            200,
          ),
        );
        final result = await current;
        expect((await obsolete)['items'].single['name'], 'old');
        expect(result['items'], isEmpty);
        expect(api.peekCache('/nodes', filter)['items'], isEmpty);
        expect(api.peekCache('/nodes')['items'].single['name'], 'new');
        expect(calls, obsoleteCall + 1);
        api.close();
      },
    );
  }

  test(
    'obsolete no-store response cannot erase a newer cached generation',
    () async {
      var calls = 0;
      final oldReply = Completer<http.Response>();
      final api = ApiClient(
        Uri.parse('https://host'),
        client: MockClient((r) async {
          calls++;
          if (calls == 1) return oldReply.future;
          return http.Response('{"value":"new"}', 200);
        }),
      );
      addTearDown(api.close);
      final old = api.getCached('/nodes');
      await Future<void>.delayed(Duration.zero);
      api.invalidateCache();
      expect(await api.getCached('/nodes'), {'value': 'new'});
      oldReply.complete(
        http.Response(
          '{"value":"old"}',
          200,
          headers: {'cache-control': 'no-store'},
        ),
      );
      expect(await old, {'value': 'old'});
      expect(api.peekCache('/nodes'), {'value': 'new'});
      expect(await api.getCached('/nodes'), {'value': 'new'});
      expect(calls, 2);
    },
  );

  test(
    'closing a client isolates its late response from a replacement client',
    () async {
      final oldReply = Completer<http.Response>();
      final oldApi = ApiClient(
        Uri.parse('https://host'),
        client: MockClient((r) => oldReply.future),
      );
      var currentReads = 0;
      final currentApi = ApiClient(
        Uri.parse('https://host'),
        client: MockClient((r) async {
          currentReads++;
          return http.Response('{"value":"current"}', 200);
        }),
      );
      addTearDown(currentApi.close);
      final old = oldApi.getCached('/nodes');
      final rejected = expectLater(old, throwsA(isA<ApiException>()));
      oldApi.close();
      await currentApi.getCached('/nodes');
      oldReply.complete(
        http.Response(
          '{"value":"old"}',
          200,
          headers: {'cache-control': 'no-store'},
        ),
      );
      await rejected;
      expect(await currentApi.getCached('/nodes'), {'value': 'current'});
      expect(currentReads, 1);
    },
  );
  test(
    'obsolete no-store response preserves a newer live-patched snapshot',
    () async {
      var calls = 0;
      final oldReply = Completer<http.Response>();
      final api = ApiClient(
        Uri.parse('https://host'),
        client: MockClient((r) async {
          calls++;
          if (calls == 2) return oldReply.future;
          return http.Response('{"items":[{"id":"a","name":"old"}]}', 200);
        }),
      );
      addTearDown(api.close);
      await api.getCached('/nodes');
      api.handleLiveEvent({
        'event': 'nodeUpdate',
        'data': {'nodeId': 'a', 'name': 'first-live'},
      });
      final old = api.get('/nodes');
      await Future<void>.delayed(Duration.zero);
      api.handleLiveEvent({
        'event': 'nodeUpdate',
        'data': {'nodeId': 'a', 'name': 'new'},
      });
      oldReply.complete(
        http.Response(
          '{"items":[{"id":"a","name":"old"}]}',
          200,
          headers: {'cache-control': 'no-store'},
        ),
      );
      expect((await old)['items'].single['name'], 'old');
      expect((await api.getCached('/nodes'))['items'].single['name'], 'new');
      expect(calls, 2);
    },
  );

  test('a live list patch leaves unrelated detail readers coalesced', () async {
    var calls = 0;
    final detail = Completer<http.Response>();
    final api = ApiClient(
      Uri.parse('https://host'),
      client: MockClient((r) async {
        calls++;
        if (r.url.path.endsWith('/nodes/b')) return detail.future;
        return http.Response('{"items":[{"id":"a","name":"old"}]}', 200);
      }),
    );
    addTearDown(api.close);
    await api.getCached('/nodes');
    final first = api.getCached('/nodes/b');
    await Future<void>.delayed(Duration.zero);
    api.handleLiveEvent({
      'event': 'nodeUpdate',
      'data': {'nodeId': 'a', 'name': 'new'},
    });
    final second = api.getCached('/nodes/b');
    detail.complete(http.Response('{"id":"b"}', 200));
    expect(await first, {'id': 'b'});
    expect(await second, {'id': 'b'});
    expect(calls, 2);
  });
  test(
    'body eviction preserves shared read ownership and no-store policy',
    () async {
      var nodeReads = 0;
      final oldReply = Completer<http.Response>();
      final api = ApiClient(
        Uri.parse('https://host'),
        client: MockClient((r) async {
          if (r.url.path.endsWith('/nodes/a')) {
            nodeReads++;
            if (nodeReads == 2) return oldReply.future;
            return http.Response(
              nodeReads == 1 ? '{"value":"cached"}' : '{"value":"fresh"}',
              200,
            );
          }
          return http.Response('{}', 200);
        }),
      );
      addTearDown(api.close);
      await api.getCached('/nodes/a');
      final old = api.get('/nodes/a');
      await Future<void>.delayed(Duration.zero);
      for (var i = 0; i < 256; i++) {
        await api.getCached('/other/$i');
      }
      expect(api.peekCache('/nodes/a'), isNull);
      final fresh = api.getCached('/nodes/a');
      oldReply.complete(
        http.Response(
          '{"value":"pending"}',
          200,
          headers: {'cache-control': 'no-store'},
        ),
      );
      expect(await old, {'value': 'pending'});
      expect(await fresh, {'value': 'pending'});
      expect(api.peekCache('/nodes/a'), isNull);
      expect(nodeReads, 2);
      expect(await api.getCached('/nodes/a'), {'value': 'fresh'});
      expect(nodeReads, 3);
    },
  );

  test('current no-store read removes its own cached snapshot', () async {
    var calls = 0;
    final api = ApiClient(
      Uri.parse('https://host'),
      client: MockClient((r) async {
        calls++;
        return http.Response(
          calls == 1 ? '{"value":"cached"}' : '{"value":"fresh"}',
          200,
          headers: calls == 1 ? {} : {'cache-control': 'no-store'},
        );
      }),
    );
    addTearDown(api.close);
    await api.getCached('/nodes');
    expect(await api.get('/nodes'), {'value': 'fresh'});
    expect(api.peekCache('/nodes'), isNull);
    expect(await api.getCached('/nodes'), {'value': 'fresh'});
    expect(api.peekCache('/nodes'), isNull);
    expect(calls, 3);
  });
  test(
    'retained newer cache data still counts toward the byte budget',
    () async {
      const mib = 1024 * 1024;
      var calls = 0;
      final oldReply = Completer<http.Response>();
      final api = ApiClient(
        Uri.parse('https://host'),
        client: MockClient((r) async {
          calls++;
          if (calls == 1) return oldReply.future;
          return http.Response(
            jsonEncode({
              'value':
                  'x' * (r.url.path.endsWith('/nodes') ? 4 * mib : 5 * mib),
            }),
            200,
          );
        }),
      );
      addTearDown(api.close);
      final old = api.getCached('/nodes');
      await Future<void>.delayed(Duration.zero);
      api.invalidateCache();
      await api.getCached('/nodes');
      oldReply.complete(
        http.Response('{}', 200, headers: {'cache-control': 'no-store'}),
      );
      await old;
      expect(api.peekCache('/nodes')['value'].length, 4 * mib);
      await api.getCached('/other');
      expect(api.peekCache('/nodes') == null, isTrue);
      expect(api.peekCache('/other')['value'].length, 5 * mib);
      expect(calls, 3);
    },
  );
}
