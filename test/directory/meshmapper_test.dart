import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/core/strings.dart';
import 'package:beacon/features/directory/directory.dart';
import 'package:beacon/features/directory/meshmapper_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Future<void> pumpNode(
  WidgetTester tester,
  Map<String, dynamic> node, {
  bool open = true,
}) async {
  final api = ApiClient(
    Uri.parse('https://test.invalid'),
    client: MockClient((request) async {
      final path = request.url.path;
      final body = path.endsWith('/observations')
          ? {'items': [], 'hasMore': false}
          : path.endsWith('/neighbors')
          ? []
          : node;
      return http.Response(jsonEncode(body), 200);
    }),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: EntityDetailScreen(
        kind: 'node',
        id: 'node-1',
        api: api,
        region: const {},
        onOpen: (_, _) {},
      ),
    ),
  );
  await tester.pumpAndSettle();
  final fold = find.byKey(const ValueKey('fold-node-meshmapper'));
  if (open && fold.evaluate().isNotEmpty) {
    await tester.tap(fold);
    await tester.pumpAndSettle();
  }
}

/// The text of the info tip whose message contains [part].
String tipWith(WidgetTester tester, String part) => tester
    .widgetList<Tooltip>(find.byType(Tooltip))
    .map((t) => t.message ?? '')
    .firstWhere((m) => m.contains(part));

Map<String, dynamic> node([Map<String, dynamic>? meshmapper]) => {
  'id': 'node-1',
  'publicKey': 'public-key-value',
  'nodeTypeName': 'repeater',
  'defaultScope': 'beacon-scope',
  'meshmapper': ?meshmapper,
};

void main() {
  final now = DateTime.now().millisecondsSinceEpoch;
  const hour = 3600 * 1000;

  testWidgets('shows the full MeshMapper repeater record', (tester) async {
    await pumpNode(
      tester,
      node({
        'iata': 'YOW',
        'fetchedAt': now - 2 * hour,
        'site': {
          'power': '1W',
          'hardware': 'RAK4631',
          'antenna': '5.8 dBi fibreglass',
          'heightM': 12,
          'heightAslM': 341.6,
          'powerSource': 'solar',
          'notes': 'On the fire tower\neast face',
        },
        'carpeater': false,
        'admins': ['MrAlders0n', 'Second'],
        'scopes': [
          {
            'scope': 'yow',
            'observedAt': now - 3 * hour,
            'observedPackets': 37,
            'proof': 'multibyte',
            'reportedAt': now - 5 * hour,
          },
          {'scope': 'ott', 'uploadedAt': now - hour},
        ],
        'scopesCheckedAt': now - 5 * hour,
        'defaultScope': {
          'name': 'yow',
          'state': 'named',
          'updatedAt': now - 4 * hour,
          'source': 'advert',
        },
      }),
    );

    expect(find.text('MESHMAPPER'), findsOneWidget);
    expect(find.text('CARpeater'), findsNothing);
    expect(find.text('RAK4631'), findsOneWidget);
    expect(find.text('1W'), findsOneWidget);
    expect(find.text('Solar'), findsOneWidget);
    expect(find.text('5.8 dBi fibreglass'), findsOneWidget);
    expect(find.text('12 m AGL · 341.6 m ASL'), findsOneWidget);
    expect(find.text('MrAlders0n, Second'), findsOneWidget);
    expect(find.text('yow (advert, 4h ago)'), findsOneWidget);
    expect(find.text('Confirmed scopes'), findsOneWidget);
    expect(find.text('observed 37 packets · reported'), findsOneWidget);
    expect(find.text('3h ago'), findsOneWidget);
    expect(find.text('ott'), findsOneWidget);
    expect(find.text('uploaded'), findsOneWidget);
    expect(find.text('1h ago'), findsOneWidget);
    expect(find.textContaining('multibyte'), findsNothing);
    expect(find.text('On the fire tower\neast face'), findsOneWidget);
    expect(tipWith(tester, 'From MeshMapper (YOW)'), contains('updated'));
    // The summary only shows while the fold is closed.
    expect(find.text('YOW · 2 scopes'), findsNothing);
    // Beacon's own advert-matched scope stays a separate Identity badge.
    expect(find.text('beacon-scope'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('starts folded with a one-line summary', (tester) async {
    await pumpNode(
      tester,
      node({
        'iata': 'YOW',
        'fetchedAt': now,
        'site': {'hardware': 'RAK4631'},
        'carpeater': false,
        'admins': [],
        'scopes': [
          {'scope': 'yow', 'observedAt': now},
        ],
      }),
      open: false,
    );
    expect(find.text('MESHMAPPER'), findsOneWidget);
    expect(find.text('YOW · 1 scope'), findsOneWidget);
    expect(find.text('RAK4631'), findsNothing);
  });

  testWidgets('shows Details open, above the activity', (tester) async {
    await pumpNode(tester, {
      ...node(),
      'lat': 45.4215,
      'lng': -75.6972,
      'minFirmwareVersion': '1.14.0',
      'firstSeen': now - 48 * hour,
    });
    expect(find.byKey(const ValueKey('fold-node-details')), findsNothing);
    expect(find.text('Coordinates'), findsOneWidget);
    expect(find.text('Minimum firmware'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('DETAILS')).dy,
      lessThan(tester.getTopLeft(find.text('PACKETS SENT')).dy),
    );
  });

  testWidgets('names the packet list Packets sent and explains it', (
    tester,
  ) async {
    await pumpNode(tester, node());
    expect(find.text('PACKETS SENT'), findsOneWidget);
    expect(find.text('OBSERVATIONS'), findsNothing);
    expect(
      tipWith(tester, 'Adverts and login requests this node sent.'),
      contains("can't be listed here"),
    );
  });

  testWidgets('hides the section and badge without meshmapper', (tester) async {
    await pumpNode(tester, node());
    expect(find.text('MESHMAPPER'), findsNothing);
    expect(find.text('CARpeater'), findsNothing);
    expect(find.textContaining('From MeshMapper'), findsNothing);
  });

  testWidgets('a carpeater with nothing else shows only the badge', (
    tester,
  ) async {
    await pumpNode(
      tester,
      node({
        'fetchedAt': now,
        'site': <String, dynamic>{},
        'carpeater': true,
        'admins': [],
        'scopes': [],
      }),
    );
    expect(find.text('CARpeater'), findsOneWidget);
    expect(
      find.byTooltip('Mobile repeater in a vehicle: its position moves.'),
      findsOneWidget,
    );
    expect(find.text('MESHMAPPER'), findsNothing);
  });

  testWidgets('unknown default scope and none confirmed', (tester) async {
    await pumpNode(
      tester,
      node({
        'fetchedAt': now,
        'site': <String, dynamic>{},
        'carpeater': false,
        'admins': [],
        'scopes': [],
        'scopesCheckedAt': now - 2 * hour,
        'defaultScope': {'state': 'unknown'},
      }),
    );
    expect(find.text('MESHMAPPER'), findsOneWidget);
    expect(
      find.descendant(
        of: find
            .ancestor(
              of: find.text('Default scope'),
              matching: find.byType(Row),
            )
            .first,
        matching: find.text('Unknown'),
      ),
      findsOneWidget,
    );
    expect(find.text('None confirmed'), findsOneWidget);
    expect(find.text('2h ago'), findsOneWidget);
    expect(find.text('Hardware'), findsNothing);
  });

  testWidgets('long values fit a narrow phone', (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpNode(
      tester,
      node({
        'iata': 'YOW',
        'fetchedAt': now - 30 * 24 * hour,
        'site': {'hardware': 'H' * 80, 'notes': 'N' * 300},
        'admins': List.filled(8, 'a-long-admin-name'),
        'scopes': [
          {
            'scope': 's' * 80,
            'observedPackets': 123456,
            'reportedAt': now - 30 * 24 * hour,
            'uploadedAt': now,
          },
        ],
      }),
    );
    expect(tester.takeException(), isNull);
  });

  test('heights keep at most one decimal in the active language', () {
    addTearDown(() => language = 'en');
    expect(meshMapperNumber(12), '12');
    expect(meshMapperNumber(341.64), '341.6');
    expect(meshMapperNumber(4.0), '4');
    language = 'fr';
    expect(meshMapperNumber(341.6), '341,6');
  });
}
