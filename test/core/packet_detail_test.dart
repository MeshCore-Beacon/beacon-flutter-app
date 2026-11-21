import 'dart:async';
import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/features/packets/packet_detail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  analyzerLayoutTests();
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
      // Sections are the node page's cards: a blue title in a bordered box.
      final summary = tester.widget<Text>(find.text('SUMMARY'));
      expect(
        summary.style?.color,
        Theme.of(tester.element(find.text('SUMMARY'))).colorScheme.primary,
      );
      expect(summary.style?.fontSize, 10);
      expect(find.byTooltip('Copy link'), findsOneWidget);
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

void analyzerLayoutTests() {
  testWidgets('an advert offers its sender as a button, not a decoded row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    String? opened;
    final api = ApiClient(
      Uri.parse('https://example.test'),
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'header': {'raw': '12', 'payloadType': 4, 'routeType': 2},
            'rawPayload': 'AABB',
            'parsedPayload': {'type': 'ADVERT', 'publicKey': 'AABB'},
            'observations': [
              {
                'id': 1,
                'pathBytes': '',
                'pathLength': {'raw': '00', 'hashSize': 1, 'hopCount': 0},
                'resolvedSource': {
                  'confidence': 'high',
                  'nodes': [
                    {'id': 'node-1', 'name': 'Pleb', 'publicKey': 'AABB'},
                  ],
                },
              },
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
          onOpen: (kind, id) => opened = '$kind/$id',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('From '), findsNothing);
    await tester.tap(find.text('View node'));
    expect(opened, 'node/node-1');
    // It sits in Summary, above the decoded sections.
    expect(
      tester.getTopLeft(find.text('View node')).dy,
      lessThan(tester.getTopLeft(find.text('RAW PACKET')).dy),
    );
    await tester.pumpWidget(const SizedBox());
    api.close();
  });

  testWidgets('decoded sections follow the frame and share its byte colours', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = ApiClient(
      Uri.parse('https://example.test'),
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'header': {
              'raw': '06',
              'payloadType': 1,
              'payloadVersion': 0,
              'routeTypeName': 'DIRECT',
              'routeType': 2,
            },
            'rawPayload': 'C3C83D1FD0EA',
            'parsedPayload': {
              'type': 'RESPONSE',
              'destinationHash': 'C3',
              'sourceHash': 'C8',
              'cipherMac': '3D1F',
              'ciphertext': 'D0EA',
            },
            'observations': [
              {
                'id': 1,
                'pathBytes': 'AA',
                'pathLength': {'raw': '01', 'hashSize': 1, 'hopCount': 1},
                'resolvedSource': {'confidence': 'none', 'nodes': <Object>[]},
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
    // From and To are in the payload breakdown, so no section repeats them.
    expect(find.text('ENDPOINTS'), findsNothing);
    expect(find.text('From '), findsOneWidget);
    // Path follows the structure, as its bytes follow the header.
    expect(
      tester.getTopLeft(find.text('PATH')).dy,
      greaterThan(tester.getTopLeft(find.text('PACKET STRUCTURE')).dy),
    );
    expect(
      tester.getTopLeft(find.text('PATH')).dy,
      lessThan(tester.getTopLeft(find.text('PAYLOAD BREAKDOWN')).dy),
    );
    // The raw packet comes first, so a repeated hash finds its raw byte.
    Color? of(String text) =>
        tester.widget<Text>(find.text(text).first).style?.color;
    // Raw bytes: header 06, path length 01, path AA, then the payload.
    expect(of('HEADER BYTE'), of('06'));
    expect(of('PATH LENGTH'), of('01'));
    expect(of('MAC'), of('3D'));
    expect(of('Ciphertext'), of('D0'));
    expect(of('From '), of('C8'));
    expect(of('To '), of('C3'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    api.close();
  });
}
