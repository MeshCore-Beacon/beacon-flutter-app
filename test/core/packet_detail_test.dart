import 'dart:async';
import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/features/packets/packet_detail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets(
    'packet structure uses compact metadata and hides duplicate payload data',
    (tester) async {
      final api = ApiClient(
        Uri.parse('https://example.test'),
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'header': {
                'raw': '11',
                'payloadType': 4,
                'payloadVersion': 0,
                'routeTypeName': 'FLOOD',
                'routeType': 1,
              },
              'originPubkey': 'AABB',
              'rawPayload': 'AABB',
              'parsedPayload': {'type': 'ADVERT', 'publicKey': 'AABB'},
              'observations': [
                {
                  'id': 1,
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
          home: PacketDetailScreen(api: api, hash: 'abcd', onOpen: (_, _) {}),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Origin public key'), findsNothing);
      expect(find.text('Ver 0'), findsOneWidget);
      expect(find.text('Type ADVERT (4)'), findsOneWidget);
      expect(find.text('Hash size 3B'), findsOneWidget);
      expect(find.text('Hops 0'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('PAYLOAD DATA'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      final payload = find.widgetWithText(ExpansionTile, 'PAYLOAD DATA');
      expect(tester.widget<ExpansionTile>(payload).initiallyExpanded, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      api.close();
    },
  );
  testWidgets(
    'missing requested observation never shows a different raw frame',
    (tester) async {
      final api = ApiClient(
        Uri.parse('https://example.test'),
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'packetHash': 'abcd',
              'header': {'raw': '11'},
              'observations': [
                {'id': 1, 'observerName': 'Other report'},
              ],
              'rawPayload': 'AA',
            }),
            200,
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: PacketDetailScreen(
            api: api,
            hash: 'abcd',
            initialObservationId: '99',
            onOpen: (_, _) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          'This observation is no longer retained. Select another report to inspect it.',
        ),
        findsOneWidget,
      );
      expect(find.text('RAW PACKET'), findsNothing);
    },
  );
  testWidgets('expired selection stays unavailable across repeated reloads', (
    tester,
  ) async {
    var calls = 0;
    final api = ApiClient(
      Uri.parse('https://example.test'),
      client: MockClient((_) async {
        calls++;
        return http.Response(
          jsonEncode({
            'header': {'raw': '11'},
            'observations': [
              {'id': calls == 1 ? 1 : 2, 'observerName': 'Report'},
            ],
            'rawPayload': 'AA',
          }),
          200,
        );
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PacketDetailScreen(api: api, hash: 'abcd', onOpen: (_, _) {}),
      ),
    );
    await tester.pumpAndSettle();
    for (var reload = 0; reload < 2; reload++) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(
        find.text(
          'This observation is no longer retained. Select another report to inspect it.',
        ),
        findsOneWidget,
      );
      expect(find.text('RAW PACKET'), findsNothing);
    }
  });

  testWidgets('observation link selects the requested analyzer frame', (
    tester,
  ) async {
    final api = ApiClient(
      Uri.parse('https://example.test'),
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'packetHash': 'abcd',
            'header': {'payloadType': 4, 'raw': '11'},
            'observations': [
              {'id': 1, 'observerName': 'First', 'pathBytes': 'AA'},
              {'id': 2, 'observerName': 'Second', 'pathBytes': 'BB'},
            ],
          }),
          200,
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PacketDetailScreen(
          api: api,
          hash: 'abcd',
          initialObservationId: '2',
          onOpen: (_, _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final selected = tester.widgetList<Container>(find.byType(Container)).where(
      (c) {
        final decoration = c.decoration;
        return decoration is BoxDecoration &&
            decoration.border is Border &&
            (decoration.border as Border).top.color ==
                Theme.of(tester.element(find.text('Second')))
                    .colorScheme
                    .primary;
      },
    );
    expect(selected.length, 1);
    expect(
      find.descendant(
        of: find.byWidget(selected.single),
        matching: find.text('Second'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('packet analyzer refreshes when returning to foreground', (
    tester,
  ) async {
    var calls = 0;
    final api = ApiClient(
      Uri.parse('https://example.test'),
      client: MockClient((r) async {
        calls++;
        return http.Response(
          jsonEncode({
            'packetHash': 'abcd',
            'header': {'payloadType': 4, 'raw': '11'},
            'observations': [],
            'observationCount': calls,
          }),
          200,
        );
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PacketDetailScreen(api: api, hash: 'abcd', onOpen: (_, _) {}),
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(calls, 2);
  });

  testWidgets('a slow stale load cannot overwrite a newer one', (tester) async {
    final stale = Completer<http.Response>();
    var calls = 0;
    http.Response body(int type) => http.Response(
      jsonEncode({
        'header': {'payloadType': type, 'raw': '11'},
        'observations': [],
      }),
      200,
    );
    final api = ApiClient(
      Uri.parse('https://example.test'),
      client: MockClient((r) async => ++calls == 1 ? stale.future : body(4)),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PacketDetailScreen(api: api, hash: 'abcd', onOpen: (_, _) {}),
      ),
    );
    await tester.pump();
    // A live event drops the in-flight request so the resume load can't join it.
    api.invalidateCache(prefix: '/packets/abcd');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Type ADVERT (4)'), findsOneWidget);
    stale.complete(body(2));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('Type ADVERT (4)'), findsOneWidget);
  });

  testWidgets('hex grid caps rendered bytes', (tester) async {
    final api = ApiClient(
      Uri.parse('https://example.test'),
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'header': {'payloadType': 4, 'raw': '11'},
            'rawPayload': 'AB' * 2000,
            'observations': [],
          }),
          200,
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PacketDetailScreen(api: api, hash: 'abcd', onOpen: (_, _) {}),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('more bytes'), findsOneWidget);
    expect(find.text('AB').evaluate().length, lessThanOrEqualTo(512));
  });
}
