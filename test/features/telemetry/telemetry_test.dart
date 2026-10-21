import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:beacon/features/telemetry/companion.dart';
import 'package:beacon/features/telemetry/poll_policy.dart';
import 'package:beacon/features/telemetry/sharing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'a progressing contact stream can exceed the ordinary command timeout',
    (tester) async {
      final frames = StreamController<List<int>>.broadcast(sync: true);
      final commands = <int>[];
      final radio = Companion.frames(frames.stream, (command) async {
        commands.add(command.first);
      }, () async {});
      List<CompanionContact>? contacts;
      Object? error;
      unawaited(
        radio.contacts().then(
          (value) {
            contacts = value;
          },
          onError: (Object e) {
            error = e;
          },
        ),
      );
      await tester.pump();
      frames.add([2, 4, 0, 0, 0]);
      for (var index = 0; index < 4; index++) {
        await tester.pump(const Duration(seconds: 4));
        final contact = Uint8List(148)
          ..[0] = 3
          ..[33] = 2
          ..[35] = 255;
        contact.setRange(1, 33, List.filled(32, index + 1));
        frames.add(contact);
      }
      frames.add([4, 0, 0, 0, 0]);
      await tester.pump();
      // Stream cancellation can complete on the real event loop, outside the
      // widget clock used above to advance a long, progressing transfer.
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(error, isNull);
      expect(contacts, hasLength(4));
      expect(commands, [4]); // local saved contacts only; no RF
      unawaited(radio.close());
      await tester.pump();
      await frames.close();
    },
  );
  test('TCP frames survive arbitrary fragmentation and coalescing', () {
    final decoder = CompanionFrames();
    expect(decoder.add([62, 3]), isEmpty);
    expect(decoder.add([0, 5, 9]), isEmpty);
    expect(decoder.add([8, 62, 1, 0, 0]), [
      [5, 9, 8],
      [0],
    ]);
    expect(decoder.add([62, 255, 255, 0, 62, 1, 0, 7]), [
      [7],
    ]);
    expect(() => decoder.add(List.filled(65537, 0)), throwsFormatException);
  });

  test(
    'contacts preserve full identity and zero bytes in 1/2/3-byte paths',
    () {
      for (var width = 1; width <= 3; width++) {
        final bytes = Uint8List(148)..[0] = 3;
        bytes.setRange(1, 33, List.filled(32, 0xab));
        bytes[33] = 2;
        bytes[35] = ((width - 1) << 6) | 2;
        bytes[36] = 0;
        bytes[37] = 7;
        final contact = CompanionContact.parse(bytes);
        expect(contact.key, 'ab' * 32);
        expect(contact.hops, 2);
        expect(contact.path.length, width * 2);
        expect(contact.path.first, 0);
      }
    },
  );

  test('environment channel 2 and explicit zero survive; GPS is discarded', () {
    final sample = parseTelemetry([
      1,
      116,
      1,
      144,
      2,
      103,
      0,
      0,
      2,
      104,
      126,
      2,
      115,
      38,
      152,
      9,
      136,
      ...List.filled(9, 0),
    ]);
    expect(sample.values['batteryMv'], 4000);
    expect(sample.sensors.length, 4);
    expect(sample.sensors[1], {
      'channel': 2,
      'kind': 'temperature',
      'value': 0.0,
      'unit': 'C',
    });
    expect(() => parseTelemetry([2, 103, 0]), throwsFormatException);
    expect(() => parseTelemetry([2, 104, 255]), throwsFormatException);
    expect(() => parseTelemetry([2, 199, 1]), throwsFormatException);
  });

  test(
    'persistent reservation prevents restart, interval-change and clock bypass',
    () {
      var state = <String, dynamic>{};
      final now = DateTime.utc(2026, 10, 20);
      final policy = PollPolicy(state);
      policy.reserve('radio', 'node', 6, now);
      state = jsonDecode(jsonEncode(state)) as Map<String, dynamic>;
      final restarted = PollPolicy(state);
      expect(
        restarted.blocked('radio', 'node', now.add(const Duration(hours: 1))),
        isNotNull,
      );
      expect(
        restarted.blocked(
          'radio',
          'other',
          now.subtract(const Duration(seconds: 1)),
        ),
        isNotNull,
      );
      expect(
        restarted.blocked('radio', 'node', now.add(const Duration(hours: 6))),
        isNull,
      );
      expect(
        restarted.blocked(
          'radio',
          'node',
          now.add(const Duration(hours: 6)),
          intervalHours: 72,
        ),
        isNotNull,
      );
      expect(
        () => restarted.reserve('radio', 'node', 0, now),
        throwsArgumentError,
      );
      expect(
        () => restarted.reserve('radio', 'node', 73, now),
        throwsArgumentError,
      );
    },
  );

  test('radio budget is shared across targets and server choices', () {
    final policy = PollPolicy({});
    final now = DateTime.utc(2026);
    policy.reserve('radio', 'a', 1, now);
    expect(
      policy.blocked('radio', 'b', now.add(const Duration(seconds: 10))),
      isNotNull,
    );
    policy.reserve('radio', 'b', 1, now.add(const Duration(minutes: 2)));
    expect(
      policy.blocked('radio', 'c', now.add(const Duration(minutes: 4))),
      isNotNull,
    );
    expect(
      policy.blocked('other-radio', 'c', now.add(const Duration(minutes: 4))),
      isNull,
    );
  });

  test(
    'a one-hour interval cannot starve repeaters beyond the radio budget',
    () {
      final policy = PollPolicy({});
      final now = DateTime.utc(2026);
      policy.reserve('radio', 'first', 1, now);
      policy.reserve('radio', 'second', 1, now.add(const Duration(minutes: 2)));
      expect(
        policy.nextNode(
          'radio',
          ['first', 'second', 'third'],
          1,
          now.add(const Duration(hours: 1)),
        ),
        'third',
      );
      policy.reserve('radio', 'third', 1, now.add(const Duration(hours: 1)));
      expect(
        policy.nextNode(
          'radio',
          ['first', 'second', 'third'],
          1,
          now.add(const Duration(hours: 1, minutes: 3)),
        ),
        'first',
      );
    },
  );

  test('challenge binds the selected instance, radio and client before signing', () {
    final now = DateTime.utc(2026);
    final claims = {
      'kind': 'challenge',
      'instance': 'https://example.com/beacon',
      'radioKey': 'aa' * 32,
      'collectorKey': 'bb' * 32,
      'expires': now.millisecondsSinceEpoch ~/ 1000 + 120,
      'nonce': 'test',
    };
    final token =
        '${base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '')}.mac';
    final reply = {
      'challenge': token,
      'message': 'BEACON-TELEMETRY-ENROLL-V1\n$token',
      'instance': claims['instance'],
    };
    expect(
      enrollmentMessage(
        reply,
        claims['instance'] as String,
        'aa' * 32,
        'bb' * 32,
        now,
      ),
      utf8.encode(reply['message'] as String),
    );
    expect(
      () => enrollmentMessage(
        reply,
        'https://other.example',
        'aa' * 32,
        'bb' * 32,
        now,
      ),
      throwsFormatException,
    );
  });
}
