import 'dart:convert';

import 'package:beacon/app.dart';
import 'package:beacon/core/api.dart';
import 'package:beacon/core/json.dart';
import 'package:beacon/core/region_selection.dart';
import 'package:beacon/core/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ApiClient fakeApi() => ApiClient(
  Uri.parse('https://beacon.example.com/api/v1'),
  client: MockClient((r) async {
    final body = switch (r.url.path) {
      final p when p.endsWith('/regions') => [
        {'id': 1, 'slug': 'golm', 'name': 'Great Ontario Lake Mesh'},
        {'id': 2, 'slug': 'ottawa', 'name': 'Ottawa-Quebec Corridor'},
      ],
      final p when p.endsWith('/regions/1') => {
        'iatas': ['YYZ', 'YHM'],
      },
      final p when p.endsWith('/regions/2') => {
        'iatas': ['YOW'],
      },
      final p when p.endsWith('/iatas') => [
        {'iata': 'XCM', 'displayName': 'Chatham-Kent'},
        {'iata': 'YOW', 'displayName': 'Ottawa'},
      ],
      _ => <String, dynamic>{},
    };
    return http.Response(jsonEncode(body), 200);
  }),
);

void main() {
  setUp(BeaconTheme.load);

  Future<(RegionSelection, Json)?> open(
    WidgetTester tester,
    RegionSelection initial,
    Future<void> Function() interact,
  ) async {
    (RegionSelection, Json)? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: BeaconTheme.all.first.data,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async =>
                  result = await showModalBottomSheet<(RegionSelection, Json)>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) =>
                        RegionSheet(api: fakeApi(), initial: initial),
                  ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await interact();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    return result;
  }

  bool ticked(WidgetTester tester, String text) => tester
      .widget<CheckboxListTile>(
        find.ancestor(
          of: find.textContaining(text),
          matching: find.byType(CheckboxListTile),
        ),
      )
      .value!;

  testWidgets('a picked region stays ticked and mixes with areas', (
    tester,
  ) async {
    final result = await open(tester, RegionSelection.all, () async {
      await tester.tap(find.text('Great Ontario Lake Mesh'));
      await tester.tap(find.textContaining('Chatham-Kent'));
      await tester.pump();
      expect(ticked(tester, 'Great Ontario Lake Mesh'), isTrue);
      expect(ticked(tester, 'Ottawa-Quebec Corridor'), isFalse);
      expect(ticked(tester, 'Chatham-Kent'), isTrue);
    });
    expect(result!.$1.regions, {'golm'});
    expect(result.$1.areas, {'XCM'});
    expect(result.$2, {'iatas': 'XCM,YHM,YYZ'});
    expect(result.$1.label, '1 region · XCM');
  });

  testWidgets('reopening shows the saved region ticked', (tester) async {
    await open(
      tester,
      const RegionSelection(regions: {'ottawa'}),
      () async => expect(ticked(tester, 'Ottawa-Quebec Corridor'), isTrue),
    );
  });

  testWidgets('searching an area code finds its region', (tester) async {
    await open(tester, RegionSelection.all, () async {
      await tester.enterText(find.byType(TextField), 'yhm');
      await tester.pump();
      expect(find.text('Great Ontario Lake Mesh'), findsOneWidget);
      expect(find.text('YHM'), findsOneWidget);
      expect(find.text('Ottawa-Quebec Corridor'), findsNothing);
    });
  });
}
