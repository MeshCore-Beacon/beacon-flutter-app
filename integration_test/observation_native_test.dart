import 'package:beacon/core/theme.dart';
import 'package:beacon/features/analytics/charts.dart';
import 'package:beacon/features/directory/observation_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('observation rows preserve packet and observer navigation', (
    tester,
  ) async {
    await BeaconTheme.load();
    String? opened;
    final samples = [
      {
        'id': 1,
        'packetHash': 'abc',
        'payloadType': 4,
        'iata': 'YUL',
        'rssi': -123,
        'snr': -6,
        'hopCount': 0,
      },
      {
        'id': 2,
        'packetHash': 'def',
        'payloadType': 4,
        'iata': 'YGK',
        'rssi': -102,
        'snr': 5.5,
        'hopCount': 8,
      },
      {
        'id': 3,
        'packetHash': 'ghi',
        'payloadType': 4,
        'iata': 'YOW',
        'rssi': -80,
        'snr': 11.75,
        'hopCount': 7,
      },
      {
        'id': 4,
        'packetHash': 'jkl',
        'payloadType': 5,
        'iata': 'YUL',
        'rssi': -90,
        'snr': 0,
        'hopCount': 2,
        'observerId': 'obs',
        'observerName': 'Hull_Hospital',
      },
      {'id': 5, 'packetHash': 'mno', 'payloadType': 4, 'iata': 'YQB'},
    ];
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: BeaconTheme.resolve('cyberpunk'),
        home: Scaffold(
          appBar: AppBar(title: const Text('VA2SM 1W Repeater')),
          body: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              AnalyticsCard(
                title: 'Observations',
                child: Column(
                  children: [
                    for (var i = 0; i < samples.length; i++)
                      ObservationRow(
                        observation: {
                          ...samples[i],
                          'heardAt': DateTime.now()
                              .subtract(Duration(minutes: 30 + i * 12))
                              .millisecondsSinceEpoch,
                        },
                        timestamp: '2026-10-04 08:23',
                        onOpen: (kind, id) => opened = '$kind/$id',
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('0 dB'), findsOneWidget);
    expect(find.text('30m ago'), findsOneWidget);
    expect(find.text('-'), findsNWidgets(3));
    await binding.takeScreenshot('ios-observations-polished');
    await tester.tap(find.text('-123 dBm'));
    expect(opened, 'packet/abc:1');
    await tester.tap(find.text('Hull_Hospital'));
    expect(opened, 'observer/obs');
  });
}
