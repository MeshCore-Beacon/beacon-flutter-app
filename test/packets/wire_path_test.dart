import 'package:beacon/features/packets/packet_model.dart';
import 'package:beacon/features/packets/path_hop.dart';
import 'package:beacon/features/packets/payload_view.dart';
import 'package:flutter/material.dart';
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

  // On air: 26 02 28F4 11223344 00000000 00 A1B2C3, a 3-hop trace heard after 2 hops.
  const trace = {
    'header': {'raw': '26', 'payloadType': 9},
    'rawPayload': '112233440000000000A1B2C3',
    'parsedPayload': {'traceTag': '11223344'},
  };
  const heard = {
    'pathLength': {'raw': '02', 'hashSize': 1, 'hopCount': 3},
    'pathBytes': 'A1B2C3',
    'wirePathBytes': '28F4',
  };
  test('a trace frame is the 16 bytes sent, with highlights in place', () {
    final frame = observationFrame(trace, heard);
    expect(frame, '260228F4112233440000000000A1B2C3');
    expect(frame.length, 32);
    final ranges = computeFieldRanges(trace, heard);
    String bytes(String field) =>
        frame.substring(ranges[field]!.start * 2, ranges[field]!.end * 2);
    expect(bytes('header'), '26');
    expect(bytes('pathLength'), '02');
    expect(bytes('pathData'), '28F4');
    expect(bytes('payload'), '112233440000000000A1B2C3');
    expect(bytes('traceTag'), '11223344');
    expect(bytes('tracePath'), 'A1B2C3');
  });
  test('a trace heard before any hop has no path bytes in its frame', () {
    final unheard = {...heard, 'wirePathBytes': ''}
      ..['pathLength'] = {'raw': '00', 'hashSize': 1, 'hopCount': 3};
    expect(observationFrame(trace, unheard), '2600112233440000000000A1B2C3');
    final ranges = computeFieldRanges(trace, unheard);
    expect(ranges['pathData'], isNull);
    expect(ranges['payload'], const PacketByteRange(2, 14));
    expect(ranges['traceTag'], const PacketByteRange(2, 6));
  });
  test('a null wire path falls back to pathBytes like a missing one', () {
    const observation = {
      'pathLength': {'raw': '02'},
      'pathBytes': 'AABB',
      'wirePathBytes': null,
    };
    expect(observationWirePath(observation), 'AABB');
  });
  testWidgets('the hop chips still show the trace hashes', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PacketPathHops(observation: heard, onOpen: (_, _) {}),
        ),
      ),
    );
    for (final hop in ['A1', 'B2', 'C3']) {
      expect(find.text(hop), findsOneWidget);
    }
    expect(find.text('28'), findsNothing);
    expect(find.text('F4'), findsNothing);
  });
}
