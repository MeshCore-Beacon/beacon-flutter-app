import 'dart:async';
import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/features/directory/directory.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Widget directory(ApiClient api, {Stream<Map<String, dynamic>>? events}) =>
    MaterialApp(
      home: Scaffold(
        body: DirectoryScreen(
          kind: 'observers',
          api: api,
          region: const {},
          events: events,
          onOpen: (_, _) {},
        ),
      ),
    );

void main() {
  testWidgets(
    'revisiting requests a snapshot and pull to refresh fetches again',
    (tester) async {
      var listCalls = 0;
      final api = ApiClient(
        Uri.parse('https://test.invalid'),
        client: MockClient((request) async {
          if (request.url.path.endsWith('/directory')) {
            listCalls++;
            return http.Response(
              jsonEncode({
                'items': [
                  {'id': 'obs-1', 'displayName': 'Observer $listCalls'},
                ],
                'hasMore': false,
                'windowStart': 1767225600000,
                'windowEnd': 1767830400000,
                'effectiveSort': 'traffic',
                'coverage': {'status': 'complete'},
                'maxObservationCount': 0,
              }),
              200,
            );
          }
          return http.Response('[]', 200);
        }),
      );

      await tester.pumpWidget(directory(api));
      await tester.pumpAndSettle();
      expect(listCalls, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(directory(api));
      await tester.pumpAndSettle();
      expect(listCalls, 2);
      expect(find.text('Observer 2'), findsOneWidget);

      final refresh = tester.state<RefreshIndicatorState>(
        find.byType(RefreshIndicator),
      );
      unawaited(refresh.show());
      await tester.pumpAndSettle();
      expect(listCalls, 3);
      expect(find.text('Observer 3'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      api.close();
    },
  );

  testWidgets('known observer status patches the loaded row without refetch', (
    tester,
  ) async {
    final events = StreamController<Map<String, dynamic>>.broadcast();
    var listCalls = 0;
    final api = ApiClient(
      Uri.parse('https://test.invalid'),
      client: MockClient((request) async {
        if (request.url.path.endsWith('/directory')) {
          listCalls++;
          return http.Response(
            jsonEncode({
              'items': [
                {'id': 'obs-1', 'displayName': 'Original', 'status': 'online'},
              ],
              'hasMore': false,
              'windowStart': 1767225600000,
              'windowEnd': 1767830400000,
              'effectiveSort': 'traffic',
              'coverage': {'status': 'complete'},
              'maxObservationCount': 0,
            }),
            200,
          );
        }
        return http.Response('[]', 200);
      }),
    );

    await tester.pumpWidget(directory(api, events: events.stream));
    await tester.pumpAndSettle();
    events.add({
      'event': 'observerStatus',
      'data': {
        'observerId': 'obs-1',
        'displayName': 'Updated',
        'online': false,
        'lastStatusAt': 1000,
      },
    });
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('Original'), findsOneWidget);
    expect(find.byTooltip('Offline'), findsOneWidget);
    expect(listCalls, 1);

    await tester.pumpWidget(const SizedBox());
    await events.close();
    api.close();
  });
}
