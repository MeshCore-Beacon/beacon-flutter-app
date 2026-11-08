import 'package:beacon/features/telemetry/poll_permit.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 11, 8);
  final request = <String, dynamic>{
    'instance': 'https://beacon.example',
    'requestId': 'request',
    'nodeKey': 'node',
    'radioKey': 'radio',
    'collectorKey': 'client',
    'intervalHours': 72,
    'commandBudget': 3,
    'routeMode': 'nearby',
  };
  Map<String, dynamic> reply() => {
    ...request,
    'allowed': true,
    'issuedAt': now.millisecondsSinceEpoch,
    'expiresAt': now.add(const Duration(minutes: 5)).millisecondsSinceEpoch,
    'nextAllowedAt': now.add(const Duration(hours: 72)).millisecondsSinceEpoch,
  };
  test('permit preserves the requested 72-hour cooldown', () {
    final permit = PollPermit.parse(reply(), request, now)!;
    expect(permit.id, 'request');
    expect(
      () => permit.check(now.add(const Duration(minutes: 5))),
      throwsStateError,
    );
  });
  test(
    'rejects wrong identity, instance, interval, expired and unbounded replies',
    () {
      for (final change in <String, dynamic>{
        'nodeKey': 'wrong',
        'radioKey': 'wrong',
        'collectorKey': 'wrong',
        'instance': 'https://other.example',
        'requestId': 'wrong',
        'routeMode': 'discovery',
        'intervalHours': 1,
        'expiresAt': now.millisecondsSinceEpoch,
        'nextAllowedAt': now
            .add(const Duration(minutes: 5))
            .millisecondsSinceEpoch,
        'issuedAt': now.add(const Duration(minutes: 1)).millisecondsSinceEpoch,
        'allowed': null,
      }.entries) {
        expect(
          () => PollPermit.parse(
            {...reply(), change.key: change.value},
            request,
            now,
          ),
          throwsFormatException,
          reason: change.key,
        );
      }
    },
  );
  test('standby never yields permission and requires bounded retry', () {
    expect(
      PollPermit.parse(
        {...request, 'allowed': false, 'retryAfterSeconds': 60},
        request,
        now,
      ),
      isNull,
    );
    expect(
      () => PollPermit.parse(
        {...request, 'allowed': false, 'retryAfterSeconds': 0},
        request,
        now,
      ),
      throwsFormatException,
    );
  });
  test(
    'nearby routes preserve 1/2/3-byte widths and reject visible collisions',
    () {
      expect(nearbyRouteIsUnambiguous(null, [], 'target', []), false);
      expect(nearbyRouteIsUnambiguous(0, [], 'target', []), true);
      expect(
        nearbyRouteIsUnambiguous(1, [0xab], 'target', ['ab12', 'ab34']),
        false,
      );
      expect(
        nearbyRouteIsUnambiguous(
          1,
          [0xab, 0x12],
          'target',
          ['ab1234', 'ab3456'],
        ),
        true,
      );
      expect(
        nearbyRouteIsUnambiguous(1, [0xab, 0x12, 0x34], 'target', ['ab123456']),
        true,
      );
      expect(nearbyRouteIsUnambiguous(1, [0xab], 'ab1234', ['ab1234']), false);
      expect(
        nearbyRouteIsUnambiguous(
          2,
          [0xab, 0xcd],
          'target',
          ['ab1234', 'cd1234'],
        ),
        false,
      );
    },
  );
}
