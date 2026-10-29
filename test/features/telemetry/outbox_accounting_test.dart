import 'package:beacon/features/telemetry/sharing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('expired saved reports remain distinct from accepted delivery', () {
    final now = DateTime.utc(2026, 10, 21);
    final state = <String, dynamic>{
      'outbox': [
        {'at': now.subtract(const Duration(hours: 25)).millisecondsSinceEpoch},
        {'at': now.subtract(const Duration(hours: 24)).millisecondsSinceEpoch},
        {'at': now.millisecondsSinceEpoch},
      ],
      'expiredReports': 2,
    };
    expect(expireSavedReports(state, now), 1);
    expect(state['expiredReports'], 3);
    expect(state['outbox'], hasLength(2));
    expect(expireSavedReports(state, now), 0);
    expect(state['expiredReports'], 3);
    expect(state.containsKey('accepted'), isFalse);
  });
}
