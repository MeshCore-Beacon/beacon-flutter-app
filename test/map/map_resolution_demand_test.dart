import 'dart:async';
import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/core/json.dart';
import 'package:beacon/core/theme.dart';
import 'package:beacon/features/map/map_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(BeaconTheme.load);

  testWidgets('only resumed Live Map owns a resolved stream subscription', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final base = StreamController<Json>();
    final flow = StreamController<Json>.broadcast();
    final nextRegion = StreamController<Json>.broadcast();
    final api = ApiClient(
      Uri.parse('https://beacon.example.com'),
      client: MockClient(
        (r) async => http.Response(
          jsonEncode(
            r.url.path.endsWith('/iatas')
                ? []
                : {'items': [], 'hasMore': false},
          ),
          200,
        ),
      ),
    );
    Widget host(Stream<Json> resolved, String iata) => MaterialApp(
      theme: BeaconTheme.all.first.data,
      home: Scaffold(
        body: MapScreen(
          api: api,
          region: {'iatas': iata},
          events: base.stream,
          flowEvents: resolved,
          onOpen: (_, _) {},
        ),
      ),
    );
    await tester.pumpWidget(host(flow.stream, 'YKF'));
    await tester.pumpAndSettle();
    expect(base.hasListener, isTrue);
    expect(flow.hasListener, isFalse);

    Future<void> toggle(bool on) async {
      await tester.tap(
        find.byTooltip(
          on ? 'Play live map packet flow' : 'Stop live map packet flow',
        ),
      );
      await tester.pump();
      expect(flow.hasListener, on);
      expect(base.hasListener, isTrue);
    }

    await toggle(true);
    unawaited(
      Navigator.of(tester.element(find.byType(MapScreen))).push<void>(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('Opaque details')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(flow.hasListener, isFalse);
    expect(base.hasListener, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(flow.hasListener, isFalse);
    Navigator.of(tester.element(find.text('Opaque details'))).pop();
    await tester.pumpAndSettle();
    expect(flow.hasListener, isTrue);
    await toggle(false);
    await toggle(true);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(flow.hasListener, isFalse);
    expect(base.hasListener, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(flow.hasListener, isTrue);

    // Region replacement releases the previous live connection's demand.
    await tester.pumpWidget(host(nextRegion.stream, 'YOW'));
    await tester.pumpAndSettle();
    expect(flow.hasListener, isFalse);
    expect(nextRegion.hasListener, isTrue);
    expect(base.hasListener, isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(nextRegion.hasListener, isFalse);
    expect(base.hasListener, isFalse);
    unawaited(base.close());
    unawaited(flow.close());
    unawaited(nextRegion.close());
    await tester.pump();
    api.close();
  });
  testWidgets('standalone maps retain their single-subscription event stream', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final events = StreamController<Json>();
    final api = ApiClient(
      Uri.parse('https://beacon.example.com'),
      client: MockClient(
        (r) async => http.Response(
          jsonEncode(
            r.url.path.endsWith('/iatas')
                ? []
                : {'items': [], 'hasMore': false},
          ),
          200,
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: BeaconTheme.all.first.data,
        home: Scaffold(
          body: MapScreen(
            api: api,
            region: const {},
            events: events.stream,
            onOpen: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Play live map packet flow'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(events.hasListener, isTrue);
    await tester.tap(find.byTooltip('Stop live map packet flow'));
    await tester.pump();
    expect(events.hasListener, isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(events.hasListener, isFalse);
    unawaited(events.close());
    await tester.pump();
    api.close();
  });
}
