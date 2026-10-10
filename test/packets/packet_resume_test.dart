import 'dart:async';
import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/features/packets/packet_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets(
    'full-width rows and banner resume live feed from older packets',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final events = StreamController<Map<String, dynamic>>.broadcast();
      final api = ApiClient(
        Uri.parse('https://example.test'),
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'items': List.generate(
                60,
                (i) => {
                  'packetHash': i.toRadixString(16).padLeft(8, '0'),
                  'payloadType': 4,
                  'lastHeardAt': 100 - i,
                },
              ),
              'hasMore': false,
            }),
            200,
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PacketScreen(
              api: api,
              region: const {},
              events: events.stream,
              onOpen: (_, _) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final row = tester.getRect(find.byType(Card).first);
      expect(row.left, 0);
      expect(row.right, 390);
      final list = find.byType(ListView);
      await tester.drag(list, const Offset(0, -500));
      await tester.pumpAndSettle();
      final scroll = tester.widget<ListView>(list).controller!;
      expect(scroll.offset, greaterThan(100));
      void receive(String hash, int time) => events.add({
        'event': 'packetObservation',
        'data': {
          'packetHash': hash,
          'packet': {'payloadType': 4},
          'observation': {'heardAt': time, 'observerId': 'observer'},
        },
      });
      receive('aabbccdd', 200);
      await tester.pumpAndSettle();
      expect(find.text('1 new packet'), findsOneWidget);
      final banner = tester.getRect(
        find.widgetWithText(TextButton, '1 new packet'),
      );
      expect(banner.left, 0);
      expect(banner.right, 390);
      await tester.tapAt(Offset(8, banner.center.dy));
      receive('eeff0011', 201);
      await tester.pumpAndSettle();
      expect(scroll.offset, 0);
      expect(find.text('AABBCCDD'), findsOneWidget);
      expect(find.text('EEFF0011'), findsOneWidget);
      expect(find.text('1 new packet'), findsNothing);
      receive('aabbccdd', 202);
      await tester.pumpAndSettle();
      expect(find.text('AABBCCDD'), findsOneWidget);
      expect(find.text('1 new packet'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await events.close();
      api.close();
    },
  );
}
