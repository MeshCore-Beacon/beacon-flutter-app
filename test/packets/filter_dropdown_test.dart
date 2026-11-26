import 'package:beacon/features/packets/filter_dropdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('search filters choices and preserves multiple selections', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var selected = <int>{};
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, update) => Padding(
              padding: const EdgeInsets.all(16),
              child: FilterDropdown<int>(
                label: 'Observers',
                options: {
                  1: 'Roof observer',
                  2: 'Garden observer',
                  3: 'Hill station',
                  for (var i = 4; i <= 9; i++) i: 'Spare $i',
                },
                selected: selected,
                onChanged: (value) => update(() => selected = value),
              ),
            ),
          ),
        ),
      ),
    );
    final anchor = find.byKey(const ValueKey('filter-Observers'));
    final search = find.byKey(const ValueKey('search-Observers'));
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(find.text('Any'), findsOneWidget);
    await tester.tap(anchor);
    await tester.pumpAndSettle();
    await tester.enterText(search, 'ROOF');
    await tester.pumpAndSettle();
    expect(find.byType(CheckboxListTile), findsOneWidget);
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Roof observer'));
    await tester.pumpAndSettle();
    await tester.enterText(search, 'garden');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Garden observer'));
    await tester.pumpAndSettle();
    expect(selected, {1, 2});
    await tester.enterText(search, 'absent');
    await tester.pumpAndSettle();
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(find.text('No results'), findsOneWidget);
    await tester.tap(anchor);
    await tester.pumpAndSettle();
    await tester.tap(anchor);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(search).controller!.text, isEmpty);
    expect(
      tester
          .widget<CheckboxListTile>(
            find.widgetWithText(CheckboxListTile, 'Roof observer'),
          )
          .value,
      isTrue,
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 330);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('a short list has no search box and shows its selection', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FilterDropdown<int>(
            label: 'Route type',
            options: const {1: 'FLOOD', 2: 'DIRECT'},
            selected: const {1, 2},
            onChanged: (_) {},
          ),
        ),
      ),
    );
    expect(find.text('FLOOD, DIRECT'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('filter-Route type')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('search-Route type')), findsNothing);
    expect(find.byType(CheckboxListTile), findsNWidgets(2));
  });
}
