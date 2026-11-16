import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/features/directory/directory.dart';
import 'package:beacon/features/packets/packet_detail.dart';
import 'package:beacon/features/packets/trace_quality.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const suspect = {
  'status': 'suspect',
  'reasons': ['too_many_hops'],
};
const ambiguous = {
  'status': 'ambiguous',
  'reasons': ['ambiguous_prefix'],
};

void main() {
  testWidgets(
    'older servers and supported records gain no authenticity badge',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                TraceQualityNotice(quality: null),
                TraceQualityNotice(quality: {'status': 'supported'}),
              ],
            ),
          ),
        ),
      );
      expect(find.byType(Text), findsNothing);
    },
  );
  testWidgets(
    'ambiguous metadata explains uncertainty rather than proving a collision',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: TraceQualityNotice(quality: ambiguous)),
        ),
      );
      expect(find.text('Possible prefix collision'), findsOneWidget);
      expect(find.text('A hop matches multiple known nodes'), findsOneWidget);
      expect(
        find.textContaining('does not establish a real route'),
        findsOneWidget,
      );
    },
  );
  testWidgets(
    'trace directory marks suspect rows without dropping raw or older-server rows',
    (tester) async {
      final api = ApiClient(
        Uri.parse('https://test.invalid'),
        client: MockClient(
          (request) async => http.Response(
            jsonEncode(
              request.url.path.endsWith('/traces')
                  ? {
                      'items': [
                        {
                          'traceTag': '11111111',
                          'traceType': 'TRACE',
                          'pathHashes': ['AA'],
                          'quality': suspect,
                        },
                        {
                          'traceTag': '22222222',
                          'traceType': 'TRACE',
                          'pathHashes': ['BB'],
                        },
                      ],
                      'hasMore': false,
                    }
                  : [],
            ),
            200,
          ),
        ),
      );
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DirectoryScreen(
              kind: 'traces',
              api: api,
              region: const {},
              onOpen: (_, _) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Suspect observation'), findsOneWidget);
      expect(find.text('11111111'), findsOneWidget);
      expect(find.text('22222222'), findsOneWidget);
      expect(find.text('AA'), findsOneWidget);
      expect(find.text('BB'), findsOneWidget);
    },
  );
  testWidgets(
    'trace packet detail retains its path with a quality explanation',
    (tester) async {
      final api = ApiClient(
        Uri.parse('https://test.invalid'),
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'traceTag': '11111111',
              'packets': [
                {
                  'packetHash': 'abcd',
                  'routeTypeName': 'DIRECT',
                  'quality': suspect,
                  'rawPath': [
                    {'hash': 'AA'},
                  ],
                  'resolvedRoute': [],
                },
              ],
            }),
            200,
          ),
        ),
      );
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: EntityDetailScreen(
            kind: 'trace',
            id: '11111111',
            api: api,
            region: const {},
            onOpen: (_, _) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Suspect observation'), findsOneWidget);
      expect(
        find.text('Route exceeds the supported trace hop count'),
        findsOneWidget,
      );
      expect(find.textContaining('Raw evidence is retained'), findsOneWidget);
    },
  );
  testWidgets(
    'analyzer uses the selected observation quality over the packet summary',
    (tester) async {
      final api = ApiClient(
        Uri.parse('https://test.invalid'),
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'packetHash': 'abcd',
              'header': {'payloadType': 9},
              'traceQuality': {'status': 'supported'},
              'observations': [
                {
                  'id': 1,
                  'observerId': 'observer',
                  'traceQuality': ambiguous,
                  'pathLength': {'raw': '00', 'hashSize': 1, 'hopCount': 0},
                },
              ],
            }),
            200,
          ),
        ),
      );
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: PacketDetailScreen(hash: 'abcd', api: api, onOpen: (_, _) {}),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Possible prefix collision'), findsOneWidget);
      expect(find.textContaining('Raw evidence is retained'), findsOneWidget);
    },
  );
}
