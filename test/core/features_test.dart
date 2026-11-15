import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/core/features.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('ServerFeatures.fromInfo', () {
    test('null info is all off', () {
      final f = ServerFeatures.fromInfo(null);
      expect(f.polling, false);
      expect(f.accounts, 'off');
      expect(f.telemetryRequests, false);
      expect(f.alerts, false);
    });

    test('info without features is all off', () {
      final f = ServerFeatures.fromInfo({'minAppVersion': '2.0.0'});
      expect(f.polling, false);
      expect(f.accounts, 'off');
    });

    test('a full object is read', () {
      final f = ServerFeatures.fromInfo({
        'features': {
          'polling': true,
          'accounts': 'optional',
          'telemetryRequests': true,
          'alerts': true,
        },
      });
      expect(f.polling, true);
      expect(f.accounts, 'optional');
      expect(f.telemetryRequests, true);
      expect(f.alerts, true);
    });

    test('wrong types fall back to off', () {
      final f = ServerFeatures.fromInfo({
        'features': {'polling': 'yes', 'accounts': 3},
      });
      expect(f.polling, false);
      expect(f.accounts, 'off');
    });
  });

  group('ApiClient', () {
    ApiClient client(Future<http.Response> Function(http.Request) handler) =>
        ApiClient(
          Uri.parse('https://test.invalid'),
          transientRetries: 0,
          client: MockClient(handler),
        );

    test('features() is off on a 404', () async {
      final api = client((r) async => http.Response('{}', 404));
      expect((await api.features()).polling, false);
    });

    test('features() is off when the request throws', () async {
      final api = client((r) async => throw http.ClientException('down'));
      expect((await api.features()).polling, false);
    });

    test('features() reads /info and caches it', () async {
      var calls = 0;
      final api = client((r) async {
        calls++;
        expect(r.url.path, '/api/v1/info');
        return http.Response(
          jsonEncode({
            'features': {'polling': true},
          }),
          200,
        );
      });
      expect((await api.features()).polling, true);
      expect((await api.features()).polling, true);
      expect(calls, 1);
    });

    test('nodeTelemetry and nodePolling use the node routes', () async {
      final seen = <Uri>[];
      final api = client((r) async {
        seen.add(r.url);
        expect(r.headers.containsKey('authorization'), false);
        return http.Response('{"points":[]}', 200);
      });
      await api.nodeTelemetry('abc/1');
      await api.nodeTelemetry('abc/1', range: '24h');
      await api.nodePolling('abc/1');
      expect(seen[0].path, '/api/v1/nodes/abc%2F1/telemetry');
      expect(seen[0].queryParameters, {'range': '168h', 'interval': '6h'});
      expect(seen[1].queryParameters, {'range': '24h', 'interval': '1h'});
      expect(seen[2].path, '/api/v1/nodes/abc%2F1/polling');
      expect(seen[2].query, '');
    });

    test('a 404 from nodeTelemetry carries its status', () async {
      final api = client((r) async => http.Response('{}', 404));
      expect(
        api.nodeTelemetry('x'),
        throwsA(isA<ApiException>().having((e) => e.status, 'status', 404)),
      );
    });
  });
}
