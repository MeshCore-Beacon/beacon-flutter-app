import 'package:beacon/core/filter_sheet.dart';
import 'package:beacon/core/sheet.dart';
import 'package:beacon/core/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> pump(WidgetTester tester, Widget body) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: BeaconTheme.all.first.data,
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: body,
        ),
      ),
    ),
  );
}

Finder field(String label) => find.byKey(ValueKey('filter-$label'));

void main() {
  setUp(BeaconTheme.load);
  footerTests();

  testWidgets('single: Any row first, radios, closes on pick', (tester) async {
    var selected = <String>{};
    await pump(
      tester,
      StatefulBuilder(
        builder: (context, update) => FilterField<String>(
          label: 'Poller',
          options: const {'true': 'Yes', 'false': 'No'},
          selected: selected,
          onChanged: (v) => update(() => selected = v),
        ),
      ),
    );
    expect(find.text('Any'), findsOneWidget);
    await tester.tap(field('Poller'));
    await tester.pumpAndSettle();
    // The Any row leads the list; no search for a short list.
    expect(find.text('Any'), findsNWidgets(2));
    expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_off), findsNWidgets(2));
    expect(find.byIcon(Icons.check_box_outline_blank), findsNothing);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('No'));
    await tester.pumpAndSettle();
    expect(selected, {'false'});
    expect(find.byIcon(Icons.radio_button_off), findsNothing);
    await tester.tap(field('Poller'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Any').last);
    await tester.pumpAndSettle();
    expect(selected, isEmpty);
  });

  testWidgets('multi: checkboxes, stays open, no Any row', (tester) async {
    var selected = <int>{};
    await pump(
      tester,
      StatefulBuilder(
        builder: (context, update) => FilterField<int>(
          label: 'Route type',
          multi: true,
          options: const {1: 'FLOOD', 2: 'DIRECT'},
          selected: selected,
          onChanged: (v) => update(() => selected = v),
        ),
      ),
    );
    await tester.tap(field('Route type'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check_box_outline_blank), findsNWidgets(2));
    expect(find.text('Any'), findsOneWidget);
    await tester.tap(find.text('FLOOD'));
    await tester.pump();
    await tester.tap(find.text('DIRECT'));
    await tester.pumpAndSettle();
    expect(selected, {1, 2});
    expect(find.byIcon(Icons.check_box), findsNWidgets(2));
    expect(find.text('FLOOD, DIRECT'), findsOneWidget);
    await tester.tap(find.text('FLOOD').last);
    await tester.pumpAndSettle();
    expect(selected, {2});
  });

  testWidgets('search only above 8 options, unfocused, filters', (
    tester,
  ) async {
    await pump(
      tester,
      FilterField<String>(
        label: 'Scope',
        options: {for (var i = 0; i < 9; i++) '#s$i': '#scope$i'},
        selected: const {},
        onChanged: (_) {},
      ),
    );
    await tester.tap(field('Scope'));
    await tester.pumpAndSettle();
    final search = find.byKey(const ValueKey('search-Scope'));
    expect(search, findsOneWidget);
    expect(tester.widget<TextField>(search).focusNode!.hasFocus, isFalse);
    await tester.enterText(search, 'scope7');
    await tester.pumpAndSettle();
    expect(find.text('#scope7'), findsOneWidget);
    expect(find.text('#scope3'), findsNothing);
    await tester.enterText(search, 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('No results'), findsOneWidget);
  });

  testWidgets('one field open at a time and the list pushes content down', (
    tester,
  ) async {
    await pump(
      tester,
      Column(
        children: [
          FilterField<String>(
            label: 'A',
            options: const {'x': 'X'},
            selected: const {},
            onChanged: (_) {},
          ),
          FilterField<String>(
            label: 'B',
            options: const {'y': 'Y'},
            selected: const {},
            onChanged: (_) {},
          ),
        ],
      ),
    );
    final before = tester.getTopLeft(field('B')).dy;
    await tester.tap(field('A'));
    await tester.pumpAndSettle();
    expect(find.text('X'), findsOneWidget);
    expect(tester.getTopLeft(field('B')).dy, greaterThan(before));
    await tester.tap(field('B'));
    await tester.pumpAndSettle();
    expect(find.text('X'), findsNothing);
    expect(find.text('Y'), findsOneWidget);
  });

  testWidgets('the field has the dropdown height and chevron', (tester) async {
    await pump(
      tester,
      Column(
        children: [
          DropdownButtonFormField<String>(
            key: const ValueKey('directory'),
            initialValue: '',
            isExpanded: true,
            decoration: filterFieldDecoration('Scope'),
            items: const [DropdownMenuItem(value: '', child: Text('Any'))],
            onChanged: (_) {},
          ),
          FilterField<int>(
            key: const ValueKey('packets'),
            label: 'Scope',
            options: const {1: 'A'},
            selected: const {},
            onChanged: (_) {},
          ),
        ],
      ),
    );
    Finder decorator(String key) => find
        .descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(InputDecorator),
        )
        .first;
    Finder chevron(String key) => find.descendant(
      of: find.byKey(ValueKey(key)),
      matching: find.byIcon(Icons.arrow_drop_down),
    );
    expect(
      tester.getSize(decorator('packets')),
      tester.getSize(decorator('directory')),
    );
    IconThemeData theme(String key) =>
        IconTheme.of(tester.element(chevron(key)));
    expect(theme('packets').size, theme('directory').size);
    expect(theme('packets').color, theme('directory').color);
    double fromRight(String key) =>
        tester.getTopRight(decorator(key)).dx -
        tester.getTopLeft(chevron(key)).dx;
    expect(fromRight('packets'), fromRight('directory'));
  });
}

void footerTests() {
  testWidgets(
    'a long open list keeps the footer in view and the fields scroll',
    (tester) async {
      tester.view.physicalSize = const Size(390, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: BeaconTheme.all.first.data,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showBeaconSheet<void>(
                  context,
                  builder: (_) => BeaconSheet(
                    title: 'Filters',
                    maxHeight: .9,
                    child: FilterSheetBody(
                      onClear: () {},
                      onPrimary: () {},
                      fields: [
                        for (final label in ['A', 'B', 'C', 'D'])
                          FilterField<String>(
                            label: label,
                            options: {
                              for (var i = 0; i < 30; i++) '#$i': '#opt$i',
                            },
                            selected: const {},
                            onChanged: (_) {},
                          ),
                      ],
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(field('A'));
      await tester.pumpAndSettle();
      final screen = tester.view.physicalSize;
      final button = tester.getRect(find.widgetWithText(FilledButton, 'Apply'));
      expect(button.bottom, lessThanOrEqualTo(screen.height));
      expect(button.top, greaterThanOrEqualTo(0));
      final scroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(FilterSheetBody),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(scroll.position.maxScrollExtent, greaterThan(0));
    },
  );
}
