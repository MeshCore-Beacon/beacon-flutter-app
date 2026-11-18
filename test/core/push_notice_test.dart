import 'dart:convert';
import 'dart:io';

import 'package:beacon/core/push_notice.dart';
import 'package:flutter_test/flutter_test.dart';

/// Made by beacon-server's own code, and read by the Swift tests too.
final fixture = jsonDecode(
  File('test/fixtures/push_notice.json').readAsStringSync(),
) as Map<String, dynamic>;

void main() {
  group('alertSentence', () {
    for (final c in (fixture['sentences'] as List).cast<Map>()) {
      test('${c['kind']} ${c['value']} ${c['detail']} ${c['tempUnit']}', () {
        final notice = PushNotice.fromJson({
          'v': 1,
          'kind': c['kind'],
          'name': c['name'],
          'value': c['value'],
          'detail': c['detail'],
          'targetKind': 'node',
          'publicKey': 'aa',
          'id': '',
          'tempUnit': c['tempUnit'],
        });
        expect(alertSentence(notice!), c['want']);
      });
    }

    test('an unknown kind has no sentence', () {
      final notice = PushNotice.fromJson({'kind': 'future_kind', 'name': 'N'});
      expect(alertSentence(notice!), isNull);
    });

    test('the name is capped again, by characters', () {
      final long = '${'é' * 45}🛰️';
      final notice = PushNotice.fromJson({'kind': 'rebooted', 'name': long})!;
      expect(alertSentence(notice), '${'é' * 40} rebooted.');
    });

    test('line breaks in a name become spaces', () {
      final notice = PushNotice.fromJson({
        'kind': 'rebooted',
        'name': 'Hill\ntop\u202e',
      })!;
      expect(alertSentence(notice), 'Hill top rebooted.');
    });
  });

  group('openNotice', () {
    for (final s in (fixture['sealed'] as List).cast<Map>()) {
      test('opens ${s['pushId']}', () async {
        final notice = await openNotice(
          base64.decode(s['key'] as String),
          s['pushId'] as String,
          s['ct'] as String,
        );
        expect(notice, isNotNull);
        final plain = jsonDecode(s['plaintext'] as String) as Map;
        expect(notice!.kind, plain['kind']);
        expect(notice.publicKey, plain['publicKey']);
        expect(notice.id, plain['id']);
        expect(alertSentence(notice), s['want']);
      });
    }

    final first = (fixture['sealed'] as List).first as Map;
    final key = base64.decode(first['key'] as String);

    test('another server\'s push id does not open', () async {
      expect(await openNotice(key, 'inst_other', first['ct'] as String), null);
    });

    test('a wrong key, a changed byte or junk do not open', () async {
      final ct = base64.decode(first['ct'] as String);
      final wrong = List<int>.from(key)..[0] ^= 1;
      expect(
        await openNotice(wrong, first['pushId'] as String, first['ct']),
        isNull,
      );
      final flipped = List<int>.from(ct)..[20] ^= 1;
      expect(
        await openNotice(
          key,
          first['pushId'] as String,
          base64.encode(flipped),
        ),
        isNull,
      );
      expect(await openNotice(key, 'p', 'not base64!'), isNull);
      expect(await openNotice(key, 'p', base64.encode([1, 2, 3])), isNull);
      expect(await openNotice([1, 2], 'p', first['ct'] as String), isNull);
    });

    test('seal and open round-trip', () async {
      final ct = await sealNotice(key, 'inst_x', '{"kind":"rebooted"}');
      final notice = await openNotice(key, 'inst_x', ct);
      expect(notice!.kind, 'rebooted');
    });
  });
}
