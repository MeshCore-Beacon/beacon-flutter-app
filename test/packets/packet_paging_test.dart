import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/features/packets/packet_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const pc = 'v1:999123:00000001';

http.Response page(
  List<String> hashes, {
  bool more = false,
  bool exact = true,
}) => http.Response(
  jsonEncode({
    'items': [
      for (final (i, h) in hashes.indexed)
        {'packetHash': h, 'payloadType': 4, 'lastHeardAt': 1000 - i},
    ],
    'hasMore': more,
    if (more) 'nextCursor': 999,
    if (more && exact) 'nextPageCursor': pc,
  }),
  200,
);

Future<List<Map<String, String>>> pump(
  WidgetTester tester,
  Map<String, dynamic> region,
  http.Response Function(Map<String, String> q, int n) packets,
) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final queries = <Map<String, String>>[];
  final api = ApiClient(
    Uri.parse('https://example.test'),
    client: MockClient((r) async {
      if (r.url.path.endsWith('/scopes')) return http.Response('[]', 200);
      if (r.url.path.endsWith('/packets')) {
        queries.add(r.url.queryParameters);
        return packets(r.url.queryParameters, queries.length);
      }
      return http.Response('{}', 404);
    }),
  );
  addTearDown(api.close);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PacketScreen(
          api: api,
          region: region,
          events: null,
          onOpen: (_, _) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return queries;
}

Future<void> older(WidgetTester tester) async {
  await tester.tap(find.text('Load older packets'));
  await tester.pumpAndSettle();
}

void main() {
  for (final (label, region) in [
    ('global', <String, dynamic>{}),
    ('region', <String, dynamic>{'iatas': 'AAA,BBB'}),
  ]) {
    testWidgets(
      '$label: load older sends both cursors when the page has both',
      (tester) async {
        final q = await pump(
          tester,
          region,
          (q, n) =>
              n == 1 ? page(['00000001'], more: true) : page(['00000002']),
        );
        await older(tester);
        expect(q[1]['cursor'], '999');
        expect(q[1]['pageCursor'], pc);
        expect(q[1]['iatas'], region['iatas']);
      },
    );
    testWidgets('$label: a page without nextPageCursor pages by cursor only', (
      tester,
    ) async {
      final q = await pump(
        tester,
        region,
        (q, n) => n == 1
            ? page(['00000001'], more: true, exact: false)
            : page(['00000002']),
      );
      await older(tester);
      expect(q[1].containsKey('pageCursor'), false);
      expect(q[1]['cursor'], '999');
    });
    testWidgets(
      '$label: pages forward on a server that ignores pageCursor and shows a repeated packet once',
      (tester) async {
        await pump(
          tester,
          region,
          (q, n) => q['cursor'] == null
              ? page(['00000001', '00000002'], more: true)
              : page(['00000002', '00000003']),
        );
        await older(tester);
        for (final h in ['00000001', '00000002', '00000003']) {
          expect(find.text(h), findsOneWidget);
        }
        expect(find.text('Load older packets'), findsNothing);
      },
    );
  }

  testWidgets('retries a 503 after Retry-After with the same params', (
    tester,
  ) async {
    final q = await pump(
      tester,
      {},
      (q, n) => switch (n) {
        1 => page(['00000001'], more: true),
        2 => http.Response(
          '{"error":{"code":"deadline_exceeded","message":"busy"}}',
          503,
          headers: {'retry-after': '5'},
        ),
        _ => page(['00000002']),
      },
    );
    await tester.tap(find.text('Load older packets'));
    await tester.pump(const Duration(seconds: 4));
    expect(q.length, 2);
    expect(find.text('00000001'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(q.length, 3);
    expect(q[2], q[1]);
    expect(find.text('00000002'), findsOneWidget);
    expect(find.text('busy'), findsNothing);
  });

  testWidgets('a region with no IATAs sends no packets request', (
    tester,
  ) async {
    final q = await pump(tester, {
      'region': 'east',
    }, (q, n) => page(['00000001']));
    expect(q, isEmpty);
  });
}
