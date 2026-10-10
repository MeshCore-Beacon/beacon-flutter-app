import 'package:beacon/features/packets/packet_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('live repeats cannot reset observation counts and normal updates deduplicate', () {
    final original = {
      'packetHash': 'a',
      'observationCount': 8,
      'lastHeardAt': 100,
      'payloadType': 4,
    };
    final repeat = {
      'packetHash': 'a',
      'packet': {'isRepeat': true, 'observationCount': 0},
      'observation': {'heardAt': 200},
    };
    expect(mergePacketEvent([original], repeat).single['observationCount'], 8);
    final update = {
      'packetHash': 'a',
      'packet': {'observationCount': 9, 'payloadType': 4},
      'observation': {
        'heardAt': 300,
        'observerId': 'o',
        'observerName': 'Observer',
        'iata': 'YOW',
      },
    };
    final result = mergePacketEvent([original], update);
    expect(result.length, 1);
    expect(result.single['observationCount'], 9);
    expect(result.single['latestObserver']['displayName'], 'Observer');
  });
  test('older page cannot replace newer live count', () {
    final result = mergePacketPages(
      [
        {'packetHash': 'a', 'lastHeardAt': 300, 'observationCount': 8},
      ],
      [
        {'packetHash': 'a', 'lastHeardAt': 100, 'observationCount': 2},
      ],
    );
    expect(result.single['observationCount'], 8);
  });
  test('payload names match numeric protocol types', () {
    expect(payloadName(4), 'ADVERT');
    expect(payloadName(5), 'GRP_TXT');
  });
}
