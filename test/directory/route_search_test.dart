import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/features/directory/directory.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

typedef Handler = http.Response Function(Uri url);

http.Response json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

Future<List<Uri>> search(
  WidgetTester tester, {
  Map<String, dynamic> region = const {},
  String fromHash = 'aa',
  String toHash = 'bb',
  Handler? searchResponse,
  Handler? crossResponse,
  List<String> known = const ['YVR', 'YYJ', 'SEA'],
}) async {
  final calls = <Uri>[];
  final api = ApiClient(
    Uri.parse('https://test.invalid'),
    client: MockClient((r) async {
      final path = r.url.path;
      if (path.endsWith('/iatas')) {
        return json([
          for (final iata in known) {'iata': iata},
        ]);
      }
      if (path.endsWith('/routes/search') || path.endsWith('/routes/cross')) {
        calls.add(r.url);
      }
      if (path.endsWith('/routes/search')) {
        return searchResponse?.call(r.url) ?? json([]);
      }
      if (path.endsWith('/routes/cross')) {
        return crossResponse?.call(r.url) ?? json([]);
      }
      return json([]);
    }),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: DirectoryScreen(
          kind: 'routes',
          api: api,
          region: region,
          onOpen: (_, _) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.enterText(find.widgetWithText(TextField, 'From hash'), fromHash);
  await tester.enterText(find.widgetWithText(TextField, 'To hash'), toHash);
  await tester.tap(find.widgetWithIcon(IconButton, Icons.search));
  await tester.pumpAndSettle();
  return calls;
}

Map<String, dynamic> route(String iata, List<String> hops, int lastSeen) => {
  'id': '$iata-${hops.join()}',
  'iata': iata,
  'pathKey': hops.join(),
  'hops': [
    for (final h in hops) {'node': h},
  ],
  'hopCount': hops.length,
  'lastSeen': lastSeen,
};

Map<String, dynamic> crossRoute(
  List<String> source,
  List<String> target,
  int lastSeen,
) => {
  'sourceSegment': [
    for (final h in source) {'node': h},
  ],
  'targetSegment': [
    for (final h in target) {'node': h},
  ],
  'totalHops': source.length + target.length,
  'crossHop': {
    'fromIata': 'YVR',
    'toIata': 'YYJ',
    'fromNode': source.last,
    'toNode': target.first,
    'lastSeen': lastSeen,
  },
};

void main() {
  testWidgets('single IATA scope sends only /routes/search', (tester) async {
    final calls = await search(tester, region: const {'iatas': 'yvr'});
    expect(calls.map((u) => u.path), ['/api/v1/routes/search']);
    expect(calls.single.queryParameters, {
      'iatas': 'YVR',
      'from': 'aa',
      'to': 'bb',
    });
  });

  testWidgets('multi IATA scope sends one search and one cross call', (
    tester,
  ) async {
    final calls = await search(
      tester,
      region: const {'iatas': 'YVR,YYJ,YVR'},
      fromHash: ' AABB ',
      toHash: 'cc',
    );
    expect(calls.map((u) => u.path).toSet(), {
      '/api/v1/routes/search',
      '/api/v1/routes/cross',
    });
    expect(calls, hasLength(2));
    final byPath = {for (final u in calls) u.path: u.queryParameters};
    expect(byPath['/api/v1/routes/search'], {
      'iatas': 'YVR,YYJ',
      'from': 'aabb',
      'to': 'cc',
    });
    expect(byPath['/api/v1/routes/cross'], {
      'iatas': 'YVR,YYJ',
      'fromHash': 'aabb',
      'toHash': 'cc',
    });
  });

  testWidgets('no scope searches globally without an iatas key', (
    tester,
  ) async {
    final calls = await search(tester);
    expect(calls, hasLength(2));
    for (final u in calls) {
      expect(u.queryParameters.containsKey('iatas'), isFalse);
    }
  });

  testWidgets('a scope listing every known IATA is treated as global', (
    tester,
  ) async {
    final calls = await search(tester, region: const {'iatas': 'SEA,YVR,YYJ'});
    expect(calls, hasLength(2));
    for (final u in calls) {
      expect(u.queryParameters.containsKey('iatas'), isFalse);
    }
  });

  testWidgets('more than 100 IATAs blocks the search', (tester) async {
    final many = [
      for (var i = 0; i < 101; i++) 'A${i.toString().padLeft(2, '0')}',
    ];
    final calls = await search(tester, region: {'iatas': many.join(',')});
    expect(calls, isEmpty);
    expect(find.textContaining('Pick areas in Filters'), findsOneWidget);
    expect(find.text('No routes found'), findsNothing);
  });

  testWidgets('a malformed hash blocks the search', (tester) async {
    final calls = await search(tester, fromHash: 'abc');
    expect(calls, isEmpty);
    expect(find.textContaining('2, 4, 6 or 8 hex'), findsOneWidget);
  });

  testWidgets('cross rows join segments once and merge by hops then recency', (
    tester,
  ) async {
    await search(
      tester,
      region: const {'iatas': 'YVR,YYJ'},
      searchResponse: (_) => json([
        route('YVR', ['aa', '11', '22', 'bb'], 100),
        route('YYJ', ['aa', 'bb'], 50),
      ]),
      crossResponse: (_) => json([
        crossRoute(['aa', 'f1'], ['f2', 'bb'], 900),
      ]),
    );
    final labels = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .where((t) => t.startsWith('YVR') || t.startsWith('YYJ'))
        .toList();
    expect(labels, ['YYJ', 'YVR → YYJ', 'YVR']);
    expect(find.textContaining('4 hops'), findsNWidgets(2));
  });

  test('cross row uses its segments, totalHops and crossHop.lastSeen', () {
    final row = crossRouteRow(crossRoute(['aa', 'f1'], ['f2', 'bb'], 900));
    expect(row['hops'], [
      {'node': 'aa'},
      {'node': 'f1'},
      {'node': 'f2'},
      {'node': 'bb'},
    ]);
    expect(row['hopCount'], 4);
    expect(row['lastSeen'], 900);
    expect(row['iata'], 'YVR → YYJ');
  });

  testWidgets('400 message shows verbatim without "No routes found"', (
    tester,
  ) async {
    const message =
        'hash matches too many areas; use a longer hash or fewer iatas';
    await search(
      tester,
      region: const {'iatas': 'YVR,YYJ'},
      searchResponse: (_) => json({
        'error': {'message': message},
      }, 400),
      crossResponse: (_) => json({
        'error': {'message': message},
      }, 400),
    );
    expect(find.text(message), findsOneWidget);
    expect(find.text('No routes found'), findsNothing);
  });

  testWidgets('503 shows the route search timeout message', (tester) async {
    await search(
      tester,
      region: const {'iatas': 'YVR'},
      searchResponse: (_) => json({
        'error': {'message': 'timeout'},
      }, 503),
    );
    expect(
      find.text(
        'Route search timed out — narrow the areas or use a longer hash.',
      ),
      findsOneWidget,
    );
    expect(find.text('No routes found'), findsNothing);
  });

  testWidgets('one failed call still shows the other call\'s routes', (
    tester,
  ) async {
    await search(
      tester,
      region: const {'iatas': 'YVR,YYJ'},
      searchResponse: (_) => json([
        route('YVR', ['aa', 'bb'], 100),
      ]),
      crossResponse: (_) => json({
        'error': {'message': 'cross failed'},
      }, 400),
    );
    expect(find.text('cross failed'), findsOneWidget);
    expect(find.text('YVR'), findsWidgets);
  });

  testWidgets('cross rows omit First and the footer counts routes', (
    tester,
  ) async {
    await search(
      tester,
      region: const {'iatas': 'YVR,YYJ'},
      searchResponse: (_) => json([
        {
          ...route('YVR', ['aa', 'bb'], 100),
          'firstSeen': 50,
        },
      ]),
      crossResponse: (_) => json([
        crossRoute(['aa', 'f1'], ['f2', 'bb'], 900),
      ]),
    );
    expect(find.textContaining('First '), findsOneWidget);
    expect(find.textContaining('Last '), findsNWidgets(2));
    expect(find.text('2 routes'), findsOneWidget);
  });

  testWidgets('a single result uses the singular footer', (tester) async {
    await search(
      tester,
      region: const {'iatas': 'YVR'},
      searchResponse: (_) => json([
        route('YVR', ['aa', 'bb'], 100),
      ]),
    );
    expect(find.text('1 route'), findsOneWidget);
    expect(find.text('1 routes'), findsNothing);
  });

  test('pluralCount singularises one item only', () {
    expect(pluralCount(0, 'routes'), '0 routes');
    expect(pluralCount(1, 'routes'), '1 route');
    expect(pluralCount(1, 'nodes'), '1 node');
    expect(pluralCount(2, 'channels'), '2 channels');
  });

  testWidgets('IATA filter uppercases as typed and in requests', (
    tester,
  ) async {
    final listed = <String>[];
    final api = ApiClient(
      Uri.parse('https://test.invalid'),
      client: MockClient((r) async {
        if (r.url.path.endsWith('/routes')) {
          listed.add(r.url.queryParameters['iata'] ?? '');
        }
        return json([]);
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DirectoryScreen(
            kind: 'routes',
            api: api,
            region: const {},
            onOpen: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Filters'));
    await tester.pumpAndSettle();
    final field = find.descendant(
      of: find.byKey(const ValueKey('routes-iata-filter')),
      matching: find.byType(EditableText),
    );
    await tester.enterText(field, 'yvr');
    await tester.pump();
    expect(tester.widget<EditableText>(field).controller.text, 'YVR');
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(listed.last, 'YVR');
  });
}
