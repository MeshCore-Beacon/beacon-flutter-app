import 'dart:convert';

import 'package:beacon/core/account.dart';
import 'package:beacon/core/auth_api.dart';
import 'package:beacon/core/features.dart';
import 'package:beacon/core/push.dart';
import 'package:beacon/core/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../fake_push.dart';

const _base = 'https://beacon.example.com';

void main() {
  late MemoryTokenStore tokens;
  late List<http.Request> seen;
  late AccountState account;
  late FakePush push;
  late ServerFeatures features;
  late PushRegistration registration;
  var deviceStatus = 204;

  setUp(() {
    tokens = MemoryTokenStore();
    seen = [];
    deviceStatus = 204;
    features = const ServerFeatures(
      polling: false,
      accounts: 'local',
      telemetryRequests: false,
      alerts: true,
      alertDelivery: 'push',
    );
    push = FakePush();
    account = AccountState(
      AuthApi(
        _base,
        tokens,
        client: MockClient((r) async {
          seen.add(r);
          if (r.url.path.endsWith('/me/devices')) {
            return http.Response('', deviceStatus);
          }
          return http.Response(jsonEncode({}), 200);
        }),
      ),
    );
    registration = PushRegistration(
      client: push,
      account: account,
      features: () async => features,
    );
    account.push = registration;
  });

  tearDown(() async {
    registration.dispose();
    await push.close();
  });

  Future<void> signIn() async {
    await tokens.write(_base, 'abc');
    account.adopt({'id': 'u1', 'username': 'a'});
    await pump();
  }

  Iterable<http.Request> devices(String method) =>
      seen.where((r) => r.method == method && r.url.path.endsWith('/devices'));

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
    expect(push.calls, ['available', 'available']);
    expect(seen, isEmpty);
  });

  test('email delivery or alerts off leaves push alone', () async {
    features = const ServerFeatures(
      polling: false,
      accounts: 'local',
      telemetryRequests: false,
      alerts: true,
      alertDelivery: 'email',
    );
    await signIn();
    expect(registration.status, PushStatus.off);
    expect(push.calls, isEmpty);
  });

  test('never asks for permission on its own', () async {
    await signIn();
    expect(registration.status, PushStatus.needsPermission);
    expect(push.calls, ['available', 'permission']);
    expect(seen, isEmpty);
  });

  test('enable asks, then registers the token with the platform', () async {
    await signIn();
    await registration.enable();
    expect(push.calls, contains('request'));
    expect(registration.status, PushStatus.registered);
    final post = devices('POST').single;
    expect(jsonDecode(post.body), {
      'platform': 'android',
      'pushToken': 'tok-1',
    });
    expect(post.headers['authorization'], 'Bearer abc');
  });

  test('a refusal is remembered and nothing is sent', () async {
    await signIn();
    push.afterRequest = PushPermission.denied;
    await registration.enable();
    expect(registration.status, PushStatus.denied);
    expect(seen, isEmpty);
  });

  test('already granted registers after sign-in without asking', () async {
    push.state = PushPermission.granted;
    await signIn();
    expect(registration.status, PushStatus.registered);
    expect(push.calls, isNot(contains('request')));
    expect(devices('POST'), hasLength(1));
  });

  test('a token refresh registers the new token', () async {
    push.state = PushPermission.granted;
    await signIn();
    push.refresh.add('tok-2');
    await pump();
    final bodies = devices('POST').map((r) => jsonDecode(r.body)['pushToken']);
    expect(bodies, ['tok-1', 'tok-2']);
  });

  test('a server error while registering reads as failed', () async {
    push.state = PushPermission.granted;
    deviceStatus = 500;
    await signIn();
    expect(registration.status, PushStatus.failed);
  });

  test('no token from the plugin reads as failed and sends nothing', () async {
    push.state = PushPermission.granted;
    push.deviceToken = null;
    await signIn();
    expect(registration.status, PushStatus.failed);
    expect(seen, isEmpty);
  });

  test(
    'sign out removes the device and the token before the session',
    () async {
      push.state = PushPermission.granted;
      await signIn();
      await account.signOut();
      expect(devices('DELETE'), hasLength(1));
      expect(push.calls.last, 'deleteToken');
      final order = seen.map((r) => '${r.method} ${r.url.path}').toList();
      expect(
        order.indexOf('DELETE /api/v1/me/devices'),
        lessThan(order.indexOf('POST /api/v1/auth/logout')),
      );
      expect(registration.status, PushStatus.off);
      push.refresh.add('tok-3');
      await pump();
      expect(devices('POST'), hasLength(1));
    },
  );

  test('sign out still completes when removing the device fails', () async {
    push.state = PushPermission.granted;
    await signIn();
    deviceStatus = 500;
    await account.signOut();
    expect(await tokens.read(_base), isNull);
  });

  test('sign out with push never set up sends no device call', () async {
    push.isAvailable = false;
    await signIn();
    await account.signOut();
    expect(devices('DELETE'), isEmpty);
    expect(push.calls, isNot(contains('deleteToken')));
  });

  test('a tapped notification reports the target it names', () async {
    push.state = PushPermission.granted;
    final tapped = <String>[];
    registration.onOpened = (kind, key, id) =>
        tapped.add('$kind:$key:${id ?? '-'}');
    await signIn();
    push.taps.add({'targetKind': 'node', 'publicKey': 'aabb'});
    push.taps.add({
      'targetKind': 'node',
      'publicKey': 'aabb',
      'id': '11111111-1111-1111-1111-111111111111',
    });
    push.taps.add({'targetKind': 'node', 'publicKey': 'aabb', 'id': ''});
    push.taps.add({'other': 'x'});
    await pump();
    expect(tapped, [
      'node:aabb:-',
      'node:aabb:11111111-1111-1111-1111-111111111111',
      'node:aabb:-',
    ]);
  });

  test('the notification that launched the app is opened once', () async {
    push.state = PushPermission.granted;
    push.initial = {'targetKind': 'observer', 'publicKey': 'ccdd'};
    final tapped = <String>[];
    registration.onOpened = (kind, key, id) =>
        tapped.add('$kind:$key:${id ?? '-'}');
    await signIn();
    await registration.refresh();
    expect(tapped, ['observer:ccdd:-']);
  });
}

Future<void> pump() =>
    Future<void>.delayed(Duration.zero)
        .then((_) => Future<void>.delayed(const Duration(milliseconds: 10)));
