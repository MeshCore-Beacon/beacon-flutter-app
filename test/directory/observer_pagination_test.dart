import 'dart:async';
import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/features/directory/directory.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> page(int start, int end, {bool more = false}) => {
  'items': [
    for (var i = start; i < end; i++)
      {
        'id': '$i',
        'displayName': 'Observer $i',
        'status': 'online',
        'observationCount': 1000 - i,
      },
  ],
  'windowStart': 1767225612345,
  'windowEnd': 1767830412345,
  'hasMore': more,
  if (more) 'nextCursor': end,
  'maxObservationCount': 1000,
  'observerTypes': ['remote-type'],
  'coverage': {'status': 'complete'},
  'effectiveSort': 'traffic',
};
Future<void> show(
  WidgetTester tester,
  Future<http.Response> Function(http.Request) handler,
) async {
  final api = ApiClient(
    Uri.parse('https://test.invalid'),
    client: MockClient(handler),
  );
  addTearDown(api.close);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: DirectoryScreen(
          kind: 'observers',
          api: api,
          region: const {'iata': 'YVR'},
          onOpen: (_, _) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

http.Response ok(Object value) => http.Response(jsonEncode(value), 200);
void main() {
  testWidgets('scrolls beyond 200 with counts and frozen window parameters', (
    tester,
  ) async {
    final requests = <Uri>[];
    await show(tester, (r) async {
      if (!r.url.path.endsWith('/directory')) return ok([]);
      requests.add(r.url);
      final start = int.tryParse(r.url.queryParameters['cursor'] ?? '') ?? 0;
      return ok({
        ...page(start, start + 50, more: start < 200),
        'maxObservationCount': start == 0 ? 1000 : 2000,
      });
    });
    expect(find.text('Observer 0'), findsOneWidget);
    expect(requests.single.queryParameters['sort'], 'traffic');
    final q = requests.single.queryParameters;
    expect(q.containsKey('since'), isFalse);
    expect(q.containsKey('until'), isFalse);
    for (var i = 0; i < 4; i++) {
      final scroll = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        ),
      );
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
    }
    expect(requests.length, 5);
    expect(requests.last.queryParameters, {
      'iata': 'YVR',
      'sort': 'traffic',
      'since': '1767225612345',
      'until': '1767830412345',
      'cursor': '200',
      'limit': '50',
    });
    await tester.scrollUntilVisible(
      find.text('Observer 200'),
      300,
      scrollable: find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.text('800'), findsOneWidget);
    final fills = tester.widgetList<FractionallySizedBox>(
      find.byType(FractionallySizedBox),
    );
    expect(fills.any((f) => f.widthFactor == .8), isTrue);
  });
  testWidgets('partial history keeps traffic counts, bars and server order', (
    tester,
  ) async {
    await show(
      tester,
      (r) async => r.url.path.endsWith('/directory')
          ? ok({
              ...page(0, 2),
              'items': [
                {'id': 'z', 'displayName': 'Zulu', 'observationCount': 800},
                {'id': 'a', 'displayName': 'Alpha', 'observationCount': 400},
              ],
              'maxObservationCount': 800,
              'coverage': {
                'status': 'partial',
                'expectedHours': 168,
                'completeHours': 64,
                'partialHours': 0,
                'missingHours': 104,
              },
            })
          : ok([]),
    );
    expect(find.text('800'), findsOneWidget);
    expect(find.text('400'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Zulu')).dy,
      lessThan(tester.getTopLeft(find.text('Alpha')).dy),
    );
    expect(
      tester
          .widgetList<FractionallySizedBox>(find.byType(FractionallySizedBox))
          .map((w) => w.widthFactor),
      [1, .5],
    );
    expect(find.textContaining('Traffic unavailable'), findsNothing);
  });
  testWidgets('no available history shows numeric zero without a warning', (
    tester,
  ) async {
    await show(
      tester,
      (r) async => r.url.path.endsWith('/directory')
          ? ok({
              ...page(0, 1),
              'items': [
                {
                  'id': '0',
                  'displayName': 'New observer',
                  'observationCount': 0,
                },
              ],
              'maxObservationCount': 0,
              'coverage': {'status': 'unavailable'},
            })
          : ok([]),
    );
    expect(find.text('0'), findsOneWidget);
    expect(find.text('-'), findsNothing);
    expect(find.textContaining('Traffic unavailable'), findsNothing);
    expect(
      tester
          .widgetList<FractionallySizedBox>(find.byType(FractionallySizedBox))
          .every((w) => w.widthFactor == 0),
      isTrue,
    );
  });
  for (final trigger in ['pull to refresh', 'app resume']) {
    testWidgets('$trigger gets a new window and freezes it for later pages', (
      tester,
    ) async {
      final requests = <Uri>[];
      var starts = 0;
      await show(tester, (r) async {
        if (!r.url.path.endsWith('/directory')) return ok([]);
        requests.add(r.url);
        final more = r.url.queryParameters.containsKey('cursor');
        if (!more) starts++;
        return ok({
          ...page(more ? 1 : 0, more ? 2 : 1, more: !more),
          'windowStart': starts == 1 ? 1767225612345 : 1767225672345,
          'windowEnd': starts == 1 ? 1767830412345 : 1767830472345,
        });
      });
      expect(requests.length, 2);
      if (trigger == 'pull to refresh') {
        await tester.drag(find.byType(ListView), const Offset(0, 400));
      } else {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      }
      await tester.pumpAndSettle();
      expect(requests.length, 4);
      expect(requests[2].queryParameters, {
        'iata': 'YVR',
        'limit': '50',
        'sort': 'traffic',
      });
      expect(requests[3].queryParameters, {
        'iata': 'YVR',
        'limit': '50',
        'sort': 'traffic',
        'since': '1767225672345',
        'until': '1767830472345',
        'cursor': '1',
      });
      expect(find.text('Observer 1'), findsOneWidget);
    });
  }
  testWidgets('fills short viewport and stops a repeated cursor', (
    tester,
  ) async {
    var calls = 0;
    await show(tester, (r) async {
      if (!r.url.path.endsWith('/directory')) return ok([]);
      calls++;
      return ok(page(0, 1, more: true));
    });
    expect(calls, 2);
    expect(find.text('Observer 0'), findsOneWidget);
  });
  testWidgets('null counts remain unavailable and server order is preserved', (
    tester,
  ) async {
    await show(
      tester,
      (r) async => r.url.path.endsWith('/directory')
          ? ok({
              ...page(0, 2),
              'items': [
                {'id': 'z', 'displayName': 'Zulu', 'observationCount': null},
                {'id': 'a', 'displayName': 'Alpha', 'observationCount': null},
              ],
              'maxObservationCount': null,
              'coverage': {'status': 'partial'},
              'effectiveSort': 'name',
            })
          : ok([]),
    );
    expect(find.text('-'), findsNWidgets(2));
    expect(
      tester.getTopLeft(find.text('Zulu')).dy,
      lessThan(tester.getTopLeft(find.text('Alpha')).dy),
    );
    expect(find.textContaining('Traffic unavailable'), findsOneWidget);
  });
  testWidgets(
    'changed effective sort restarts the list instead of mixing orders',
    (tester) async {
      var starts = 0;
      await show(tester, (r) async {
        if (!r.url.path.endsWith('/directory')) return ok([]);
        if (r.url.queryParameters.containsKey('cursor')) {
          return ok({...page(1, 2), 'effectiveSort': 'name'});
        }
        starts++;
        return ok(starts == 1 ? page(0, 1, more: true) : page(10, 11));
      });
      expect(starts, 2);
      expect(find.text('Observer 0'), findsNothing);
      expect(find.text('Observer 10'), findsOneWidget);
    },
  );
  testWidgets('older server shows upgrade state', (tester) async {
    await show(
      tester,
      (r) async => r.url.path.endsWith('/directory')
          ? http.Response(
              '{"error":{"message":"failed to parse observer UUID"}}',
              400,
            )
          : ok([]),
    );
    expect(find.textContaining('Upgrade'), findsOneWidget);
  });
  testWidgets(
    'search rejects an old in-flight page and sends filters to server',
    (tester) async {
      final pending = Completer<http.Response>();
      final requests = <Uri>[];
      await show(tester, (r) async {
        if (!r.url.path.endsWith('/directory')) return ok([]);
        requests.add(r.url);
        if (r.url.queryParameters.containsKey('cursor')) {
          return pending.future;
        }
        return ok(
          requests.length == 1 ? page(0, 50, more: true) : page(100, 101),
        );
      });
      final scroll = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        ),
      );
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      await tester.enterText(find.byType(TextField).first, 'North');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(requests.last.queryParameters['name'], 'North');
      expect(requests.last.queryParameters['iata'], 'YVR');
      expect(requests.last.queryParameters.containsKey('cursor'), isFalse);
      pending.complete(ok(page(50, 100)));
      await tester.pumpAndSettle();
      expect(find.text('Observer 100'), findsOneWidget);
      expect(find.text('Observer 50'), findsNothing);
    },
  );
  testWidgets('failed next page preserves rows and retries the same cursor', (
    tester,
  ) async {
    var attempts = 0;
    final continuations = <Map<String, String>>[];
    await show(tester, (r) async {
      if (!r.url.path.endsWith('/directory')) return ok([]);
      if (!r.url.queryParameters.containsKey('cursor')) {
        return ok(page(0, 1, more: true));
      }
      continuations.add(r.url.queryParameters);
      attempts++;
      if (attempts == 1) {
        return http.Response('{"error":{"message":"Try again"}}', 500);
      }
      return ok({
        ...page(0, 2),
        'items': [
          {'id': '0', 'displayName': 'Observer 0', 'observationCount': 1000},
          {'id': '1', 'displayName': 'Observer 1', 'observationCount': 0},
        ],
      });
    });
    expect(find.text('Observer 0'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(continuations.length, 2);
    expect(continuations[0], continuations[1]);
    expect(find.text('Observer 0'), findsOneWidget);
    expect(find.text('Observer 1'), findsOneWidget);
    expect(find.text('0'), findsOneWidget);
  });
  testWidgets('slow filter options survive automatic continuation', (
    tester,
  ) async {
    final scopes = Completer<http.Response>();
    await show(tester, (r) async {
      if (r.url.path.endsWith('/scopes')) return scopes.future;
      if (r.url.path.endsWith('/brokers')) {
        return ok([
          {'name': 'remote-broker'},
        ]);
      }
      if (!r.url.path.endsWith('/directory')) return ok([]);
      return ok(
        r.url.queryParameters.containsKey('cursor')
            ? page(1, 2)
            : page(0, 1, more: true),
      );
    });
    scopes.complete(ok(['#remote']));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Filters'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>).at(2));
    await tester.pumpAndSettle();
    expect(find.text('remote-broker').last, findsOneWidget);
  });
  testWidgets('repeated server sort changes stop automatic restart loops', (
    tester,
  ) async {
    var starts = 0;
    await show(tester, (r) async {
      if (!r.url.path.endsWith('/directory')) return ok([]);
      if (r.url.queryParameters.containsKey('cursor')) {
        return ok({...page(1, 2), 'effectiveSort': 'name'});
      }
      starts++;
      return ok(page(0, 1, more: true));
    });
    expect(starts, 2);
    expect(
      find.textContaining('Traffic ordering changed again'),
      findsOneWidget,
    );
  });
  testWidgets('zero first-page maximum keeps bars empty after counts change', (
    tester,
  ) async {
    await show(tester, (r) async {
      if (!r.url.path.endsWith('/directory')) return ok([]);
      if (r.url.queryParameters.containsKey('cursor')) return ok(page(1, 2));
      return ok({
        ...page(0, 1, more: true),
        'maxObservationCount': 0,
        'items': [
          {'id': '0', 'displayName': 'Observer 0', 'observationCount': 0},
        ],
      });
    });
    expect(find.text('Observer 1'), findsOneWidget);
    expect(
      tester
          .widgetList<FractionallySizedBox>(find.byType(FractionallySizedBox))
          .every((w) => w.widthFactor == 0),
      isTrue,
    );
  });
}
