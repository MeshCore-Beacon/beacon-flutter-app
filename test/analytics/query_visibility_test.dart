import 'dart:async';
import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/features/analytics/charts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('covered charts defer periodic and changed-parameter reads', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final requests = <Uri>[];
    final window = ValueNotifier<int>(0);
    final api = ApiClient(
      Uri.parse('https://example.test'),
      client: MockClient((r) async {
        requests.add(r.url);
        return http.Response(
          jsonEncode(
            r.url.queryParameters['window'] == '0'
                ? []
                : {'window': r.url.queryParameters['window']},
          ),
          200,
        );
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<int>(
            valueListenable: window,
            builder: (_, value, _) => StatsQuery(
              api: api,
              path: '/stats/example',
              params: {'window': value},
              pollInterval: const Duration(minutes: 1),
              builder: (data) => Text(
                value == 0
                    ? 'Count ${(data as List).length}'
                    : 'Window ${(data as Map)['window']}',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final navigator = Navigator.of(tester.element(find.byType(StatsQuery)));
    expect(requests, hasLength(1));
    unawaited(
      navigator.push<void>(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('Covered')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(minutes: 3));
    await tester.pumpAndSettle();
    expect(requests, hasLength(1));
    window.value = 1;
    await tester.pump();
    window.value = 2;
    await tester.pump();
    expect(requests, hasLength(1));
    navigator.pop();
    await tester.pumpAndSettle();
    expect(requests, hasLength(2));
    expect(requests.last.queryParameters['window'], '2');
    await tester.pump(const Duration(minutes: 1));
    await tester.pumpAndSettle();
    expect(requests, hasLength(3));
    await tester.pumpWidget(const SizedBox());
    window.dispose();
    api.close();
  });

  testWidgets(
    'cover cancels a queued retry and return performs one current read',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      var requests = 0;
      final api = ApiClient(
        Uri.parse('https://example.test'),
        client: MockClient((r) async {
          requests++;
          return requests == 1
              ? http.Response('busy', 503, headers: {'retry-after': '5'})
              : http.Response('{}', 200);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatsQuery(
              api: api,
              path: '/stats/example',
              pollInterval: const Duration(minutes: 1),
              builder: (data) => Text('Chart $data'),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1));
      expect(requests, 1);
      final navigator = Navigator.of(tester.element(find.byType(StatsQuery)));
      unawaited(
        navigator.push<void>(
          MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('Covered')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(requests, 1);
      navigator.pop();
      await tester.pumpAndSettle();
      expect(requests, 2);
      expect(find.textContaining('Data unavailable'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      api.close();
    },
  );

  testWidgets(
    'a missing chart endpoint stays stopped across cover and return',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      var requests = 0;
      final api = ApiClient(
        Uri.parse('https://example.test'),
        client: MockClient((r) async {
          requests++;
          return http.Response('missing', 404);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatsQuery(
              api: api,
              path: '/stats/missing',
              pollInterval: const Duration(minutes: 1),
              builder: (data) => Text('Chart $data'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(requests, 1);
      final navigator = Navigator.of(tester.element(find.byType(StatsQuery)));
      unawaited(
        navigator.push<void>(
          MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('Covered')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(minutes: 3));
      navigator.pop();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(minutes: 1));
      expect(requests, 1);
      await tester.pumpWidget(const SizedBox());
      api.close();
    },
  );
  for (final initialState in [
    AppLifecycleState.paused,
    AppLifecycleState.inactive,
  ]) {
    testWidgets('a chart mounted while $initialState defers its initial read', (
      tester,
    ) async {
      tester.binding.handleAppLifecycleStateChanged(initialState);
      var requests = 0;
      final api = ApiClient(
        Uri.parse('https://example.test'),
        client: MockClient((r) async {
          requests++;
          return http.Response('{"value":1}', 200);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatsQuery(
              api: api,
              path: '/stats/example',
              pollInterval: const Duration(minutes: 1),
              builder: (data) => Text('Value ${(data as Map)['value']}'),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(minutes: 3));
      expect(requests, 0);
      expect(tester.takeException(), isNull);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(requests, 1);
      expect(find.text('Value 1'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      api.close();
    });
  }
  testWidgets(
    'an initially hidden chart waits for visibility and reuses cached data',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      var requests = 0;
      final shown = ValueNotifier<bool>(false);
      final api = ApiClient(
        Uri.parse('https://example.test'),
        client: MockClient((r) async {
          requests++;
          return http.Response('{"value":1}', 200);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<bool>(
            valueListenable: shown,
            builder: (_, enabled, _) => TickerMode(
              enabled: enabled,
              child: StatsQuery(
                api: api,
                path: '/stats/example',
                builder: (data) => Text('Value ${(data as Map)['value']}'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(requests, 0);
      shown.value = true;
      await tester.pumpAndSettle();
      expect(requests, 1);
      expect(find.text('Value 1'), findsOneWidget);
      shown.value = false;
      await tester.pumpAndSettle();
      shown.value = true;
      await tester.pumpAndSettle();
      expect(requests, 1);
      await tester.pumpWidget(const SizedBox());
      shown.dispose();
      api.close();
    },
  );
  testWidgets(
    'hidden API replacement reads the new source once and rejects the old result',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final oldReply = Completer<http.Response>();
      var oldReads = 0, newReads = 0;
      final oldApi = ApiClient(
        Uri.parse('https://old.example.test'),
        client: MockClient((r) {
          oldReads++;
          return oldReply.future;
        }),
      );
      final newApi = ApiClient(
        Uri.parse('https://new.example.test'),
        client: MockClient((r) async {
          newReads++;
          return http.Response('{"source":"new"}', 200);
        }),
      );
      final selected = ValueNotifier<ApiClient>(oldApi);
      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<ApiClient>(
            valueListenable: selected,
            builder: (_, api, _) => Scaffold(
              body: StatsQuery(
                api: api,
                path: '/stats/example',
                builder: (data) => Text('Source ${(data as Map)['source']}'),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1));
      expect(oldReads, 1);
      final navigator = Navigator.of(tester.element(find.byType(StatsQuery)));
      unawaited(
        navigator.push<void>(
          MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('Covered')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      selected.value = newApi;
      await tester.pump();
      expect(newReads, 0);
      oldReply.complete(http.Response('old failure', 500));
      await tester.pumpAndSettle();
      navigator.pop();
      await tester.pumpAndSettle();
      expect(newReads, 1);
      expect(oldReads, 1);
      expect(find.text('Source new'), findsOneWidget);
      expect(find.textContaining('Data unavailable'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      selected.dispose();
      oldApi.close();
      newApi.close();
    },
  );
}
