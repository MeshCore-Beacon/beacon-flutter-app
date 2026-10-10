import 'dart:convert';

import 'package:beacon/app.dart';
import 'package:beacon/core/api.dart';
import 'package:beacon/core/instance.dart';
import 'package:beacon/core/preferences.dart';
import 'package:beacon/core/strings.dart';
import 'package:beacon/core/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await BeaconTheme.load();
    await loadStrings();
  });

  testWidgets('Nodes to observer detail and back preserves the list', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await launch(tester);

    await tester.tap(find.text('Nodes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Node One'));
    await tester.pumpAndSettle();
    expect(find.text('node-public-key'), findsOneWidget);

    await tester.tap(find.byTooltip('Copy public key'));
    await tester.pumpAndSettle();
    expect(copied, 'node-public-key');

    await tester.tap(find.text('Observer details'));
    await tester.pumpAndSettle();
    expect(find.text('Observer One'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('node-public-key'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Node One'), findsOneWidget);
    expect(find.text('Observer details'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('More observer dashboard seeds comparison A and stacks back', (
    tester,
  ) async {
    await launch(tester);

    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Observers'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Observer One'));
    await tester.pumpAndSettle();
    expect(find.text('Observer One'), findsOneWidget);
    expect(find.text('ONLINE'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Compare observers'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Compare observers'));
    await tester.pumpAndSettle();
    expect(find.text('Observer A: 11111111'), findsOneWidget);

    await tester.tap(find.text('Observer B: Choose an observer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Observer Two'));
    await tester.pumpAndSettle();
    expect(find.text('Observer B: Observer Two'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Compare'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Flood packets heard'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Flood packets heard'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Compare observers'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Observer One'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Channels message opens its packet report and back restores list',
    (tester) async {
      final requests = await launch(tester);

      await tester.tap(find.text('Channels'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Public'));
      await tester.pumpAndSettle();
      expect(find.text('Read this message'), findsOneWidget);

      await tester.tap(find.text('1 observation'));
      await tester.pumpAndSettle();
      expect(find.text('Packet analyzer'), findsOneWidget);
      expect(
        requests.any((uri) => uri.path == '/api/v1/packets/packet-1'),
        isTrue,
      );
      final investigation = find.byKey(const ValueKey('packet-investigation'));
      await tester.ensureVisible(investigation);
      await tester.tap(investigation);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('report-91')), findsOneWidget);
      expect(find.text('Selected report'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Public'), findsOneWidget);
      expect(find.text('Read this message'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Public'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

Future<List<Uri>> launch(WidgetTester tester) async {
  final requests = <Uri>[];
  final preferences = await Preferences.load();
  await preferences.saveServer(
    BeaconInstance.create('Journey fixture', 'https://journey.test'),
  );
  await tester.pumpWidget(
    BeaconApp(
      preferences: preferences,
      connectLive: false,
      apiFactory: (base) => ApiClient(
        base,
        client: MockClient((request) async {
          requests.add(request.url);
          final path = request.url.path;
          final dynamic body = switch (path) {
            '/api/v1/scopes' || '/api/v1/brokers' => [],
            '/api/v1/nodes' => {
              'items': [
                {
                  'id': 'node-1',
                  'name': 'Node One',
                  'nodeTypeName': 'repeater',
                },
              ],
              'hasMore': false,
            },
            '/api/v1/nodes/node-1' => {
              'id': 'node-1',
              'name': 'Node One',
              'publicKey': 'node-public-key',
              'nodeTypeName': 'repeater',
              'observerId': '11111111-1111-4111-8111-111111111111',
            },
            '/api/v1/nodes/node-1/neighbors' => [],
            '/api/v1/nodes/node-1/observations' => {
              'items': [],
              'hasMore': false,
            },
            '/api/v1/observers' || '/api/v1/observers/directory' => {
              'windowStart': 1767225600000,
              'windowEnd': 1767830400000,
              'effectiveSort': 'traffic',
              'coverage': {'status': 'complete'},
              'maxObservationCount': 0,
              'items': [
                {
                  'id': '11111111-1111-4111-8111-111111111111',
                  'displayName': 'Observer One',
                  'status': 'online',
                  'observerType': 'repeater',
                  'iata': 'YVR',
                  'publicKey': 'observer-one-key',
                },
                {
                  'id': '22222222-2222-4222-8222-222222222222',
                  'displayName': 'Observer Two',
                  'status': 'online',
                  'observerType': 'repeater',
                  'iata': 'YVR',
                  'publicKey': 'observer-two-key',
                },
              ],
              'hasMore': false,
            },
            '/api/v1/observers/11111111-1111-4111-8111-111111111111' => {
              'id': '11111111-1111-4111-8111-111111111111',
              'displayName': 'Observer One',
              'status': 'online',
              'observerType': 'repeater',
              'iata': 'YVR',
              'publicKey': 'observer-one-key',
            },
            '/api/v1/observers/11111111-1111-4111-8111-111111111111/adverts' =>
              {'items': [], 'hasMore': false},
            '/api/v1/observers/11111111-1111-4111-8111-111111111111/activity' =>
              {'points': [], 'payloadTypes': []},
            '/api/v1/observers/11111111-1111-4111-8111-111111111111/telemetry' =>
              {'points': []},
            '/api/v1/channels' =>
              request.url.queryParameters['keyKnown'] == 'true'
                  ? {
                      'items': [
                        {
                          'id': 1,
                          'name': 'Public',
                          'channelHash': 'channel-hash',
                          'keyKnown': true,
                          'lastSeen': 1,
                        },
                      ],
                      'hasMore': false,
                    }
                  : {'items': [], 'hasMore': false},
            '/api/v1/channels/1' => {
              'id': 1,
              'name': 'Public',
              'channelHash': 'channel-hash',
              'keyKnown': true,
              'messageCount': 1,
            },
            '/api/v1/channels/1/messages' => {
              'items': [
                {
                  'id': 41,
                  'senderName': 'Alice',
                  'content': 'Read this message',
                  'packetHash': 'packet-1',
                  'sentAt': 1000,
                  'observationCount': 1,
                },
              ],
              'hasMore': false,
            },
            '/api/v1/packets/packet-1' => {
              'packetHash': 'packet-1',
              'header': {'payloadType': 4, 'raw': '11'},
              'observations': [
                {
                  'id': 91,
                  'observerName': 'Selected report',
                  'pathBytes': 'AA',
                  'heardAt': 1000,
                },
              ],
              'rawPayload': 'AA',
            },
            '/api/v1/stats/observer-comparison' => {
              'totalPackets': 1,
              'onlyA': 0,
              'both': 1,
              'onlyB': 0,
            },
            _ => {'items': [], 'hasMore': false, 'points': []},
          };
          return http.Response(jsonEncode(body), 200);
        }),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return requests;
}
