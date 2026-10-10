import 'package:beacon/features/packets/investigation.dart';
import 'package:beacon/features/packets/path_hop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'observations use compact headers and show six path groups initially',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                PacketInvestigation(
                  initiallyExpanded: true,
                  selectedId: null,
                  detail: {
                    'observations': [
                      for (var i = 1; i <= 7; i++)
                        {
                          'id': i,
                          'observerId': 'observer-$i',
                          'pathBytes': i.toRadixString(16).padLeft(2, '0'),
                          'pathLength': {'hashSize': 1, 'hopCount': 1},
                        },
                    ],
                  },
                  onSelect: (_) {},
                  onOpen: (_, _) {},
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final title = tester.widget<Text>(find.text('OBSERVATIONS'));
      expect(title.style?.fontFamily, 'JetBrainsMono');
      expect(find.text('Heard by 7 observers'), findsOneWidget);
      final pathTitles = tester
          .widgetList<RichText>(find.byType(RichText))
          .map((text) => text.text.toPlainText())
          .toList();
      for (var i = 1; i <= 6; i++) {
        expect(
          pathTitles,
          contains(
            'Path $i  ${i.toRadixString(16).padLeft(2, '0').toUpperCase()}',
          ),
        );
      }
      expect(pathTitles, isNot(contains('Path 7  07')));
      expect(find.text('Load more (1 left)'), findsOneWidget);
    },
  );

  testWidgets('observer reports fill the screen regardless of content length', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              PacketInvestigation(
                initiallyExpanded: true,
                selectedId: '1',
                detail: {
                  'observations': [
                    {
                      'id': 1,
                      'observerId': 'a',
                      'observerName': 'Short',
                      'pathBytes': 'AA',
                      'pathLength': {'hashSize': 1, 'hopCount': 1},
                    },
                    {
                      'id': 2,
                      'observerId': 'b',
                      'observerName': 'A much longer observer name',
                      'pathBytes': 'AA',
                      'pathLength': {'hashSize': 1, 'hopCount': 1},
                      'propagationTimeMs': 4994,
                    },
                  ],
                },
                onSelect: (_) {},
                onOpen: (_, _) {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final id in [1, 2]) {
      final rect = tester.getRect(find.byKey(ValueKey('report-$id')));
      expect(rect.left, 0);
      expect(rect.right, 390);
    }
    expect(tester.takeException(), isNull);
  });
  test(
    'path groups keep malformed reports separate and order by reception',
    () {
      final groups = groupPacketReports([
        {
          'id': 3,
          'heardAt': 30,
          'pathBytes': 'aa',
          'pathLength': {'hashSize': 1, 'hopCount': 1},
        },
        {
          'id': 1,
          'heardAt': 10,
          'pathBytes': 'AA',
          'pathLength': {'hashSize': 1, 'hopCount': 1},
        },
        {
          'id': 2,
          'heardAt': 20,
          'pathBytes': 'AA',
          'pathLength': {'hashSize': 2, 'hopCount': 1},
        },
        {
          'id': 4,
          'heardAt': 40,
          'pathBytes': '',
          'pathLength': {'hashSize': 1, 'hopCount': 0},
        },
      ]);
      expect(groups.length, 3);
      expect(groups.first.reports.map((r) => r['id']), [1, 3]);
      expect(groups[1].kind, 'unavailable');
      expect(groups[2].kind, 'empty');
    },
  );
  testWidgets(
    'observation paths label hashes from wire bytes, including unresolved hops',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PacketPathHops(
              observation: {
                'pathBytes': 'a180971300c7',
                'pathLength': {'hashSize': 3, 'hopCount': 2},
                'resolvedPath': [
                  {
                    'confidence': 'high',
                    'nodes': [
                      {'id': 'one', 'name': 'Relay'},
                    ],
                  },
                ],
              },
              onOpen: (_, _) {},
            ),
          ),
        ),
      );
      expect(find.text('A18097'), findsOneWidget);
      expect(find.text('1300C7'), findsOneWidget);
      expect(find.text('Resolved node'), findsNothing);
      await tester.tap(find.text('1300C7'));
      await tester.pumpAndSettle();
      expect(find.text('No resolved nodes for this hop.'), findsOneWidget);
    },
  );
  testWidgets(
    'ambiguous hop popup opens chosen node without selecting packet',
    (tester) async {
      String? opened;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PathHopChip(
              hash: 'AA',
              hop: {
                'confidence': 'ambiguous',
                'nodes': [
                  {'id': 'one', 'name': 'First'},
                  {'id': 'two', 'name': 'Second'},
                ],
              },
              onOpen: (kind, id) => opened = '$kind:$id',
            ),
          ),
        ),
      );
      expect(find.text('First'), findsNothing);
      await tester.tap(find.byType(ActionChip));
      await tester.pumpAndSettle();
      expect(find.text('First'), findsOneWidget);
      await tester.tap(find.text('Second'));
      await tester.pumpAndSettle();
      expect(opened, 'node:two');
      expect(find.text('First'), findsNothing);
    },
  );
}
