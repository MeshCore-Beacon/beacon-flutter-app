import 'dart:async';
import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/features/packets/packet_expansion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const summary = {
  'packetHash': 'ab12',
  'firstHeardAt': 1000,
  'lastHeardAt': 1250,
  'observationCount': 1,
};
final detail = {
  'packetHash': 'ab12',
  'header': {'payloadType': 9},
  'parsedPayload': {
    'snrValues': [0],
  },
  'observations': [
    {
      'id': 42,
      'observerId': 'obs1',
      'observerName': 'Roof observer',
      'iata': 'YVR',
      'heardAt': 1250,
      'snr': 0,
      'rssi': -90,
      'propagationTimeMs': 0,
      'pathLength': {'hashSize': 1, 'hopCount': 1},
      'pathBytes': 'aa',
      'resolvedPath': [
        {
          'confidence': 'high',
          'nodes': [
            {'id': 'n1', 'name': 'Hill relay', 'publicKey': 'aa'},
          ],
        },
      ],
    },
  ],
};
Widget host(
  ApiClient api, {
  Map<String, dynamic> packet = summary,
  void Function(String, String)? onOpen,
}) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: PacketExpansion(
        api: api,
        packet: packet,
        onOpen: onOpen ?? (_, _) {},
      ),
    ),
  ),
);
void main() {
  testWidgets('fetches detail, shows timing and opens selected observation', (
    tester,
  ) async {
    final requests = <Uri>[];
    String? destination;
    final api = ApiClient(
      Uri.parse('https://test.invalid'),
      client: MockClient((r) async {
        requests.add(r.url);
        return http.Response(jsonEncode(detail), 200);
      }),
    );
    await tester.pumpWidget(
      host(api, onOpen: (kind, id) => destination = '$kind/$id'),
    );
    await tester.pumpAndSettle();
    expect(requests.single.path, '/api/v1/packets/ab12');
    expect(find.text('Spread 0.250s'), findsOneWidget);
    expect(find.text('0.00'), findsOneWidget);
    expect(find.text('Hill relay'), findsNothing);
    await tester.tap(find.byType(ActionChip));
    await tester.pumpAndSettle();
    expect(find.text('Hill relay'), findsOneWidget);
    await tester.tap(find.text('Hill relay'));
    await tester.pumpAndSettle();
    expect(destination, 'node/n1');
    await tester.tap(find.text('Roof observer'));
    expect(destination, 'packet/ab12:42');
    await tester.tap(find.text('Open analyzer'));
    expect(destination, 'packet/ab12');
    expect(tester.takeException(), isNull);
  });
  testWidgets('empty summary shows empty state while request is pending', (
    tester,
  ) async {
    final response = Completer<http.Response>();
    final api = ApiClient(
      Uri.parse('https://test.invalid'),
      client: MockClient((_) => response.future),
    );
    await tester.pumpWidget(
      host(api, packet: {...summary, 'observationCount': 0}),
    );
    await tester.pump();
    expect(find.text('No observations'), findsOneWidget);
    response.complete(http.Response('{"observations":[]}', 200));
    await tester.pumpAndSettle();
    expect(find.text('No observations'), findsOneWidget);
  });
  testWidgets('load error is retryable and unknown signal stays unknown', (
    tester,
  ) async {
    var calls = 0;
    final api = ApiClient(
      Uri.parse('https://test.invalid'),
      client: MockClient((_) async {
        calls++;
        return calls == 1
            ? http.Response(
                '{"error":{"message":"Temporarily unavailable"}}',
                500,
              )
            : http.Response(
                '{"observations":[{"id":1,"observerName":"Observer","pathLength":{"hopCount":0}}]}',
                200,
              );
      }),
    );
    await tester.pumpWidget(host(api));
    await tester.pumpAndSettle();
    expect(find.textContaining('Temporarily unavailable'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('Unknown'), findsAtLeastNWidgets(2));
  });
  testWidgets('ignores late response for replaced packet', (tester) async {
    final old = Completer<http.Response>();
    final api = ApiClient(
      Uri.parse('https://test.invalid'),
      client: MockClient(
        (r) async => r.url.path.endsWith('ab12')
            ? old.future
            : http.Response('{"observations":[]}', 200),
      ),
    );
    await tester.pumpWidget(host(api));
    await tester.pump();
    await tester.pumpWidget(
      host(api, packet: {...summary, 'packetHash': 'new'}),
    );
    await tester.pumpAndSettle();
    old.complete(http.Response(jsonEncode(detail), 200));
    await tester.pumpAndSettle();
    expect(find.text('Roof observer'), findsNothing);
    expect(find.text('No observations'), findsOneWidget);
  });

  testWidgets('narrow expansion enables path action only for located route', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final located = {
      ...detail,
      'resolvedRoute': [
        {
          'confidence': 'high',
          'nodes': [
            {'id': 'n1', 'latitude': 48.0, 'longitude': -123.0},
          ],
        },
        {
          'confidence': 'high',
          'nodes': [
            {'id': 'n2', 'latitude': 49.0, 'longitude': -124.0},
          ],
        },
      ],
    };
    final api = ApiClient(
      Uri.parse('https://test.invalid'),
      client: MockClient((_) async => http.Response(jsonEncode(located), 200)),
    );
    await tester.pumpWidget(host(api));
    await tester.pumpAndSettle();
    final button = tester.widget<OutlinedButton>(
      find.ancestor(
        of: find.text('View all paths'),
        matching: find.byType(OutlinedButton),
      ),
    );
    expect(button.onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });
}
