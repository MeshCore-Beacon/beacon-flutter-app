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
}
