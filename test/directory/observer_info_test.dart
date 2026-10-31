import 'package:beacon/features/directory/observer_info.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const observerFixture = <String, dynamic>{
  'id': 'test-observer',
  'displayName': 'Hull_Hospital',
  'status': 'online',
  'iata': 'YOW',
  'observerType': 'meshcoretomqtt/1.1.0.0-622ce04',
  'softwareVersion': 'meshcoretomqtt/1.1.0.0-622ce04',
  'hardwareModel': 'Ikoka Stick-E22-30dBm (Xiao_nrf52)',
  'firmwareVersion': 'v1.17.1-4ccbf889 (Build: 26-Sep-2026)',
  'firmwareBuild': '',
  'publicKey':
      '4f5d8215ba9d2c50491b12254ef7cd6e0ed7cf75f4177627264aab287fd7e751',
  'radioFreqMhz': 910.525,
  'radioBwKhz': 62.5,
  'radioSf': 7,
  'radioCr': 5,
  'batteryLevel': 4.405,
  'uptimeSeconds': 725449,
  'observationCount': 19587,
  'statusMetadata': {
    'stats': {'noise_floor': -112.5},
  },
  'firstSeen': 1790969280000,
  'lastSeen': 1791109800000,
  'scopes': ['#can', '#onqc', '#yow'],
  'brokers': [
    {
      'name': 'mqtt1',
      'lastSeenAt': 1791109800000,
      'lastPacketAt': 1791109800000,
    },
    {
      'name': 'mqtt2',
      'lastSeenAt': 1791109800000,
      'lastPacketAt': 1791109800000,
    },
  ],
};
void main() {
  test('counts use the language\'s digit grouping', () {
    expect(groupedCount(316959), '316,959');
  });
  test('observer uptime is readable in days hours and minutes', () {
    expect(observerUptime(725449), '8d 9h 30m');
    expect(observerUptime(59), '0m');
  });
  testWidgets(
    'compact observer info keeps full identity accessible on a phone',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: ObserverInfo(
                  data: observerFixture,
                  summary: {
                    'recordedPackets': 316959,
                    'lastCompleteHour': 1204,
                  },
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('316,959'), findsOneWidget);
      expect(find.text('1,204'), findsOneWidget);
      expect(find.text('-112.5 dBm'), findsOneWidget);
      expect(find.text('LAST PACKET'), findsOneWidget);
      expect(find.text('4.41 V'), findsOneWidget);
      expect(find.text('8d 9h 30m'), findsOneWidget);
      expect(find.text('meshcoretomqtt/1.1.0.0-622ce04'), findsOneWidget);
      expect(find.textContaining('CR 4/5'), findsOneWidget);
      expect(find.text('Build'), findsNothing);
      await tester.tap(find.text('4f5d8215…fd7e751'));
      await tester.pumpAndSettle();
      expect(
        find.text(observerFixture['publicKey']! as String),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
