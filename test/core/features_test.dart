import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/core/features.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('ServerFeatures.fromInfo', () {
    test('reads the Atlas cap and falls back to 12', () {
      expect(ServerFeatures.fromInfo(null).atlasLimit, 12);
      expect(
        ServerFeatures.fromInfo({
          'limits': {'atlas': 20},
        }).atlasLimit,
        20,
      );
      for (final bad in [0, 101, 'x', 20.5]) {
        expect(
          ServerFeatures.fromInfo({
            'limits': {'atlas': bad},
          }).atlasLimit,
          12,
        );
      }
    });

    test('null info is all off', () {
      final f = ServerFeatures.fromInfo(null);
      expect(f.polling, false);
      expect(f.accounts, 'off');
      expect(f.telemetryRequests, false);
      expect(f.alerts, false);
      expect(f.registration, false);
    });

    test('registration is read when present', () {
      expect(
        ServerFeatures.fromInfo({
          'features': {'accounts': 'local', 'registration': true},
        }).registration,
        true,
      );
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

    test('portalUrl is read, a bad one is dropped', () {
      final f = ServerFeatures.fromInfo({
        'features': {
          'accounts': 'portal',
          'portalUrl': 'https://portal.example',
        },
      });
      expect(f.portalUrl, 'https://portal.example');
      final bad = ServerFeatures.fromInfo({
        'features': {'portalUrl': 4},
      });
      expect(bad.portalUrl, isNull);
    });

    test('alert channels and the push server are read', () {
      final f = ServerFeatures.fromInfo({
        'features': {
          'alerts': true,
          'alertChannels': {'email': false, 'push': true},
          'push': {
            'server': 'https://push.meshcorebeacon.ca',
            'pushId': 'inst_7f3k2m9qxa',
          },
        },
      });
      expect(f.alertEmail, false);
      expect(f.alertPush, true);
      expect(f.push!.server, Uri.parse('https://push.meshcorebeacon.ca'));
      expect(f.push!.pushId, 'inst_7f3k2m9qxa');
    });

    test('missing channels read as off and no push server', () {
      final f = ServerFeatures.fromInfo({'features': {}});
      expect(f.alertEmail, false);
      expect(f.alertPush, false);
      expect(f.push, isNull);
      expect(ServerFeatures.fromInfo(null).push, isNull);
    });

    test('a push server that is not https, or has no id, is ignored', () {
      for (final push in [
        {'server': 'http://push.example', 'pushId': 'inst_a'},
        {'server': 'https://push.example', 'pushId': ''},
        {'server': 'https://push.example'},
        {'server': 4, 'pushId': 'inst_a'},
        'https://push.example',
      ]) {
        final f = ServerFeatures.fromInfo({
          'features': {
            'alertChannels': {'push': true},
            'push': push,
          },
        });
        expect(f.push, isNull, reason: '$push');
      }
    });

    test('display units and mapTelemetry default and parse', () {
      final none = ServerFeatures.fromInfo({'features': {}});
      expect(none.temperatureUnit, 'c');
      expect(none.distanceUnit, 'metric');
      expect(none.mapTelemetry, false);
      final f = ServerFeatures.fromInfo({
        'features': {'mapTelemetry': true},
        'display': {'temperatureUnit': 'f', 'distanceUnit': 'imperial'},
      });
      expect(f.temperatureUnit, 'f');
      expect(f.distanceUnit, 'imperial');
      expect(f.mapTelemetry, true);
      final odd = ServerFeatures.fromInfo({
        'display': {'temperatureUnit': 'k', 'distanceUnit': 'furlongs'},
      });
      expect(odd.temperatureUnit, 'c');
      expect(odd.distanceUnit, 'metric');
      const off = ServerFeatures.off();
      expect(off.temperatureUnit, 'c');
      expect(off.distanceUnit, 'metric');
      expect(off.mapTelemetry, false);
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

    test('features() remembers a 404 for good', () async {
      var calls = 0;
      var now = DateTime(2026, 1, 1);
      final api = ApiClient(
        Uri.parse('https://test.invalid'),
        transientRetries: 0,
        now: () => now,
        client: MockClient((r) async {
          calls++;
          return http.Response('{}', 404);
        }),
      );
      await api.features();
      now = now.add(const Duration(hours: 1));
      await api.features();
      expect(calls, 1);
    });

    test('features() forgets a failure after a minute', () async {
      var calls = 0;
      var now = DateTime(2026, 1, 1);
      final api = ApiClient(
        Uri.parse('https://test.invalid'),
        transientRetries: 0,
        now: () => now,
        client: MockClient((r) async {
          calls++;
          if (calls == 1) throw http.ClientException('down');
          return http.Response('{"features":{"polling":true}}', 200);
        }),
      );
      expect((await api.features()).polling, false);
      now = now.add(const Duration(seconds: 30));
      expect((await api.features()).polling, false);
      expect(calls, 1);
      now = now.add(const Duration(seconds: 31));
      expect((await api.features()).polling, true);
      expect(calls, 2);
    });

    test(
      'a successful features() answer is re-read after five minutes',
      () async {
        var calls = 0;
        var now = DateTime(2026, 1, 1);
        final api = ApiClient(
          Uri.parse('https://test.invalid'),
          transientRetries: 0,
          now: () => now,
          client: MockClient((r) async {
            calls++;
            return http.Response(
              jsonEncode({
                'features': {'polling': calls > 1},
              }),
              200,
            );
          }),
        );
        expect((await api.features()).polling, false);
        now = now.add(const Duration(minutes: 4, seconds: 59));
        expect((await api.features()).polling, false);
        expect(calls, 1);
        now = now.add(const Duration(seconds: 2));
        expect((await api.features()).polling, true);
        expect(calls, 2);
      },
    );

    test('invalidateCache() forces features() to be re-read', () async {
      var calls = 0;
      final api = client((r) async {
        calls++;
        return http.Response('{"features":{"polling":true}}', 200);
      });
      await api.features();
      api.invalidateCache();
      await api.features();
      expect(calls, 2);
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
