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
    Json Function(Map<String, String> query) page, {
    Json region = const {},
  }) async {
    final requests = <Map<String, String>>[];
    final api = ApiClient(
      Uri.parse('https://test.invalid'),
      client: MockClient((r) async {
        if (!r.url.path.endsWith('/nodes')) return http.Response('[]', 200);
        requests.add(r.url.queryParameters);
        return http.Response(jsonEncode(page(r.url.queryParameters)), 200);
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DirectoryScreen(
            kind: 'nodes',
            api: api,
            region: region,
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
    await tester.tap(find.text('Load more'));
    await tester.pumpAndSettle();
    expect(requests.last['pageCursor'], 'v2:name:a');
    expect(requests.last.containsKey('cursor'), false);
    expect(requests.last['sort'], 'name');
    expect(top(tester, 'Alpha'), lessThan(top(tester, 'Bravo')));
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
    Future<void> choose(String label) async {
      await tester.tap(find.byIcon(Icons.sort));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    await choose('Neighbors');
    expect(requests.last['sort'], 'neighbors');
    expect(requests.last['order'], 'asc');
    await choose('Reverse order');
    expect(requests.last['sort'], 'neighbors');
    expect(requests.last['order'], 'desc');
    await choose('Newest first');
    expect(requests.last.containsKey('sort'), false);
    expect(requests.last.containsKey('order'), false);
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
