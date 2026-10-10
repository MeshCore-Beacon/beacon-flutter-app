import 'package:beacon/features/packets/path_hop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('candidate sheet previews, reveals and copies full keys', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = List.filled(8, 'abcdef12').join();
    String? copied;
    String? opened;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
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
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PathHopChip(
            hash: 'ab',
            hop: {
              'confidence': 'ambiguous',
              'nodes': List.generate(
                15,
                (i) => {'id': 'node$i', 'name': 'Relay $i', 'publicKey': key},
              ),
            },
            onOpen: (kind, id) => opened = '$kind/$id',
          ),
        ),
      ),
    );
    await tester.tap(find.byType(ActionChip));
    await tester.pumpAndSettle();
    expect(find.text('Multiple matches'), findsOneWidget);
    expect(find.text(key), findsNothing);
    await tester.tap(find.text('abcdef12abcd…abcdef12').first);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text(key), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Copy public key').first);
    await tester.pumpAndSettle();
    expect(copied, key);
    expect(opened, isNull);
    await tester.scrollUntilVisible(
      find.text('Relay 14'),
      150,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Relay 14'));
    await tester.pumpAndSettle();
    expect(opened, 'node/node14');
    expect(find.byType(BottomSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
