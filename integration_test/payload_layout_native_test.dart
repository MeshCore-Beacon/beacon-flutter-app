import 'dart:convert';
import 'dart:io';

import 'package:beacon/core/api.dart';
import 'package:beacon/core/strings.dart';
import 'package:beacon/core/theme.dart';
import 'package:beacon/features/packets/packet_detail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('compact advert structure and payload on a phone', (
    tester,
  ) async {
    await Future.wait([BeaconTheme.load(), loadStrings()]);
    final publicKey = '3A79${'00' * 30}';
    final signature = '1BAA${'BB' * 62}';
    final api = ApiClient(
      Uri.parse('https://example.test'),
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'header': {
              'raw': '11',
              'payloadType': 4,
              'payloadVersion': 0,
              'routeType': 1,
              'routeTypeName': 'FLOOD',
            },
            'originPubkey': publicKey,
            'rawPayload':
                '$publicKey${'00' * 4}${signature}92${'00' * 8}54657374',
            'parsedPayload': {
              'type': 'ADVERT',
              'publicKey': publicKey,
              'signature': signature,
              'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000 - 420,
              'appData': {
                'name': 'Test repeater',
                'latitude': 45.40032,
                'longitude': -73.5068,
                'flags': {
                  'raw': '92',
                  'deviceRoleName': 'REPEATER',
                  'deviceRole': 2,
                  'hasName': true,
                  'hasLocation': true,
                  'hasFeature1': false,
                  'hasFeature2': false,
                },
              },
            },
            'observations': [
              {
                'id': 1,
                'observerId': 'test',
                'observerName': 'Test observer',
                'pathBytes': '',
                'pathLength': {'raw': '80', 'hashSize': 3, 'hopCount': 0},
              },
            ],
          }),
          200,
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: BeaconTheme.resolve('neutral-blue'),
        home: PacketDetailScreen(
          api: api,
          hash: '6A82B1184D3B0E76',
          onOpen: (_, _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (Platform.isAndroid) {
      await binding.convertFlutterSurfaceToImage();
      await tester.pump();
    }
    await tester.scrollUntilVisible(
      find.text('PAYLOAD BREAKDOWN'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await binding.takeScreenshot(
      '${Platform.operatingSystem}-advert-payload-layout',
    );
    expect(find.text('Has Name'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    api.close();
  });
}
