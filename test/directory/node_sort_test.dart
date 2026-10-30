import 'dart:async';
import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/core/json.dart';
import 'package:beacon/features/directory/directory.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  Json node(String id, String name, int lastSeen) => {
    'id': id,
    'name': name,
    'lastSeen': lastSeen,
  };

  Future<List<Map<String, String>>> pump(
    WidgetTester tester,
    // A Json body, or an http.Response to send as is.
    FutureOr<Object> Function(Map<String, String> query) page, {
    Json region = const {},
    Stream<Json>? events,
  }) async {
    final requests = <Map<String, String>>[];
    final api = ApiClient(
      Uri.parse('https://test.invalid'),
      client: MockClient((r) async {
        if (!r.url.path.endsWith('/nodes')) return http.Response('[]', 200);
        requests.add(r.url.queryParameters);
        final body = await page(r.url.queryParameters);
        return body is http.Response
            ? body
            : http.Response(jsonEncode(body), 200);
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DirectoryScreen(
            kind: 'nodes',
            api: api,
            region: region,
            events: events,
            onOpen: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return requests;
  }

  double top(WidgetTester tester, String text) =>
      tester.getTopLeft(find.text(text)).dy;

  Future<void> scrollToEnd(WidgetTester tester) async {
    final scroll = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );
    scroll.position.jumpTo(scroll.position.maxScrollExtent);
    await tester.pump();
  }

  // 50 rows from [start] in name order, as a server-sorted page.
  Json namePage(int start, {String? next}) => {
    'items': [
      for (var i = start; i < start + 50; i++)
        node('n$i', 'Node ${i.toString().padLeft(3, '0')}', i),
    ],
    'hasMore': next != null,
    'nextPageCursor': ?next,
    'sort': 'name',
    'order': 'asc',
  };

  Future<void> choose(WidgetTester tester, String label) async {
    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets('nodes ask the server for name order and keep its order', (
    tester,
  ) async {
    final requests = await pump(
      tester,
      (q) => {
        // Natural order from the server; a plain string sort would put 10 first.
        'items': [node('a', 'Node 9', 1), node('b', 'Node 10', 2)],
        'hasMore': false,
        'sort': q['sort'],
        'order': q['order'],
      },
      region: const {'iatas': 'YOW'},
    );
    expect(requests.single['sort'], 'name');
    expect(requests.single['order'], 'asc');
    expect(requests.single['iatas'], 'YOW');
    expect(top(tester, 'Node 9'), lessThan(top(tester, 'Node 10')));
  });

  testWidgets('a sorted list pages with pageCursor alone', (tester) async {
    final requests = await pump(
      tester,
      (q) => q['pageCursor'] == null
          ? {
              'items': [node('a', 'Alpha', 1)],
              'hasMore': true,
              'nextPageCursor': 'v2:name:a',
              'nextCursor': 1,
              'sort': 'name',
              'order': 'asc',
            }
          : {
              'items': [node('b', 'Bravo', 2)],
              'hasMore': false,
              'sort': 'name',
              'order': 'asc',
            },
    );
    // A short first page fills the screen without a scroll or a button.
    expect(requests.length, 2);
    expect(find.text('Load more'), findsNothing);
    expect(requests.last['pageCursor'], 'v2:name:a');
    expect(requests.last.containsKey('cursor'), false);
    expect(requests.last['sort'], 'name');
    expect(top(tester, 'Alpha'), lessThan(top(tester, 'Bravo')));
  });

  testWidgets('nodes load the next page as the list nears its end', (
    tester,
  ) async {
    final requests = await pump(
      tester,
      (q) => switch (q['pageCursor']) {
        null => namePage(0, next: 'p50'),
        'p50' => namePage(50, next: 'p100'),
        _ => namePage(100),
      },
    );
    expect(requests.length, 1);
    expect(find.text('Load more'), findsNothing);
    expect(find.text('Load older'), findsNothing);
    for (var i = 0; i < 3; i++) {
      await scrollToEnd(tester);
      await tester.pumpAndSettle();
    }
    expect(requests.map((q) => q['pageCursor']), [null, 'p50', 'p100']);
    expect(requests.every((q) => q['limit'] == '50'), true);
    expect(requests.every((q) => !q.containsKey('cursor')), true);
    expect(find.text('150 nodes'), findsOneWidget);

    // A new order starts again from the top.
    await choose(tester, 'Reverse order');
    final scroll = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );
    expect(scroll.position.pixels, 0);
  });

  testWidgets('a failed next page keeps the rows and retries that page', (
    tester,
  ) async {
    var failures = 0;
    final requests = await pump(
      tester,
      (q) => switch (q['pageCursor']) {
        null => namePage(0, next: 'p50'),
        _ when failures++ == 0 => http.Response(
          '{"error":{"message":"Try again"}}',
          500,
        ),
        _ => namePage(50),
      },
    );
    await scrollToEnd(tester);
    await tester.pumpAndSettle();
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Node 049'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(requests.map((q) => q['pageCursor']), [null, 'p50', 'p50']);
    await scrollToEnd(tester);
    expect(find.text('100 nodes'), findsOneWidget);
  });

  testWidgets('a repeated page cursor stops the scroll paging', (tester) async {
    final requests = await pump(
      tester,
      (_) => {
        'items': [node('a', 'Alpha', 1)],
        'hasMore': true,
        'nextPageCursor': 'same',
      },
    );
    expect(requests.length, 2);
    expect(find.text('1 node'), findsOneWidget);
  });

  testWidgets('scroll paging waits for a live refresh and keeps its pages', (
    tester,
  ) async {
    final events = StreamController<Json>.broadcast();
    final live = Completer<Json>();
    var firstPages = 0;
    final requests = await pump(tester, events: events.stream, (q) {
      return switch (q['pageCursor']) {
        null when ++firstPages == 2 => live.future,
        null => namePage(0, next: 'p50'),
        'p50' => namePage(50, next: 'p100'),
        'p100' => namePage(100, next: 'p150'),
        _ => {
          'items': [node('last', 'Node last', 0)],
          'hasMore': false,
          'sort': 'name',
          'order': 'asc',
        },
      };
    });
    await scrollToEnd(tester);
    await tester.pumpAndSettle();
    expect(requests.last['pageCursor'], 'p50');

    // A node outside the list asks for a live refresh of page one.
    void heard() => events.add({
      'type': 'event',
      'event': 'nodeUpdate',
      'data': {'nodeId': 'elsewhere'},
    });
    heard();
    await tester.pump(const Duration(seconds: 1));
    expect(firstPages, 2);
    await scrollToEnd(tester);
    expect(requests.last.containsKey('pageCursor'), false);
    live.complete(namePage(0, next: 'p50'));
    await tester.pumpAndSettle();
    expect(requests.last['pageCursor'], 'p100');

    // The next refresh waits out its 30 s throttle; scrolling does not.
    heard();
    await tester.pump();
    await scrollToEnd(tester);
    await tester.pumpAndSettle();
    expect(requests.last['pageCursor'], 'p150');
    expect(
      requests
          .where((q) => q['pageCursor'] != null)
          .map((q) => q['pageCursor']),
      ['p50', 'p100', 'p150'],
    );
    await scrollToEnd(tester);
    expect(find.text('151 nodes'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets('sort choices reload in the matching server order', (
    tester,
  ) async {
    final requests = await pump(
      tester,
      (q) => {
        'items': [node('a', 'Alpha', 1)],
        'hasMore': false,
        if (q['sort'] != null) 'sort': q['sort'],
        if (q['order'] != null) 'order': q['order'],
      },
    );
    await choose(tester, 'Neighbors');
    expect(requests.last['sort'], 'neighbors');
    expect(requests.last['order'], 'asc');
    await choose(tester, 'Reverse order');
    expect(requests.last['sort'], 'neighbors');
    expect(requests.last['order'], 'desc');
    await choose(tester, 'Newest first');
    expect(requests.last.containsKey('sort'), false);
    expect(requests.last.containsKey('order'), false);
  });

  testWidgets('type asks the server, and the device sorts if it is ignored', (
    tester,
  ) async {
    final requests = await pump(
      tester,
      (_) => {
        'items': [
          {...node('a', 'Alpha', 1), 'nodeTypeName': 'repeater'},
          {...node('b', 'Bravo', 2), 'nodeTypeName': 'companion'},
        ],
        'hasMore': false,
      },
    );
    expect(top(tester, 'Alpha'), lessThan(top(tester, 'Bravo')));
    await choose(tester, 'Type');
    expect(requests.last['sort'], 'type');
    expect(requests.last['order'], 'asc');
    expect(top(tester, 'Bravo'), lessThan(top(tester, 'Alpha')));
  });

  testWidgets('reversing newest first asks for oldest heard first', (
    tester,
  ) async {
    final requests = await pump(
      tester,
      (q) => {
        'items': q['order'] == 'asc' && q['sort'] == 'lastSeen'
            ? [node('o', 'Old', 1), node('n', 'New', 2)]
            : [node('n', 'New', 2), node('o', 'Old', 1)],
        'hasMore': false,
        'sort': q['sort'] ?? 'lastSeen',
        'order': q['order'] ?? 'desc',
      },
    );
    await choose(tester, 'Newest first');
    expect(requests.last.containsKey('sort'), false);
    expect(top(tester, 'New'), lessThan(top(tester, 'Old')));
    await choose(tester, 'Reverse order');
    expect(requests.last['sort'], 'lastSeen');
    expect(requests.last['order'], 'asc');
    expect(top(tester, 'Old'), lessThan(top(tester, 'New')));
    await choose(tester, 'Reverse order');
    expect(top(tester, 'New'), lessThan(top(tester, 'Old')));
  });

  testWidgets('a server without lastSeen gets no oldest-first request', (
    tester,
  ) async {
    final requests = await pump(
      tester,
      (_) => {
        'items': [
          {'id': 'a', 'name': 'Alpha'},
        ],
        'hasMore': false,
      },
    );
    await choose(tester, 'Newest first');
    final sent = requests.length;
    await choose(tester, 'Reverse order');
    expect(requests.length, sent);
  });

  testWidgets('the sort menu is labelled for nodes', (tester) async {
    await pump(tester, (_) => {'items': [], 'hasMore': false});
    expect(find.byTooltip('Sort nodes'), findsOneWidget);
  });

  testWidgets('node cards show when each node was last heard', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await pump(
      tester,
      (_) => {
        'items': [
          node('a', 'Alpha', now - 5 * 60 * 1000),
          {'id': 'b', 'name': 'Bravo'},
        ],
        'hasMore': false,
      },
    );
    expect(find.text('5m ago'), findsOneWidget);
    // Bravo has no lastSeen, so its card shows none.
    expect(find.textContaining('ago'), findsOneWidget);
  });

  testWidgets('a live node update marks the node heard just now', (
    tester,
  ) async {
    final events = StreamController<Json>.broadcast();
    final hourAgo = DateTime.now().millisecondsSinceEpoch - 3600 * 1000;
    await pump(
      tester,
      events: events.stream,
      (_) => {
        'items': [node('a', 'Alpha', hourAgo)],
        'hasMore': false,
      },
    );
    expect(find.text('1h ago'), findsOneWidget);
    events.add({
      'type': 'event',
      'event': 'nodeUpdate',
      'data': {'nodeId': 'a', 'name': 'Alpha'},
    });
    await tester.pump();
    await tester.pump();
    expect(find.text('1h ago'), findsNothing);
    expect(find.textContaining(RegExp(r'^[01]s ago$')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets('a live update leaves last heard off for an older server', (
    tester,
  ) async {
    final events = StreamController<Json>.broadcast();
    await pump(
      tester,
      events: events.stream,
      (_) => {
        'items': [
          {'id': 'a', 'name': 'Alpha'},
        ],
        'hasMore': false,
      },
    );
    events.add({
      'type': 'event',
      'event': 'nodeUpdate',
      'data': {'nodeId': 'a', 'name': 'Alpha'},
    });
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('ago'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets('a page without sort falls back to sorting on the device', (
    tester,
  ) async {
    await pump(
      tester,
      (_) => {
        'items': [node('z', 'Zulu', 9), node('a', 'alpha', 1)],
        'hasMore': false,
      },
    );
    expect(top(tester, 'alpha'), lessThan(top(tester, 'Zulu')));
  });
}
