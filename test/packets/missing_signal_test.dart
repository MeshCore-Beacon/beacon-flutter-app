import 'package:beacon/core/json.dart';
import 'package:beacon/core/live.dart';
import 'package:beacon/core/theme.dart';
import 'package:beacon/features/analytics/transforms.dart';
import 'package:beacon/features/directory/observation_row.dart';
import 'package:beacon/features/packets/investigation.dart';
import 'package:beacon/features/packets/packet_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// A server may leave rssi and snr out when the observer reported none; 0 is a real reading.
void main() {
  setUp(BeaconTheme.load);

  Widget host(Widget child) => MaterialApp(
    theme: BeaconTheme.all.first.data,
    home: Scaffold(body: ListView(children: [child])),
  );

  test('a live observation keeps a zero and stays without a missing signal', () {
    final zero = decodeLiveEvent(
      '{"v":1,"type":"event","event":"packetObservation","data":'
      '{"packetHash":"aa","observation":{"observerId":"o1","rssi":0,"snr":0}}}',
    )!;
    final none = decodeLiveEvent(
      '{"v":1,"type":"event","event":"packetObservation","data":'
      '{"packetHash":"bb","observation":{"observerId":"o1"}}}',
    )!;
    final merged = mergePacketEvent(
      mergePacketEvent([], object(zero['data'])),
      object(none['data']),
    );
    expect(merged, hasLength(2));
    final seen = zero['data']['observation'] as Map;
    expect(seen['snr'], 0);
    expect(seen['rssi'], 0);
    final unseen = none['data']['observation'] as Map;
    expect(unseen.containsKey('snr'), isFalse);
    expect(unseen.containsKey('rssi'), isFalse);
  });

  testWidgets(
    'an observation row shows a dash for a missing signal and 0 for zero',
    (tester) async {
      Widget row(Map<String, dynamic> signal) => host(
        ObservationRow(
          observation: {
            'packetHash': 'aa',
            'payloadTypeName': 'ADVERT',
            ...signal,
          },
          timestamp: 'now',
          onOpen: (_, _) {},
        ),
      );
      await tester.pumpWidget(row({'rssi': 0, 'snr': 0}));
      expect(find.text('0 dBm'), findsOneWidget);
      expect(find.text('0 dB'), findsOneWidget);
      final dashes = find.text('-').evaluate().length;
      for (final missing in [
        <String, dynamic>{},
        {'rssi': null, 'snr': null},
      ]) {
        await tester.pumpWidget(row(missing));
        expect(find.text('-'), findsNWidgets(dashes + 2));
        expect(find.textContaining('dB'), findsNothing);
      }
    },
  );

  testWidgets('the analyzer shows a dash for a missing signal and 0 for zero', (
    tester,
  ) async {
    Widget analyzer(Map<String, dynamic> signal) => host(
      PacketInvestigation(
        key: ValueKey(signal.length),
        initiallyExpanded: true,
        selectedId: '1',
        detail: {
          'observations': [
            {
              'id': 1,
              'observerId': 'observer-1',
              'pathBytes': '01',
              'pathLength': {'hashSize': 1, 'hopCount': 1},
              ...signal,
            },
          ],
        },
        onSelect: (_) {},
        onOpen: (_, _) {},
      ),
    );
    await tester.pumpWidget(analyzer({}));
    await tester.pumpAndSettle();
    expect(find.text('RSSI -'), findsOneWidget);
    expect(find.text('SNR -'), findsOneWidget);
    await tester.pumpWidget(analyzer({'rssi': 0, 'snr': 0}));
    await tester.pumpAndSettle();
    expect(find.text('RSSI 0 dBm'), findsOneWidget);
    expect(find.text('SNR 0 dB'), findsOneWidget);
  });

  test(
    'an hour with no signal samples leaves a gap; a 0 dB mean is a point',
    () {
      final points = windowedPoints(
        {
          'since': 0,
          'until': 3 * 3600000,
          'hourly': [
            {'hour': 0, 'snrAverage': 0, 'snrSamples': 4},
            {'hour': 3600000, 'snrSamples': 0},
            {'hour': 7200000, 'snrAverage': null, 'snrSamples': 2},
          ],
        },
        'snrAverage',
        sampleKey: 'snrSamples',
      );
      expect(points.map((p) => p.y), [0, null, null]);
    },
  );
}
