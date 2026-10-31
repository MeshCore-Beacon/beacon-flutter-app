import 'dart:async';
import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/features/directory/directory.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

typedef RouteRow = Map<String, dynamic>;

RouteRow route(int id, String iata, int lastSeen) => {
  'id': id,
  'iata': iata,
  'pathKey': 'p$id',
  'hops': [
    {'hashBytes': 'h$id'},
  ],
  'hopCount': 1,
  'lastSeen': lastSeen,
};

int newestFirst(RouteRow a, RouteRow b) {
  final seen = (b['lastSeen'] as int).compareTo(a['lastSeen'] as int);
  return seen != 0 ? seen : (b['id'] as int).compareTo(a['id'] as int);
}

/// /routes as the server pages it. With [honoursIatas] false it acts like a
/// server before 2.1, which ignores iatas and answers with every IATA.
http.Response serveRoutes(
  Uri url,
  List<RouteRow> all, {
  bool honoursIatas = true,
}) {
  final q = url.queryParameters;
  final iatas = honoursIatas && (q['iatas'] ?? '').isNotEmpty
      ? q['iatas']!.split(',').toSet()
      : null;
  final iata = iatas == null ? q['iata'] ?? '' : '';
  final cursor = int.tryParse(q['cursor'] ?? '');
  final cursorId = int.tryParse(q['cursorId'] ?? '');
  final page = ([...all]..sort(newestFirst))
      .where((r) {
        if (iatas != null && !iatas.contains(r['iata'])) return false;
        if (iata.isNotEmpty && r['iata'] != iata) return false;
        if (cursor == null) return true;
        final seen = r['lastSeen'] as int;
        return seen < cursor ||
            (cursorId != null && seen == cursor && (r['id'] as int) < cursorId);
      })
      .take(int.parse(q['limit'] ?? '50'))
      .toList();
  return http.Response(jsonEncode(page), 200);
}

/// Every /routes request, plus the screen, served from [all].
Future<List<Map<String, String>>> showRoutes(
  WidgetTester tester,
  String iatas,
  List<RouteRow> all, {
  bool Function()? honoursIatas,
  Stream<Map<String, dynamic>>? events,
}) async {
  // Tall enough that every loaded row is built, so the order can be read.
  tester.view.physicalSize = const Size(800, 20000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final requests = <Map<String, String>>[];
  final api = ApiClient(
    Uri.parse('https://test.invalid'),
    client: MockClient((r) async {
      if (!r.url.path.endsWith('/routes')) return http.Response('[]', 200);
      requests.add(r.url.queryParameters);
      return serveRoutes(
        r.url,
        all,
        honoursIatas: honoursIatas?.call() ?? true,
      );
    }),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: DirectoryScreen(
          kind: 'routes',
          api: api,
          region: {'iatas': iatas},
          onOpen: (_, _) {},
          events: events,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return requests;
}

/// Route ids in the order the list shows them.
List<int> shownRoutes(WidgetTester tester) {
  final rows = tester
      .widgetList<KeyedSubtree>(
        find.byWidgetPredicate(
          (w) =>
              w is KeyedSubtree &&
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith('routes:'),
        ),
      )
      .map((w) => w.key! as ValueKey<String>)
      .toList();
  rows.sort(
    (a, b) => tester
        .getTopLeft(find.byKey(a))
        .dy
        .compareTo(tester.getTopLeft(find.byKey(b)).dy),
  );
  return [for (final key in rows) int.parse(key.value.split(':p').last)];
}

List<int> idsOf(Iterable<RouteRow> routes) => [
  for (final r in [...routes]..sort(newestFirst)) r['id'] as int,
];

Future<void> loadOlder(WidgetTester tester) async {
  await tester.tap(find.text('Load older'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a region pages its routes with one iatas request per page', (
    tester,
  ) async {
    // 55 region routes among another area's; the 50th and 51st share a millisecond.
    final all = [
      for (var i = 0; i < 55; i++)
        route(
          i + 1,
          i.isEven ? 'YVR' : 'YYJ',
          10000 - i * 10 + (i == 50 ? 10 : 0),
        ),
      for (var i = 0; i < 30; i++) route(100 + i, 'SEA', 10005 - i * 10),
    ];
    final requests = await showRoutes(tester, 'YVR,YYJ', all);
    expect(requests, [
      {'iatas': 'YVR,YYJ', 'limit': '50'},
    ]);
    await loadOlder(tester);
    final region = all.where((r) => r['iata'] != 'SEA');
    final last = ([...region]..sort(newestFirst))[49];
    expect(requests.last, {
      'iatas': 'YVR,YYJ',
      'limit': '50',
      'cursor': '${last['lastSeen']}',
      'cursorId': '${last['id']}',
    });
    expect(requests, hasLength(2));
    expect(shownRoutes(tester), idsOf(region));
    expect(find.text('55 routes'), findsOneWidget);
  });

  testWidgets('one IATA still goes as iata', (tester) async {
    final requests = await showRoutes(tester, 'YVR', [route(1, 'YVR', 100)]);
    expect(requests, [
      {'iata': 'YVR', 'limit': '50'},
    ]);
    expect(shownRoutes(tester), [1]);
  });

  testWidgets('a server that ignores iatas falls back to one call per IATA', (
    tester,
  ) async {
    final all = [
      route(900, 'SEA', 5000),
      for (var i = 0; i < 52; i++) route(i + 1, 'YVR', 3000 - i),
      for (var i = 0; i < 3; i++) route(100 + i, 'YYJ', 2900 - i),
    ];
    final requests = await showRoutes(
      tester,
      'YVR,YYJ',
      all,
      honoursIatas: () => false,
    );
    expect(requests, [
      {'iatas': 'YVR,YYJ', 'limit': '50'},
      {'iata': 'YVR', 'limit': '50'},
      {'iata': 'YYJ', 'limit': '50'},
    ]);
    final region = all.where((r) => r['iata'] != 'SEA').toList();
    expect(
      shownRoutes(tester),
      idsOf(region.take(50).followedBy(region.skip(52))),
    );
    await loadOlder(tester);
    expect(requests.last, {
      'iata': 'YVR',
      'limit': '50',
      'cursor': '2951',
      'cursorId': '50',
    });
    expect(requests, hasLength(4));
    // YVR's older routes go above YYJ's, not after them.
    expect(shownRoutes(tester), idsOf(region));
  });

  testWidgets('a server that stops honouring iatas restarts per IATA', (
    tester,
  ) async {
    var honours = true;
    final all = [
      route(900, 'SEA', 5000),
      route(901, 'SEA', 2000),
      for (var i = 0; i < 52; i++) route(i + 1, 'YVR', 3000 - i),
      for (var i = 0; i < 3; i++) route(100 + i, 'YYJ', 2900 - i),
    ];
    final requests = await showRoutes(
      tester,
      'YVR,YYJ',
      all,
      honoursIatas: () => honours,
    );
    expect(requests, hasLength(1));
    honours = false;
    await loadOlder(tester);
    expect(requests[1]['iatas'], 'YVR,YYJ');
    expect(requests.skip(2), [
      {'iata': 'YVR', 'limit': '50'},
      {'iata': 'YYJ', 'limit': '50'},
    ]);
    final region = all.where((r) => r['iata'] != 'SEA').toList();
    expect(
      shownRoutes(tester),
      idsOf(region.take(50).followedBy(region.skip(52))),
    );
    await loadOlder(tester);
    expect(requests.last['iata'], 'YVR');
    expect(requests.last['cursor'], '2951');
    expect(shownRoutes(tester), idsOf(region));
  });

  testWidgets('a live refresh that finds iatas ignored still pages it all', (
    tester,
  ) async {
    var honours = true;
    final events = StreamController<Map<String, dynamic>>.broadcast();
    final all = [
      route(900, 'SEA', 5000),
      for (var i = 0; i < 52; i++) route(i + 1, 'YVR', 3000 - i),
      for (var i = 0; i < 3; i++) route(100 + i, 'YYJ', 2900 - i),
    ];
    final requests = await showRoutes(
      tester,
      'YVR,YYJ',
      all,
      honoursIatas: () => honours,
      events: events.stream,
    );
    honours = false;
    events.add({'type': 'refresh'});
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(requests.skip(2).map((q) => q['iata']), ['YVR', 'YYJ']);
    for (
      var i = 0;
      i < 5 && find.text('Load older').evaluate().isNotEmpty;
      i++
    ) {
      await loadOlder(tester);
    }
    expect(find.text('Load older'), findsNothing);
    expect(shownRoutes(tester), idsOf(all.where((r) => r['iata'] != 'SEA')));
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  for (final count in [100, 101]) {
    testWidgets('a region of $count IATAs', (tester) async {
      final codes = [
        for (var i = 0; i < count; i++)
          'X${String.fromCharCode(65 + i ~/ 26)}${String.fromCharCode(65 + i % 26)}',
      ];
      final requests = await showRoutes(tester, codes.join(','), [
        route(1, codes.last, 100),
      ]);
      if (count <= 100) {
        expect(requests, [
          {'iatas': codes.join(','), 'limit': '50'},
        ]);
      } else {
        // Over the server's cap, so each IATA is asked for on its own.
        expect(requests.map((q) => q['iata']), codes);
        expect(requests.where((q) => q.containsKey('iatas')), isEmpty);
      }
      expect(shownRoutes(tester), [1]);
    });
  }
}
