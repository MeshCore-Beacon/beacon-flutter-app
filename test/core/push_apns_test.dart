import 'dart:async';

import 'package:beacon/core/push.dart';
import 'package:beacon/core/push_apns.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('beacon/push');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late Map<String, Object? Function()> answers;

  setUp(() {
    calls = [];
    answers = {};
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final answer = answers[call.method];
      if (answer == null) throw MissingPluginException();
      return answer();
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  /// A call from the native side, as AppDelegate.swift sends it.
  Future<void> fromNative(String method, Object? arguments) =>
      messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(MethodCall(method, arguments)),
        (_) {},
      );

  test('is iOS and available when the channel answers', () async {
    answers['permission'] = () => 'notAsked';
    final client = ApnsPushClient();
    expect(client.platform, 'ios');
    expect(await client.available(), isTrue);
  });

  test('is not available without the channel', () async {
    expect(await ApnsPushClient().available(), isFalse);
  });

  test('maps the permission answers', () async {
    final client = ApnsPushClient();
    for (final (raw, want) in [
      ('granted', PushPermission.granted),
      ('denied', PushPermission.denied),
      ('notAsked', PushPermission.notAsked),
    ]) {
      answers['permission'] = () => raw;
      answers['requestPermission'] = () => raw;
      expect(await client.permission(), want);
      expect(await client.requestPermission(), want);
    }
    expect(calls.map((c) => c.method), contains('requestPermission'));
  });

  test('token returns the hex device token', () async {
    answers['token'] = () => 'ab01ff';
    expect(await ApnsPushClient().token(), 'ab01ff');
  });

  test('a token that never comes is null', () async {
    final never = Completer<Object?>();
    answers['token'] = () => never.future;
    final client = ApnsPushClient(tokenTimeout: Duration.zero);
    expect(await client.token(), isNull);
  });

  test('a registration failure throws', () async {
    answers['token'] = () =>
        throw PlatformException(code: 'register_failed', message: 'no');
    await expectLater(
      ApnsPushClient().token(),
      throwsA(isA<PlatformException>()),
    );
  });

  test('reads the APNs environment', () async {
    answers['apnsEnvironment'] = () => 'sandbox';
    expect(await ApnsPushClient().apnsEnvironment(), 'sandbox');
  });

  test('passes on token changes', () async {
    final client = ApnsPushClient();
    final seen = <String>[];
    final sub = client.tokenRefreshes.listen(seen.add);
    await fromNative('onToken', 'cafe');
    await fromNative('onToken', '');
    await pumpEventQueue();
    expect(seen, ['cafe']);
    await sub.cancel();
  });

  test('passes on taps with the push data', () async {
    final client = ApnsPushClient();
    final seen = <Map<String, dynamic>>[];
    final sub = client.opened.listen(seen.add);
    await fromNative('onOpened', {'v': '1', 'pushId': 'inst_a', 'ct': 'x'});
    await pumpEventQueue();
    expect(seen, [
      {'v': '1', 'pushId': 'inst_a', 'ct': 'x'},
    ]);
    await sub.cancel();
  });

  test('the launch tap comes from initialMessage', () async {
    answers['initialMessage'] = () => {'pushId': 'inst_a', 'ct': 'x'};
    expect(await ApnsPushClient().initialMessage(), {
      'pushId': 'inst_a',
      'ct': 'x',
    });
    answers['initialMessage'] = () => null;
    expect(await ApnsPushClient().initialMessage(), isNull);
  });
}
