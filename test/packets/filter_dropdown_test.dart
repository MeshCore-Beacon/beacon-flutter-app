import 'package:beacon/core/filter_sheet.dart';
import 'package:beacon/core/theme.dart';
import 'package:beacon/features/packets/filter_dropdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  matchTests();
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

void matchTests() {
  testWidgets('the field has the directory dropdown height and chevron', (
    tester,
  ) async {
    await BeaconTheme.load();
    await tester.pumpWidget(
      MaterialApp(
        theme: BeaconTheme.all.first.data,
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                DropdownButtonFormField<String>(
                  key: const ValueKey('directory'),
                  initialValue: '',
                  isExpanded: true,
                  decoration: filterFieldDecoration('Scope'),
                  items: const [
                    DropdownMenuItem(value: '', child: Text('Any')),
                  ],
                  onChanged: (_) {},
                ),
                FilterDropdown<int>(
                  key: const ValueKey('packets'),
                  label: 'Scope',
                  options: const {1: 'A'},
                  selected: const {},
                  onChanged: (_) {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    Size field(String key) => tester.getSize(
      find
          .descendant(
            of: find.byKey(ValueKey(key)),
            matching: find.byType(InputDecorator),
          )
          .first,
    );
    // The icon theme the chevron actually inherits: size and colour.
    IconThemeData chevron(String key) => IconTheme.of(
      tester.element(
        find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byIcon(Icons.arrow_drop_down),
        ),
      ),
    );
    expect(field('packets'), field('directory'));
    final a = chevron('packets'), b = chevron('directory');
    expect(a.size, b.size);
    // Same spot in the field, measured from its right edge.
    double fromRight(String key) {
      final box = field(key).width;
      final left = tester
          .getTopLeft(
            find.descendant(
              of: find.byKey(ValueKey(key)),
              matching: find.byIcon(Icons.arrow_drop_down),
            ),
          )
          .dx;
      final fieldLeft = tester
          .getTopLeft(
            find
                .descendant(
                  of: find.byKey(ValueKey(key)),
                  matching: find.byType(InputDecorator),
                )
                .first,
          )
          .dx;
      return fieldLeft + box - left;
    }

    expect(fromRight('packets'), fromRight('directory'));
    expect(a.color, b.color);
  });
}
