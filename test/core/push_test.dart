import 'dart:convert';

import 'package:beacon/core/account.dart';
import 'package:beacon/core/auth_api.dart';
import 'package:beacon/core/features.dart';
import 'package:beacon/core/push.dart';
import 'package:beacon/core/push_notice.dart';
import 'package:beacon/core/push_relay.dart';
import 'package:beacon/core/push_store.dart';
import 'package:beacon/core/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../fake_push.dart';

const _base = 'https://beacon.example.com';
const _relay = 'https://push.example';

void main() {
  late MemoryTokenStore tokens;
  late List<http.Request> seen;
  late List<http.Request> relaySeen;
  late AccountState account;
  late FakePush push;
  late ServerFeatures features;
  late MemoryPushStore store;
  late PushHub hub;
  late PushRegistration registration;
  late int deviceStatus;
  late Map<String, Object?> deviceError;
  late bool pushEnabled;
  late int relayStatus;
  late http.Response? Function(http.Request)? relayAnswer;
  late int handles;

  setUp(() {
    tokens = MemoryTokenStore();
    seen = [];
    relaySeen = [];
    deviceStatus = 204;
    deviceError = {};
    pushEnabled = true;
    relayStatus = 200;
    relayAnswer = null;
    handles = 0;
    features = ServerFeatures(
      polling: false,
      accounts: 'local',
      telemetryRequests: false,
      alerts: true,
      alertPush: true,
      push: PushServerInfo(Uri.parse(_relay), 'inst_a'),
    );
    push = FakePush();
    store = MemoryPushStore();
    account = AccountState(
      AuthApi(
        _base,
        tokens,
        client: MockClient((r) async {
          seen.add(r);
          if (r.url.path.endsWith('/me/devices')) {
            return http.Response(jsonEncode(deviceError), deviceStatus);
          }
          if (r.url.path.endsWith('/me/alerts')) {
            return http.Response(
              jsonEncode({
                'channels': {
                  'email': {'available': true, 'enabled': true, 'reason': ''},
                  'push': {
                    'available': true,
                    'enabled': pushEnabled,
                    'hasDevice': false,
                  },
                },
                'targets': [],
              }),
              200,
            );
          }
          return http.Response(jsonEncode({}), 200);
        }),
      ),
    );
    hub = PushHub(
      client: push,
      store: store,
      relay: PushRelay(
        client: MockClient((r) async {
          relaySeen.add(r);
          final answer = relayAnswer?.call(r);
          if (answer != null) return answer;
          if (relayStatus != 200) return http.Response('', relayStatus);
          if (r.method == 'POST') {
            handles++;
            return http.Response(
              jsonEncode({
                'handle': 'h_$handles',
                'handleSecret': 's_$handles',
              }),
              201,
            );
          }
          return http.Response('', 204);
        }),
      ),
      random: () => 9,
    );
    registration = PushRegistration(
      hub: hub,
      account: account,
      features: () async => features,
      serverUrl: _base,
      serverName: () => 'Ottawa Mesh',
    );
    account.push = registration;
  });

  tearDown(() async {
    registration.dispose();
    hub.dispose();
    await push.close();
  });

  Future<void> signIn() async {
    await tokens.write(_base, 'abc');
    account.adopt({'id': 'u1', 'username': 'a'});
    await pump();
  }

  Iterable<http.Request> devices(String method) =>
      seen.where((r) => r.method == method && r.url.path.endsWith('/devices'));
  List<String> relayCalls() => [
    for (final r in relaySeen) '${r.method} ${r.url.path}',
  ];

  group('PushRegistration', () {
    test('signed out does nothing at all', () async {
      await registration.refresh();
      expect(registration.status, PushStatus.off);
      expect(push.calls, isEmpty);
    });

    test('a build without configuration never asks or registers', () async {
      push.isAvailable = false;
      await signIn();
      expect(registration.status, PushStatus.notSetUp);
      expect(push.calls, ['available']);
      expect(seen, isEmpty);
      await registration.enable();
      expect(seen, isEmpty);
      expect(relaySeen, isEmpty);
    });

    test(
      'a server without features.push, or alerts off, is left alone',
      () async {
        features = const ServerFeatures(
          polling: false,
          accounts: 'local',
          telemetryRequests: false,
          alerts: true,
          alertEmail: true,
        );
        await signIn();
        expect(registration.status, PushStatus.off);
        await registration.enable();
        expect(registration.status, PushStatus.off);
        expect(push.calls, isEmpty);
        expect(relaySeen, isEmpty);
      },
    );

    test('never asks for permission on its own', () async {
      await signIn();
      expect(registration.status, PushStatus.needsPermission);
      expect(push.calls, ['available', 'permission']);
      expect(seen, isEmpty);
    });

    test('enable asks, gets a handle, keeps a new key and registers', () async {
      await signIn();
      await registration.enable();
      expect(push.calls, contains('request'));
      expect(registration.status, PushStatus.registered);
      expect(relayCalls(), ['POST /v1/handles']);
      expect(jsonDecode(relaySeen.single.body), {
        'pushId': 'inst_a',
        'platform': 'android',
        'token': 'tok-1',
      });
      final entry = (await store.read('inst_a'))!;
      expect(entry.handle, 'h_1');
      expect(entry.handleSecret, 's_1');
      expect(entry.keyBytes, List.filled(32, 9));
      expect(entry.relay, Uri.parse(_relay));
      expect(entry.url, _base);
      expect(entry.name, 'Ottawa Mesh');
      final post = devices('POST').single;
      expect(jsonDecode(post.body), {
        'platform': 'android',
        'pushToken': 'h_1',
        'payloadKey': base64.encode(List.filled(32, 9)),
      });
      expect(post.headers['authorization'], 'Bearer abc');
    });

    test('a refusal is remembered and nothing is sent', () async {
      await signIn();
      push.afterRequest = PushPermission.denied;
      await registration.enable();
      expect(registration.status, PushStatus.denied);
      expect(seen, isEmpty);
      expect(relaySeen, isEmpty);
    });

    test('already granted registers after sign-in without asking', () async {
      push.state = PushPermission.granted;
      await signIn();
      expect(registration.status, PushStatus.registered);
      expect(push.calls, isNot(contains('request')));
      expect(devices('POST'), hasLength(1));
    });

    test(
      'the user\'s push switch off is respected, not turned back on',
      () async {
        push.state = PushPermission.granted;
        pushEnabled = false;
        await signIn();
        expect(registration.status, PushStatus.paused);
        expect(devices('POST'), isEmpty);
        expect(relaySeen, isEmpty);
      },
    );

    PushEntry stored({String relay = _relay, String token = 'tok-1'}) =>
        PushEntry(
          pushId: 'inst_a',
          relay: Uri.parse(relay),
          handle: 'h_old',
          handleSecret: 's_old',
          key: base64.encode(List.filled(32, 3)),
          url: _base,
          name: 'Old name',
          token: token,
        );

    test('a stored handle for the same token is reused as it is', () async {
      push.state = PushPermission.granted;
      await store.write(stored());
      await signIn();
      expect(relaySeen, isEmpty);
      final entry = (await store.read('inst_a'))!;
      expect(entry.handle, 'h_old');
      expect(entry.name, 'Ottawa Mesh');
      expect(jsonDecode(devices('POST').single.body), {
        'platform': 'android',
        'pushToken': 'h_old',
        'payloadKey': base64.encode(List.filled(32, 3)),
      });
      expect(registration.status, PushStatus.registered);
    });

    test('a changed token moves the stored handle', () async {
      push.state = PushPermission.granted;
      await store.write(stored(token: 'tok-0'));
      await signIn();
      expect(relayCalls(), ['PUT /v1/handles/h_old']);
      expect(jsonDecode(relaySeen.single.body), {
        'handleSecret': 's_old',
        'token': 'tok-1',
      });
      final entry = (await store.read('inst_a'))!;
      expect((entry.handle, entry.token), ('h_old', 'tok-1'));
    });

    test('iOS sends its APNs environment with a new handle', () async {
      push
        ..platform = 'ios'
        ..environment = 'sandbox';
      await signIn();
      await registration.enable();
      expect(jsonDecode(relaySeen.single.body), {
        'pushId': 'inst_a',
        'platform': 'ios',
        'token': 'tok-1',
        'apnsEnvironment': 'sandbox',
      });
      expect(jsonDecode(devices('POST').single.body)['platform'], 'ios');
    });

    test('iOS sends its APNs environment when the token moves', () async {
      push
        ..platform = 'ios'
        ..environment = 'production'
        ..state = PushPermission.granted;
      await store.write(stored(token: 'tok-0'));
      await signIn();
      expect(jsonDecode(relaySeen.single.body), {
        'handleSecret': 's_old',
        'token': 'tok-1',
        'apnsEnvironment': 'production',
      });
    });

    test(
      'a handle the push server forgot is replaced, keeping the key',
      () async {
        push.state = PushPermission.granted;
        await store.write(stored(token: 'tok-0'));
        relayAnswer = (r) => r.method == 'PUT'
            ? http.Response(
                jsonEncode({
                  'error': {'code': 'unknown_handle', 'message': 'x'},
                }),
                404,
              )
            : null;
        await signIn();
        expect(relayCalls(), ['PUT /v1/handles/h_old', 'POST /v1/handles']);
        final entry = (await store.read('inst_a'))!;
        expect(entry.handle, 'h_1');
        expect(entry.keyBytes, List.filled(32, 3));
        expect(jsonDecode(devices('POST').single.body)['pushToken'], 'h_1');
      },
    );

    test('a new push server gets a new handle and the old one stops', () async {
      push.state = PushPermission.granted;
      await store.write(stored(relay: 'https://old-push.example'));
      await signIn();
      expect(relayCalls(), ['POST /v1/handles', 'DELETE /v1/handles/h_old']);
      expect(relaySeen.last.url.host, 'old-push.example');
      expect((await store.read('inst_a'))!.handle, 'h_1');
    });

    test('a push server error reads as failed and skips the device', () async {
      push.state = PushPermission.granted;
      relayStatus = 503;
      await signIn();
      expect(registration.status, PushStatus.failed);
      expect(devices('POST'), isEmpty);
    });

    test('push_disabled from the server reads as off', () async {
      push.state = PushPermission.granted;
      deviceStatus = 404;
      deviceError = {
        'error': {'code': 'push_disabled', 'message': 'x'},
      };
      await signIn();
      expect(registration.status, PushStatus.off);
    });

    test('a server error while registering reads as failed', () async {
      push.state = PushPermission.granted;
      deviceStatus = 500;
      await signIn();
      expect(registration.status, PushStatus.failed);
    });

    test(
      'no token from the plugin reads as failed and sends nothing',
      () async {
        push.state = PushPermission.granted;
        push.deviceToken = null;
        await signIn();
        expect(registration.status, PushStatus.failed);
        expect(seen.where((r) => r.method == 'POST'), isEmpty);
        expect(relaySeen, isEmpty);
      },
    );

    test(
      'sign out removes the device, then the handle, then the entry',
      () async {
        push.state = PushPermission.granted;
        await signIn();
        relaySeen.clear();
        await account.signOut();
        final order = [for (final r in seen) '${r.method} ${r.url.path}']
            .where((e) => !e.startsWith('GET'))
            .toList();
        expect(order, [
          'POST /api/v1/me/devices',
          'DELETE /api/v1/me/devices',
          'POST /api/v1/auth/logout',
        ]);
        expect(relayCalls(), ['DELETE /v1/handles/h_1']);
        expect(jsonDecode(relaySeen.single.body), {'handleSecret': 's_1'});
        expect(await store.read('inst_a'), isNull);
        expect(registration.status, PushStatus.off);
        expect(push.calls, isNot(contains('deleteToken')));
      },
    );

    test('sign out still completes when the removals fail', () async {
      push.state = PushPermission.granted;
      await signIn();
      deviceStatus = 500;
      relayStatus = 500;
      await account.signOut();
      expect(await tokens.read(_base), isNull);
      expect(await store.read('inst_a'), isNull);
    });

    test('sign out with push never set up sends no device call', () async {
      push.isAvailable = false;
      await signIn();
      await account.signOut();
      expect(devices('DELETE'), isEmpty);
      expect(relaySeen, isEmpty);
    });
  });

  group('PushHub', () {
    PushEntry entryFor(String pushId, String url, int k) => PushEntry(
      pushId: pushId,
      relay: Uri.parse(_relay),
      handle: 'h_$pushId',
      handleSecret: 's_$pushId',
      key: base64.encode(List.filled(32, k)),
      url: url,
      name: 'Server $pushId',
      token: 'tok-1',
    );

    test('a token refresh moves every stored handle', () async {
      await store.write(entryFor('inst_a', _base, 1));
      await store.write(entryFor('inst_b', 'https://b.example', 2));
      await hub.start();
      push.refresh.add('tok-2');
      await pump();
      expect(relayCalls(), {
        'PUT /v1/handles/h_inst_a',
        'PUT /v1/handles/h_inst_b',
      });
      expect(jsonDecode(relaySeen.first.body)['token'], 'tok-2');
      expect((await store.read('inst_b'))!.token, 'tok-2');
      expect(seen, isEmpty);
    });

    test(
      'start moves stale handles and retries failures next launch',
      () async {
        push.state = PushPermission.granted;
        await store.write(
          entryFor('inst_a', _base, 1).copyWith(token: 'tok-0'),
        );
        await store.write(
          entryFor('inst_b', 'https://b.example', 2).copyWith(token: 'tok-0'),
        );
        relayAnswer = (r) =>
            r.url.path.endsWith('/h_inst_b') ? http.Response('', 500) : null;
        await hub.start();
        expect(relayCalls(), [
          'PUT /v1/handles/h_inst_a',
          'PUT /v1/handles/h_inst_b',
        ]);
        expect((await store.read('inst_a'))!.token, 'tok-1');
        expect((await store.read('inst_b'))!.token, 'tok-0');

        relaySeen.clear();
        relayAnswer = null;
        final relaunched = PushHub(
          client: push,
          store: store,
          relay: hub.relay,
        );
        await relaunched.start();
        relaunched.dispose();
        expect(relayCalls(), ['PUT /v1/handles/h_inst_b']);
        expect(jsonDecode(relaySeen.single.body)['token'], 'tok-1');
        expect((await store.read('inst_b'))!.token, 'tok-1');
      },
    );

    test('start leaves handles alone without permission', () async {
      await store.write(entryFor('inst_a', _base, 1).copyWith(token: 'tok-0'));
      await hub.start();
      expect(relaySeen, isEmpty);
      expect(push.calls, isNot(contains('token')));
    });

    test('an iOS token refresh carries the APNs environment', () async {
      push.environment = 'sandbox';
      await store.write(entryFor('inst_a', _base, 1));
      await hub.start();
      push.refresh.add('tok-2');
      await pump();
      expect(jsonDecode(relaySeen.single.body), {
        'handleSecret': 's_inst_a',
        'token': 'tok-2',
        'apnsEnvironment': 'sandbox',
      });
    });

    test('nothing starts in a build without configuration', () async {
      push.isAvailable = false;
      await store.write(entryFor('inst_a', _base, 1));
      await hub.start();
      push.refresh.add('tok-2');
      await pump();
      expect(relaySeen, isEmpty);
    });

    Future<Map<String, Object?>> sealed(
      String pushId,
      int k,
      Object plain,
    ) async => {
      'v': '1',
      'pushId': pushId,
      'serverName': 'X',
      'messageId': 'm_1',
      'ct': await sealNotice(List.filled(32, k), pushId, jsonEncode(plain)),
    };

    test(
      'a tapped sealed notice opens its radio on the active server',
      () async {
        await store.write(entryFor('inst_a', _base, 1));
        final opened = <PushTarget>[];
        hub.activeUrl = () => _base;
        hub.attach(_base, opened.add);
        await hub.start();
        push.taps.add(
          await sealed('inst_a', 1, {
            'kind': 'battery_low',
            'targetKind': 'node',
            'publicKey': 'aabb',
            'id': 'n1',
          }),
        );
        push.taps.add(
          await sealed('inst_a', 1, {
            'kind': 'rebooted',
            'targetKind': 'observer',
            'publicKey': 'ccdd',
            'id': '',
          }),
        );
        await pump();
        expect(
          [for (final t in opened) '${t.kind}:${t.publicKey}:${t.id}'],
          ['node:aabb:n1', 'observer:ccdd:null'],
        );
      },
    );

    test('a tap for another server switches to it, then opens', () async {
      await store.write(entryFor('inst_b', 'https://b.example', 2));
      String active = _base;
      final selected = <String>[];
      hub.activeUrl = () => active;
      hub.selectServer = (url) async {
        selected.add(url);
        active = url;
      };
      final onA = <PushTarget>[];
      hub.attach(_base, onA.add);
      await hub.start();
      push.taps.add({
        'pushId': 'inst_b',
        'targetKind': 'node',
        'publicKey': 'eeff',
        'id': 'n2',
      });
      await pump();
      expect(selected, ['https://b.example']);
      expect(onA, isEmpty);
      final onB = <PushTarget>[];
      hub.attach('https://b.example', onB.add);
      expect(onB.single.publicKey, 'eeff');
      hub.attach('https://b.example', onB.add);
      expect(onB, hasLength(1));
    });

    test('unknown servers, wrong keys and junk open nothing', () async {
      await store.write(entryFor('inst_a', _base, 1));
      final opened = <PushTarget>[];
      hub.activeUrl = () => _base;
      hub.attach(_base, opened.add);
      await hub.start();
      push.taps.add(
        await sealed('inst_a', 5, {'kind': 'rebooted', 'publicKey': 'aa'}),
      );
      push.taps.add(
        await sealed('inst_z', 1, {'kind': 'rebooted', 'publicKey': 'aa'}),
      );
      push.taps.add({'pushId': 'inst_a'});
      push.taps.add({'other': 'x'});
      await pump();
      expect(opened, isEmpty);
    });

    test('the notification that launched the app is opened once', () async {
      await store.write(entryFor('inst_a', _base, 1));
      push.initial = {
        'pushId': 'inst_a',
        'targetKind': 'observer',
        'publicKey': 'ccdd',
      };
      final opened = <PushTarget>[];
      hub.activeUrl = () => _base;
      hub.attach(_base, opened.add);
      await hub.start();
      await hub.start();
      await pump();
      expect(opened.single.publicKey, 'ccdd');
    });

    test('forgetting a server removes its device, handle and entry', () async {
      await store.write(entryFor('inst_a', _base, 1));
      await store.write(entryFor('inst_b', 'https://b.example', 2));
      await tokens.write(_base, 'abc');
      await hub.forget(_base, account.api);
      expect(devices('DELETE'), hasLength(1));
      expect(relayCalls(), ['DELETE /v1/handles/h_inst_a']);
      expect(await store.read('inst_a'), isNull);
      expect(await store.read('inst_b'), isNotNull);
      seen.clear();
      await hub.forget('https://none.example', account.api);
      expect(seen, isEmpty);
    });
  });
}

Future<void> pump() =>
    Future<void>.delayed(Duration.zero)
        .then((_) => Future<void>.delayed(const Duration(milliseconds: 10)));
