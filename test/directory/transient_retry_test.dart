import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/features/directory/directory.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response busy(int status, String seconds) => http.Response(
  '{"error":{"code":"service_unavailable","message":"busy"}}',
  status,
  headers: {'retry-after': seconds},
);

http.Response nodes() => http.Response(
  jsonEncode({
    'items': [
      {'id': 'a', 'name': 'Alpha', 'lastSeen': 1000},
    ],
    'hasMore': false,
  }),
  200,
);

Widget directory(ApiClient api) => MaterialApp(
  home: Scaffold(
    body: DirectoryScreen(
      kind: 'nodes',
      api: api,
      region: const {},
      onOpen: (_, _) {},
    ),
  ),
);

void main() {
  testWidgets('directory waits out a busy 503 and shows the page', (
    tester,
  ) async {
    var calls = 0;
    final api = ApiClient(
      Uri.parse('https://test.invalid'),
      client: MockClient((r) async {
        if (!r.url.path.endsWith('/nodes')) return http.Response('[]', 200);
        return ++calls == 1 ? busy(503, '2') : nodes();
      }),
    );
    await tester.pumpWidget(directory(api));
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 1);
    expect(find.text('busy'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('directory shows Retry after three busy retries', (tester) async {
    var calls = 0;
    var healthy = false;
    final api = ApiClient(
      Uri.parse('https://test.invalid'),
      client: MockClient((r) async {
        if (!r.url.path.endsWith('/nodes')) return http.Response('[]', 200);
        calls++;
        return healthy ? nodes() : busy(503, '1');
      }),
    );
    await tester.pumpWidget(directory(api));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.pumpAndSettle();
    expect(calls, 4);
    expect(find.text('busy'), findsOneWidget);
    healthy = true;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(calls, 5);
    expect(find.text('Alpha'), findsOneWidget);
  });

  testWidgets('entity screen waits out a 429 on detail and a 503 on history', (
    tester,
  ) async {
    var clock = DateTime(2026);
    final calls = <String, int>{};
    final api = ApiClient(
      Uri.parse('https://test.invalid'),
      now: () => clock,
      client: MockClient((r) async {
        final path = r.url.path;
        final n = calls[path] = (calls[path] ?? 0) + 1;
        if (path.endsWith('/observations')) {
          return n == 1
              ? busy(503, '1')
              : http.Response('{"items":[],"hasMore":false}', 200);
        }
        if (path.endsWith('/neighbors')) return http.Response('[]', 200);
        if (path.endsWith('/nodes/a')) {
          return n == 1
              ? busy(429, '1')
              : http.Response('{"id":"a","name":"Alpha"}', 200);
        }
        return http.Response('[]', 200);
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: EntityDetailScreen(
          kind: 'node',
          id: 'a',
          api: api,
          region: const {},
          onOpen: (_, _) {},
        ),
      ),
    );
    await tester.pump();
    // The 429 cooldown runs on the client clock.
    clock = clock.add(const Duration(seconds: 2));
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.pumpAndSettle();
    expect(calls['/api/v1/nodes/a'], 2);
    expect(calls['/api/v1/nodes/a/observations'], 2);
    expect(find.text('busy'), findsNothing);
    expect(find.text('Retry'), findsNothing);
  });
}
