import 'package:beacon/features/packets/packet_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'complete hop parser accepts separators and uniform 1-4 byte widths',
    () {
      expect(parsePathSearch(' ABcd, 1234 → Ff00 ')?.bytes, 'abcd1234ff00');
      expect(parsePathSearch('abcd 1234')?.hashSize, 2);
      expect(parsePathSearch('')?.hashSize, 0);
      expect(parsePathSearch('a'), isNull);
      expect(parsePathSearch('aa bbbb'), isNull);
      expect(parsePathSearch('xyz'), isNull);
      expect(parsePathSearch('0011223344'), isNull);
      expect(parsePathSearch('aa ' * 400), isNull);
    },
  );
  test(
    'path match uses hop boundaries and rejects trace summaries or bad widths',
    () {
      final packet = {
        'payloadType': 4,
        'latestObserver': {
          'pathBytes': 'aabbccdd',
          'pathLength': {'hashSize': 2, 'hopCount': 2},
        },
      };
      expect(matchesPathSearch(packet, parsePathSearch('aabb ccdd')), isTrue);
      expect(matchesPathSearch(packet, parsePathSearch('bbcc')), isFalse);
      expect(matchesPathSearch(packet, parsePathSearch('aa')), isFalse);
      expect(
        matchesPathSearch({
          ...packet,
          'payloadType': 9,
        }, parsePathSearch('aabb')),
        isFalse,
      );
      expect(
        matchesPathSearch({...packet, 'payloadType': 9}, parsePathSearch('')),
        isTrue,
      );
      expect(
        matchesPathSearch({
          'latestObserver': {
            'pathBytes': 'aa',
            'pathLength': {'hashSize': 1, 'hopCount': 2},
          },
        }, parsePathSearch('aa')),
        isFalse,
      );
    },
  );
  test(
    'local filters retain observers that heard a packet before latest observer',
    () {
      final packet = {
        'packetHash': 'a',
        'payloadType': 4,
        'routeType': 1,
        'scope': '#bc',
        'latestObserver': {'id': 'new'},
      };
      expect(
        matchesPacketFilters(
          packet,
          observers: {'old'},
          observersByHash: {
            'a': {'old', 'new'},
          },
        ),
        isTrue,
      );
      expect(matchesPacketFilters(packet, observers: {'old'}), isFalse);
      expect(matchesPacketFilters(packet, scopes: {'#bc', '#west'}), isTrue);
      expect(matchesPacketFilters(packet, scopes: {'#east'}), isFalse);
      expect(matchesPacketFilters(packet, payloadTypes: {5}), isFalse);
    },
  );

  test(
    'changing server filters resets history while retaining live buffer',
    () {
      final buffer = PacketBuffer();
      buffer.addHistory([
        {'packetHash': 'old', 'lastHeardAt': 1},
      ]);
      buffer.addEvent({
        'packetHash': 'live',
        'packet': {'payloadType': 4},
        'observation': {'heardAt': 2},
      });
      buffer.clearHistory();
      expect(buffer.packets.map((e) => e['packetHash']), ['live']);
    },
  );
}
