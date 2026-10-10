import 'dart:convert';
import 'dart:io';

import 'package:beacon/core/api.dart';
import 'package:beacon/core/strings.dart';
import 'package:beacon/core/theme.dart';
import 'package:beacon/features/directory/directory.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';

import '../test/directory/observer_info_test.dart' show observerFixture;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('compact observer summary and readable telemetry on phone', (
    tester,
  ) async {
    await Future.wait([BeaconTheme.load(), loadStrings()]);
    final now = DateTime.now().millisecondsSinceEpoch;
    final api = ApiClient(
      Uri.parse('https://example.test'),
      client: MockClient(
        (request) async => http.Response(
          jsonEncode(
            request.url.path.endsWith('/activity')
                ? {
                    'windowStart': now - 86400000,
                    'windowEnd': now,
                    'points': [
                      for (var i = 0; i < 96; i++)
                        {
                          't': now - 86400000 + i * 900000,
                          'observations': (i * 17 % 69) + 1,
                        },
                    ],
                    'payloadTypes': [
                      {'payloadTypeName': 'group_text', 'count': 474},
                      {'payloadTypeName': 'advert', 'count': 324},
                    ],
                  }
                : request.url.path.endsWith('/test-observer')
                ? {
                    ...observerFixture,
                    'lastSeen': now - 120000,
                    'firstSeen': now - 3 * 86400000,
                    'brokers': [
                      {
                        'name': 'mqtt1',
                        'lastSeenAt': now - 120000,
                        'lastPacketAt': now - 120000,
                      },
                      {
                        'name': 'mqtt2',
                        'lastSeenAt': now - 60000,
                        'lastPacketAt': now - 60000,
                      },
                    ],
                  }
                : {'items': []},
          ),
          200,
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: BeaconTheme.resolve('neutral-blue'),
        home: EntityDetailScreen(
          api: api,
          kind: 'observer',
          id: 'test-observer',
          region: const {},
          onOpen: (_, _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (Platform.isAndroid) {
      await binding.convertFlutterSurfaceToImage();
      await tester.pump();
    }
    await binding.takeScreenshot('${Platform.operatingSystem}-observer-info');
    await tester.scrollUntilVisible(
      find.text('PACKETS HEARD PER 15M'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await binding.takeScreenshot(
      '${Platform.operatingSystem}-observer-activity',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    api.close();
  });
}
