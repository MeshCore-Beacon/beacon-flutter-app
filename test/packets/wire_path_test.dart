import 'package:beacon/features/packets/packet_model.dart';
import 'package:beacon/features/packets/payload_view.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const detail = {
    'header': {'raw': '26'},
    'rawPayload': '111111110000000000AABB',
  };
  test('raw TRACE frame and payload offsets use the recorded SNR bytes', () {
    const observation = {
      'pathLength': {'raw': '01'},
      'pathBytes': 'AABB',
      'wirePathBytes': '10',
    };
    expect(
      observationFrame(detail, observation),
      '260110111111110000000000AABB',
    );
    final ranges = computeFieldRanges(detail, observation);
    expect(ranges['pathData'], const PacketByteRange(2, 3));
    expect(ranges['payload'], const PacketByteRange(3, 14));
  });
  test('an explicitly empty wire path is not replaced by display hashes', () {
    const observation = {
      'pathLength': {'raw': '00'},
      'pathBytes': 'AABB',
      'wirePathBytes': '',
    };
    expect(observationFrame(detail, observation), '2600111111110000000000AABB');
    expect(computeFieldRanges(detail, observation)['pathData'], isNull);
    expect(
      computeFieldRanges(detail, observation)['payload'],
      const PacketByteRange(2, 13),
    );
  });
  test('older servers retain their pathBytes fallback', () {
    const observation = {
      'pathLength': {'raw': '02'},
      'pathBytes': 'AABB',
    };
    expect(
      observationFrame(detail, observation),
      '2602AABB111111110000000000AABB',
    );
    expect(
      computeFieldRanges(detail, observation)['pathData'],
      const PacketByteRange(2, 4),
    );
  });
}
