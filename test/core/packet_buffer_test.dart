import 'package:beacon/features/packets/packet_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('new live packets outrank future timestamps and reheard packets stay in place', () {
    final buffer = PacketBuffer();
    buffer.addHistory([
      {'packetHash': 'history', 'lastHeardAt': 9999999},
    ]);
    Map<String, dynamic> event(String hash, int time, int count) => {
      'packetHash': hash,
      'packet': {'observationCount': count},
      'observation': {'heardAt': time},
    };
    buffer.addEvent(event('future', 999999, 1));
    buffer.addEvent(event('new', 100, 1));
    buffer.addEvent(event('future', 1000000, 2));
    expect(buffer.packets.map((p) => p['packetHash']), [
      'new',
      'future',
      'history',
    ]);
    expect(buffer.packets[1]['observationCount'], 2);
    buffer.reveal([
      {'packetHash': 'pending', 'lastHeardAt': 101},
      {'packetHash': 'new', 'lastHeardAt': 102, 'observationCount': 3},
    ]);
    expect(buffer.packets.map((p) => p['packetHash']), [
      'pending',
      'new',
      'future',
      'history',
    ]);
    expect(buffer.packets[1]['observationCount'], 3);
  });

  test('live cap does not discard fetched history', () {
    final buffer = PacketBuffer();
    buffer.addHistory(
      List.generate(1100, (i) => {'packetHash': 'history$i', 'lastHeardAt': i}),
    );
    for (var i = 0; i < 600; i++) {
      buffer.addEvent({
        'packetHash': 'live$i',
        'packet': {'observationCount': 1},
        'observation': {'heardAt': 2000 + i},
      });
    }
    expect(
      buffer.packets
          .where((e) => (e['packetHash'] as String).startsWith('history'))
          .length,
      1100,
    );
    expect(buffer.packets.length, 1600);
  });
}
