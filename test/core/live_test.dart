import 'package:beacon/core/live.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('versioned event envelope unwraps and ignores invalid messages', () {
    expect(
      decodeLiveEvent(
        '{"v":1,"type":"event","event":"nodeUpdate","data":{"nodeId":"abc"}}',
      )?['event'],
      'nodeUpdate',
    );
    expect(
      decodeLiveEvent('{"v":2,"type":"event","event":"nodeUpdate","data":{}}'),
      isNull,
    );
    expect(decodeLiveEvent('broken'), isNull);
    expect(decodeLiveEvent('{"v":1,"type":"hello"}'), isNull);
  });
}
