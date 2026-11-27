import 'dart:io';

import 'package:beacon/core/sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> open(WidgetTester tester, Widget sheet) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showBeaconSheet<void>(context, builder: (_) => sheet),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('shows the title and actions, and the close button shuts it', (
    tester,
  ) async {
    await open(
      tester,
      BeaconSheet(
        title: 'Filters',
        actions: [TextButton(onPressed: () {}, child: const Text('Clear'))],
        child: const Text('body'),
      ),
    );
    expect(find.text('Filters'), findsOneWidget);
    expect(find.text('Clear'), findsOneWidget);
    expect(find.text('body'), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('a short sheet wraps its content', (tester) async {
    await open(
      tester,
      const BeaconSheet(title: 'Short', child: SizedBox(height: 40)),
    );
    expect(tester.getSize(find.byType(BeaconSheet)).height, lessThan(200));
  });

  testWidgets('a long sheet stops at its height cap and scrolls', (
    tester,
  ) async {
    await open(
      tester,
      BeaconSheet(
        title: 'Long',
        child: ListView(
          shrinkWrap: true,
          children: [
            for (var i = 0; i < 60; i++) ListTile(title: Text('row $i')),
          ],
        ),
      ),
    );
    expect(tester.getSize(find.byType(BeaconSheet)).height, 800 * .65);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a filled sheet holds its height whatever it contains', (
    tester,
  ) async {
    await open(
      tester,
      const BeaconSheet(
        title: 'Picker',
        fill: true,
        maxHeight: .75,
        child: SizedBox(height: 40),
      ),
    );
    expect(tester.getSize(find.byType(BeaconSheet)).height, 800 * .75);
  });

  testWidgets('rows are split by hairlines', (tester) async {
    await open(
      tester,
      const BeaconSheet(
        title: 'Rows',
        child: BeaconSheetRows(
          children: [
            ListTile(title: Text('a')),
            ListTile(title: Text('b')),
          ],
        ),
      ),
    );
    expect(find.byType(Divider), findsNWidgets(2));
  });

  testWidgets('a value sheet shows the whole value and copies it', (
    tester,
  ) async {
    String? copied;
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
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showValueSheet(context, title: 'Public key', value: 'AB12'),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Public key'), findsOneWidget);
    expect(find.widgetWithText(SelectableText, 'AB12'), findsOneWidget);
    await tester.tap(find.byTooltip('Copy'));
    await tester.pumpAndSettle();
    expect(copied, 'AB12');
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
  });

  test('every bottom sheet in the app goes through the shared shell', () {
    final strays = [
      for (final file in Directory('lib').listSync(recursive: true))
        if (file is File &&
            file.path.endsWith('.dart') &&
            !file.path.endsWith('core/sheet.dart') &&
            file.readAsStringSync().contains('showModalBottomSheet'))
          file.path,
    ];
    expect(strays, isEmpty);
  });
}
