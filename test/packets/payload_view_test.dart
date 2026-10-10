import 'package:beacon/core/json.dart';
import 'package:beacon/features/packets/payload_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('direct encrypted payload byte ranges follow source, destination, MAC, ciphertext', () {
    final ranges = computeFieldRanges(
      {
        'header': {'raw': '01', 'payloadType': 4},
        'rawPayload': 'aabbccddeeff',
        'parsedPayload': {
          'type': 'TEXT_MESSAGE',
          'destinationHash': 'aa',
          'sourceHash': 'bb',
          'cipherMac': 'ccdd',
          'ciphertext': 'eeff',
        },
      },
      {
        'pathLength': {'raw': '00'},
        'pathBytes': '',
      },
    );

    expect(ranges['destinationHash'], const PacketByteRange(2, 3));
    expect(ranges['sourceHash'], const PacketByteRange(3, 4));
    expect(ranges['cipherMac'], const PacketByteRange(4, 6));
    expect(ranges['ciphertext'], const PacketByteRange(6, 8));
  });

  test('advert byte ranges honor flags and nested app data', () {
    final ranges = computeFieldRanges(
      {
        'header': {'raw': '01', 'payloadType': 4},
        // key(1), timestamp(4), signature(2), flags(1), location(8), feature1(2), name(2)
        'rawPayload':
            'aa00000000bbbbbf'
            '0000000000000000'
            'ccdd'
            'eeff',
        'parsedPayload': {
          'publicKey': 'aa',
          'timestamp': 0,
          'signature': 'bbbb',
          'appData': {
            'flags': {'raw': '00'},
          },
        },
      },
      {
        'pathLength': {'raw': '00'},
        'pathBytes': '',
      },
    );

    expect(ranges['publicKey'], const PacketByteRange(2, 3));
    expect(ranges['advertTimestamp'], const PacketByteRange(3, 7));
    expect(ranges['signature'], const PacketByteRange(7, 9));
    expect(ranges['flags'], const PacketByteRange(9, 10));
    expect(ranges['location'], const PacketByteRange(10, 18));
    expect(ranges['advertName'], const PacketByteRange(20, 22));
  });

  test('trace byte ranges split tag, auth code, flags, and embedded path', () {
    final ranges = computeFieldRanges(
      {
        'header': {'raw': '01', 'payloadType': 9},
        'rawPayload': '0102030405060708090a0b',
        'parsedPayload': {
          'type': 'TRACE',
          'traceTag': '01020304',
          'authCode': 0x05060708,
          'flags': 9,
          'pathHashes': ['0a', '0b'],
        },
      },
      {
        'pathLength': {'raw': '00'},
        'pathBytes': '',
      },
    );

    expect(ranges['traceTag'], const PacketByteRange(2, 6));
    expect(ranges['authCode'], const PacketByteRange(6, 10));
    expect(ranges['flags'], const PacketByteRange(10, 11));
    expect(ranges['tracePath'], const PacketByteRange(11, 13));
  });

  test('malformed raw advert flags do not invent optional field ranges', () {
    final ranges = computeFieldRanges(
      {
        'header': {'raw': '01', 'payloadType': 4},
        'rawPayload':
            'aa00000000bbbbzz'
            '0000000000000000'
            'ccdd',
        'parsedPayload': {
          'publicKey': 'aa',
          'signature': 'bbbb',
          'appData': {
            'flags': {'raw': 'ff'},
          },
        },
      },
      {
        'pathLength': {'raw': '00'},
        'pathBytes': '',
      },
    );

    expect(ranges['flags'], const PacketByteRange(9, 10));
    expect(ranges.containsKey('location'), isFalse);
    expect(ranges.containsKey('advertName'), isFalse);
  });

  test('unclassified payload bytes retain a whole-payload fallback range', () {
    final ranges = computeFieldRanges(
      {
        'header': {'raw': '01', 'payloadType': 99},
        'rawPayload': 'aabbcc',
        'parsedPayload': {'type': 'FUTURE_TYPE'},
      },
      {
        'pathLength': {'raw': '00'},
        'pathBytes': '',
      },
    );

    expect(ranges['payload'], const PacketByteRange(2, 5));
    expect(ranges.containsKey('traceTag'), isFalse);
  });

  test(
    'parsed ADVERT label cannot replace missing numeric header discriminator',
    () {
      final ranges = computeFieldRanges(
        {
          'header': {'raw': '01'},
          'rawPayload': 'aabbccdd',
          'parsedPayload': {'type': 'ADVERT', 'publicKey': 'aa'},
        },
        {
          'pathLength': {'raw': '00'},
          'pathBytes': '',
        },
      );

      expect(ranges['payload'], const PacketByteRange(2, 6));
      expect(ranges.containsKey('publicKey'), isFalse);
    },
  );

  test('raw payload retains fallback range when parsed payload is absent', () {
    final ranges = computeFieldRanges(
      {
        'header': {'raw': '01'},
        'rawPayload': 'aabb',
      },
      {
        'pathLength': {'raw': '00'},
        'pathBytes': '',
      },
    );

    expect(ranges['payload'], const PacketByteRange(2, 4));
  });

  testWidgets('renders encrypted and decrypted group message states', (
    tester,
  ) async {
    Json detail = {
      'parsedPayload': {
        'type': 'GROUP_TEXT',
        'channelHash': 'aa',
        'cipherMac': 'bbcc',
        'ciphertext': 'ddeeff',
        'decrypted': null,
      },
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PacketPayloadView(
            detail: detail,
            observation: {},
            onOpen: (_, _) {},
          ),
        ),
      ),
    );
    expect(find.text('Encrypted'), findsOneWidget);
    expect(find.text('Channel'), findsOneWidget);
    expect(find.text('Ciphertext'), findsOneWidget);

    detail = {
      'parsedPayload': {
        'type': 'GROUP_TEXT',
        'channelHash': 'aa',
        'decrypted': {'sender': 'Riley', 'content': 'hello mesh'},
      },
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PacketPayloadView(
            detail: detail,
            observation: {},
            onOpen: (_, _) {},
          ),
        ),
      ),
    );
    expect(find.text('Decrypted'), findsOneWidget);
    expect(find.text('hello mesh'), findsOneWidget);
    expect(find.text('Encrypted'), findsNothing);
  });

  testWidgets('advert uses compact fields and keeps long values accessible', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final publicKey = List.filled(32, 'ab').join();
    final signature = List.filled(64, 'cd').join();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PacketPayloadView(
            detail: {
              'parsedPayload': {
                'type': 'ADVERT',
                'publicKey': publicKey,
                'timestamp': 1700000000,
                'signature': signature,
                'appData': {
                  'name': 'Relay One',
                  'latitude': 45.5,
                  'longitude': -73.5,
                  'flags': {'raw': 'b2', 'hasLocation': true},
                },
              },
            },
            observation: {},
            onOpen: (_, _) {},
          ),
        ),
      ),
    );
    expect(find.textContaining('Relay One'), findsOneWidget);
    expect(find.textContaining('45.500000, -73.500000'), findsOneWidget);
    expect(find.text('Signature'), findsOneWidget);
    expect(find.textContaining('Role Repeater'), findsOneWidget);
    expect(find.textContaining('(4B LE)'), findsOneWidget);
    expect(find.text('Device role'), findsNothing);
    expect(find.text('Has location'), findsNothing);
    expect(find.textContaining('65 6C 61 79'), findsNothing);
    expect(find.textContaining('…'), findsNWidgets(2));
    await tester.tap(find.textContaining('…').first);
    await tester.pumpAndSettle();
    expect(find.text(publicKey.toUpperCase()), findsOneWidget);
    expect(find.byType(SelectableText), findsWidgets);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('…').last);
    await tester.pumpAndSettle();
    expect(find.text(signature.toUpperCase()), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('0010'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('resolved direct endpoint opens the matching node', (
    tester,
  ) async {
    String? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PacketPayloadView(
            detail: {
              'parsedPayload': {
                'type': 'TEXT_MESSAGE',
                'destinationHash': 'aa',
                'sourceHash': 'bb',
                'decrypted': {'message': 'hello'},
              },
            },
            observation: {
              'resolvedDestination': {
                'confidence': 'high',
                'nodes': [
                  {'id': 'node-1', 'name': 'Hill Relay'},
                ],
              },
            },
            onOpen: (kind, id) => opened = '$kind/$id',
          ),
        ),
      ),
    );
    expect(find.text('AA'), findsOneWidget);
    await tester.tap(
      find.ancestor(of: find.text('AA'), matching: find.byType(ActionChip)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Hill Relay'), findsOneWidget);
    await tester.tap(find.text('Hill Relay'));
    await tester.pumpAndSettle();
    expect(opened, 'node/node-1');
    expect(find.text('hello'), findsOneWidget);
  });

  testWidgets('trace view links resolved path candidates to nodes', (
    tester,
  ) async {
    String? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PacketPayloadView(
            detail: {
              'parsedPayload': {
                'type': 'TRACE',
                'traceTag': '01020304',
                'authCode': 4,
                'flags': 0,
                'pathHashes': ['aa'],
                'snrValues': [3.5],
              },
              'resolvedRoute': [
                {
                  'confidence': 'ambiguous',
                  'nodes': [
                    {'id': 'node-2', 'name': 'Low Relay'},
                    {'id': 'node-3', 'name': 'High Relay'},
                  ],
                },
              ],
            },
            observation: {},
            onOpen: (kind, id) => opened = '$kind/$id',
          ),
        ),
      ),
    );
    expect(find.text('Trace tag'), findsOneWidget);
    expect(find.text('Auth code'), findsOneWidget);
    expect(find.text('3.5 dB'), findsOneWidget);
    expect(find.text('AA'), findsOneWidget);
    await tester.tap(
      find.ancestor(of: find.text('AA'), matching: find.byType(ActionChip)),
    );
    await tester.pumpAndSettle();
    expect(find.text('High Relay'), findsOneWidget);
    await tester.tap(find.text('High Relay'));
    await tester.pumpAndSettle();
    expect(opened, 'node/node-3');
  });

  testWidgets('anonymous request keeps prefixed destination hash chip', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PacketPayloadView(
            detail: {
              'parsedPayload': {
                'type': 'ANON_REQUEST',
                'destination': 10,
                'ephemeralPubKey': 'aabbccdd',
              },
            },
            observation: {},
            onOpen: (_, _) {},
          ),
        ),
      ),
    );
    expect(find.text('0x0A'), findsOneWidget);
    expect(find.text('Ephemeral public key'), findsOneWidget);
  });

  testWidgets('encrypted payload hex remains fully selectable', (tester) async {
    final ciphertext = List.filled(80, 'ab').join();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PacketPayloadView(
            detail: {
              'parsedPayload': {
                'type': 'GROUP_DATA',
                'channelHash': 'aa',
                'ciphertext': ciphertext,
                'decrypted': null,
              },
            },
            observation: {},
            onOpen: (_, _) {},
          ),
        ),
      ),
    );
    expect(find.text(ciphertext.toUpperCase()), findsOneWidget);
  });
}
