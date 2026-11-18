import 'dart:convert';

import 'package:beacon/core/push_display.dart';
import 'package:beacon/core/push_notice.dart';
import 'package:beacon/core/push_store.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeNotifier implements Notifier {
  final shown = <ShownNotice>[];
  @override
  Future<void> show(ShownNotice notice) async => shown.add(notice);
}

void main() {
  late MemoryPushStore store;
  late FakeNotifier notifier;
  final key = List.filled(32, 4);

  setUp(() async {
    store = MemoryPushStore();
    notifier = FakeNotifier();
    await store.write(
      PushEntry(
        pushId: 'inst_a',
        relay: Uri.parse('https://push.example'),
        handle: 'h_1',
        handleSecret: 's',
        key: base64.encode(key),
        url: 'https://a.example',
        name: 'My Ottawa',
      ),
    );
  });

  Future<Map<String, Object?>> data(
    Map<String, Object?> notice, {
    String pushId = 'inst_a',
    List<int>? withKey,
    String serverName = 'Ottawa Mesh',
  }) async => {
    'v': '1',
    'pushId': pushId,
    'serverName': serverName,
    'messageId': 'm_1',
    'ct': await sealNotice(withKey ?? key, pushId, jsonEncode(notice)),
  };

  test('shows the sentence under the stored server name', () async {
    final shown = await deliverNotice(
      await data({
        'v': 1,
        'kind': 'battery_low',
        'name': 'Ridge Rptr',
        'value': 3412,
        'targetKind': 'node',
        'publicKey': 'aabb',
        'id': 'n1',
        'tempUnit': 'c',
      }),
      store: store,
      notifier: notifier,
    );
    expect(shown, isTrue);
    final n = notifier.shown.single;
    expect(n.title, 'My Ottawa');
    expect(n.body, 'Ridge Rptr battery is low: 3.41 V.');
    expect(jsonDecode(n.payload), {
      'pushId': 'inst_a',
      'targetKind': 'node',
      'publicKey': 'aabb',
      'id': 'n1',
    });
    expect(n.id, isNonNegative);
  });

  test('without a stored name it uses the push server\'s, capped', () async {
    await store.write((await store.read('inst_a'))!.copyWith(name: ''));
    await deliverNotice(
      await data({'kind': 'rebooted', 'name': 'R'}, serverName: 'S' * 60),
      store: store,
      notifier: notifier,
    );
    expect(notifier.shown.single.title, 'S' * 40);
  });

  test('different messages get different ids', () async {
    final a = await data({'kind': 'rebooted', 'name': 'R'});
    final b = {...a, 'messageId': 'm_2'};
    await deliverNotice(a, store: store, notifier: notifier);
    await deliverNotice(b, store: store, notifier: notifier);
    expect(notifier.shown[0].id, isNot(notifier.shown[1].id));
  });

  test(
    'unknown kinds, bad keys, unknown servers and junk show nothing',
    () async {
      final cases = [
        await data({'kind': 'future_kind', 'name': 'R'}),
        await data({
          'kind': 'rebooted',
          'name': 'R',
        }, withKey: List.filled(32, 5)),
        await data({'kind': 'rebooted', 'name': 'R'}, pushId: 'inst_zz'),
        {
          ...await data({'kind': 'rebooted', 'name': 'R'}),
          'v': '2',
        },
        {
          ...await data({'kind': 'rebooted', 'name': 'R'}),
          'ct': 'zz',
        },
        {'v': '1', 'pushId': 'inst_a'},
        <String, Object?>{},
      ];
      for (final c in cases) {
        expect(
          await deliverNotice(c, store: store, notifier: notifier),
          isFalse,
        );
      }
      expect(notifier.shown, isEmpty);
    },
  );
}
