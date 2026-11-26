import 'package:beacon/features/directory/node_chips.dart';
import 'package:beacon/features/map/map_markers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('type colours are the map marker colours, unknown is null', () {
    for (final e in nodeColors.entries) {
      expect(
        nodeTypeColor(e.key)!.toARGB32() & 0xFFFFFF,
        int.parse(e.value.substring(1), radix: 16),
      );
    }
    expect(nodeTypeColor('Room Server'), nodeTypeColor('room_server'));
    expect(nodeTypeColor('gateway'), isNull);
  });

  testWidgets('type chip is tinted, role chips are outlines', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Column(
            children: [
              nodeTypeChip(context, 'repeater', 'REPEATER', Colors.grey),
              nodeTypeChip(context, 'room_server', 'ROOM_SERVER', Colors.grey),
              pollerChip(),
              observerChip(iconOnly: true),
            ],
          ),
        ),
      ),
    );
    BoxDecoration deco(Finder f) =>
        tester
                .widget<Container>(
                  find
                      .descendant(of: f, matching: find.byType(Container))
                      .first,
                )
                .decoration!
            as BoxDecoration;
    final type = deco(find.byKey(const ValueKey('chip-type-repeater')));
    expect(type.color, isNotNull);
    final poller = deco(find.byKey(const ValueKey('chip-poller')));
    expect(poller.color, isNull);
    expect(find.text('ROOM SERVER'), findsOneWidget);
    expect(find.text('ROOM_SERVER'), findsNothing);
    expect(find.byKey(const ValueKey('chip-type-room_server')), findsOneWidget);
    expect(find.text('POLLER'), findsOneWidget);
    // Glyph-only chip has no text, only its accessible name.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('chip-observer')),
        matching: find.byType(Text),
      ),
      findsNothing,
    );
    expect(find.bySemanticsLabel('Observer'), findsOneWidget);
  });
}
