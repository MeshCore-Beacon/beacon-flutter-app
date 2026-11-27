import 'dart:convert';

import 'package:beacon/core/push_relay.dart';
import 'package:beacon/core/push_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

PushEntry entry(String pushId, {String url = 'https://a.example'}) => PushEntry(
  pushId: pushId,
  relay: Uri.parse('https://push.example'),
  handle: 'h_$pushId',
  handleSecret: 's_$pushId',
  key: base64.encode(List.filled(32, 7)),
  url: url,
  name: 'Server $pushId',
  token: 'fcm-$pushId',
);

void main() {
  group('SecurePushStore', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    test('writes, reads, lists and deletes entries by push id', () async {
      final store = SecurePushStore();
      await store.write(entry('inst_a'));
      await store.write(entry('inst_b', url: 'https://b.example'));
      final a = await store.read('inst_a');
      expect(a!.handle, 'h_inst_a');
      expect(a.relay, Uri.parse('https://push.example'));
      expect(a.keyBytes, List.filled(32, 7));
      expect(a.name, 'Server inst_a');
      expect(a.token, 'fcm-inst_a');
      expect((await store.all()).map((e) => e.pushId), {'inst_a', 'inst_b'});
      expect((await store.forUrl('https://b.example'))!.pushId, 'inst_b');
      await store.delete('inst_a');
      expect(await store.read('inst_a'), isNull);
      expect(await store.all(), hasLength(1));
    });

    test('other keys and damaged entries are skipped', () async {
      FlutterSecureStorage.setMockInitialValues({
        'beacon.token.https://a.example': 'tok',
        'beacon.push.inst_x': '{not json',
        'beacon.push.inst_y': '{"pushId":"inst_y"}',
      });
      final store = SecurePushStore();
      expect(await store.all(), isEmpty);
      expect(await store.read('inst_x'), isNull);
    });

    test('the key is the shape the iOS extension reads', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final store = SecurePushStore();
      await store.write(entry('inst_a'));
      final raw = await store.storage.read(
        key: 'beacon.push.inst_a',
        iOptions: SecurePushStore.iosOptions,
      );
      final json = jsonDecode(raw!) as Map;
      expect(json['key'], base64.encode(List.filled(32, 7)));
      expect(json['name'], 'Server inst_a');
      expect(SecurePushStore.iosOptions.toMap()['groupId'], iosKeychainGroup);
    });
  });

  group('PushRelay', () {
    late List<http.Request> seen;
    late http.Response Function(http.Request) answer;
    late PushRelay relay;
    final server = Uri.parse('https://push.example');

    setUp(() {
      seen = [];
      answer = (_) => http.Response('', 204);
      relay = PushRelay(
        client: MockClient((r) async {
          seen.add(r);
          return answer(r);
        }),
      );
    });

    test('createHandle posts the push id, platform and token', () async {
      answer = (_) => http.Response(
        jsonEncode({'handle': 'h_1', 'handleSecret': 'sec'}),
        201,
      );
      final (handle, secret) = await relay.createHandle(
        server,
        pushId: 'inst_a',
        platform: 'android',
        token: 'fcm-1',
      );
      expect((handle, secret), ('h_1', 'sec'));
      expect(seen.single.method, 'POST');
      expect(seen.single.url.toString(), 'https://push.example/v1/handles');
      expect(jsonDecode(seen.single.body), {
        'pushId': 'inst_a',
        'platform': 'android',
        'token': 'fcm-1',
      });
      expect(seen.single.headers['content-type'], contains('json'));
    });

    test('a bad answer or an error throws', () async {
      answer = (_) => http.Response(jsonEncode({'handle': 'h_1'}), 200);
      expect(
        relay.createHandle(server, pushId: 'a', platform: 'ios', token: 't'),
        throwsA(isA<PushRelayException>()),
      );
      answer = (_) => http.Response(
        jsonEncode({
          'error': {'code': 'unknown_push_id', 'message': 'x'},
        }),
        404,
      );
      await expectLater(
        relay.createHandle(server, pushId: 'a', platform: 'ios', token: 't'),
        throwsA(
          isA<PushRelayException>().having(
            (e) => e.code,
            'code',
            'unknown_push_id',
          ),
        ),
      );
    });

    test('updateHandle puts the secret and new token', () async {
      await relay.updateHandle(
        server,
        'h_1/x',
        handleSecret: 'sec',
        token: 'fcm-2',
      );
      expect(seen.single.method, 'PUT');
      expect(seen.single.url.path, '/v1/handles/h_1%2Fx');
      expect(jsonDecode(seen.single.body), {
        'handleSecret': 'sec',
        'token': 'fcm-2',
      });
    });

    test('iOS adds its APNs environment to both calls', () async {
      answer = (_) => http.Response(
        jsonEncode({'handle': 'h_1', 'handleSecret': 'sec'}),
        201,
      );
      await relay.createHandle(
        server,
        pushId: 'inst_a',
        platform: 'ios',
        token: 'ab01',
        apnsEnvironment: 'sandbox',
      );
      await relay.updateHandle(
        server,
        'h_1',
        handleSecret: 'sec',
        token: 'ab02',
        apnsEnvironment: 'production',
      );
      expect(jsonDecode(seen.first.body), {
        'pushId': 'inst_a',
        'platform': 'ios',
        'token': 'ab01',
        'apnsEnvironment': 'sandbox',
      });
      expect(jsonDecode(seen.last.body), {
        'handleSecret': 'sec',
        'token': 'ab02',
        'apnsEnvironment': 'production',
      });
    });

    test('deleteHandle sends the secret; an unknown handle is done', () async {
      await relay.deleteHandle(server, 'h_1', handleSecret: 'sec');
      expect(seen.single.method, 'DELETE');
      expect(seen.single.url.path, '/v1/handles/h_1');
      expect(jsonDecode(seen.single.body), {'handleSecret': 'sec'});
      answer = (_) => http.Response(
        jsonEncode({
          'error': {'code': 'unknown_handle', 'message': 'x'},
        }),
        404,
      );
      await relay.deleteHandle(server, 'h_1', handleSecret: 'sec');
      answer = (_) => http.Response('', 500);
      expect(
        relay.deleteHandle(server, 'h_1', handleSecret: 'sec'),
        throwsA(isA<PushRelayException>()),
      );
    });
  });
}
