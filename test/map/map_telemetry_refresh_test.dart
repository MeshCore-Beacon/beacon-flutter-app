import 'dart:async';
import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/core/theme.dart';
import 'package:beacon/features/map/map_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const info = {
  'features': {'polling': true, 'mapTelemetry': true},
};

class Harness {
  final requests = <Uri>[];
  final infoGate = Completer<void>();
  bool gateInfo = false, failTelemetry = false;
  int busyTelemetryReplies = 0;
  bool withReading = false;
  final sampledAt = DateTime.now().millisecondsSinceEpoch;
  int get telemetryCalls =>
      requests.where((u) => u.path.endsWith('/nodes/telemetry/latest')).length;

  Future<http.Response> handle(http.Request r) async {
    requests.add(r.url);
    final path = r.url.path;
    if (path.endsWith('/info')) {
      if (gateInfo) await infoGate.future;
      return http.Response(jsonEncode(info), 200);
    }
    if (path.endsWith('/nodes/telemetry/latest') && busyTelemetryReplies > 0) {
      busyTelemetryReplies--;
      return http.Response('busy', 503, headers: {'retry-after': '5'});
    }
    if (withReading && path.endsWith('/nodes')) {
      return http.Response(
        jsonEncode({
          'items': [
            {'id': 'sample', 'lat': 43, 'lng': -80, 'nodeTypeName': 'repeater'},
          ],
          'hasMore': false,
        }),
        200,
      );
    }
    if (path.endsWith('/nodes/telemetry/latest') && failTelemetry) {
      return http.Response('boom', 500);
    }
    if (withReading && path.endsWith('/nodes/telemetry/latest')) {
      return http.Response(
        jsonEncode({
          'items': [
            {'nodeId': 'sample', 'batteryMv': 4100, 'sampledAt': sampledAt},
          ],
        }),
        200,
      );
    }
    return http.Response(
      jsonEncode(
        path.endsWith('/iatas') ? [] : {'items': [], 'hasMore': false},
      ),
      200,
    );
  }
}

Future<ApiClient> pump(
  WidgetTester tester,
  Harness h, {
  Map<String, dynamic> region = const {},
}) async {
  SharedPreferences.setMockInitialValues({'beacon-map-telemetry': 'on'});
  final api = ApiClient(
    Uri.parse('https://beacon.example.com'),
    client: MockClient(h.handle),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: BeaconTheme.all.first.data,
      home: Scaffold(
        body: MapScreen(api: api, region: region, onOpen: (_, _) {}),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

Future<void> unmount(WidgetTester tester, ApiClient api) async {
  await tester.pumpWidget(const SizedBox());
  api.close();
}

void main() {
  setUp(BeaconTheme.load);

  testWidgets(
    'an /info that completes while paused starts no telemetry fetch',
    (tester) async {
      final h = Harness()..gateInfo = true;
      final api = await pump(tester, h);
      expect(h.telemetryCalls, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      h.infoGate.complete();
      await tester.pumpAndSettle();
      expect(h.telemetryCalls, 0);
      await tester.pump(const Duration(minutes: 11));
      expect(h.telemetryCalls, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(h.telemetryCalls, 1);
      await unmount(tester, api);
    },
  );

  testWidgets('an empty region selection makes no telemetry request', (
    tester,
  ) async {
    final h = Harness();
    final api = await pump(tester, h, region: const {'iatas': <String>[]});
    expect(h.telemetryCalls, 0);
    await tester.pump(const Duration(minutes: 6));
    expect(h.telemetryCalls, 0);
    await unmount(tester, api);
  });

  testWidgets('a failed background refetch shows no error', (tester) async {
    final h = Harness();
    final api = await pump(tester, h);
    expect(h.telemetryCalls, greaterThan(0));
    final before = h.telemetryCalls;
    h.failTelemetry = true;
    await tester.pump(const Duration(minutes: 5));
    await tester.pumpAndSettle();
    expect(h.telemetryCalls, greaterThan(before));
    expect(find.textContaining('Telemetry:'), findsNothing);
    await unmount(tester, api);
  });
  testWidgets('covered maps suspend telemetry refresh until visible again', (
    tester,
  ) async {
    final h = Harness()..withReading = true;
    final api = await pump(tester, h);
    String label() =>
        (tester
                        .widget<NativeMap>(
                          find.byType(NativeMap, skipOffstage: false),
                        )
                        .points['features']
                    as List)
                .single['properties']['telemetry']
            as String;
    final originalLabel = label();
    expect(originalLabel, contains('4.10V'));
    final navigator = Navigator.of(tester.element(find.byType(MapScreen)));
    final before = h.telemetryCalls;
    expect(before, greaterThan(0));
    unawaited(
      navigator.push<void>(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('Covered')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(minutes: 11));
    await tester.pumpAndSettle();
    expect(h.telemetryCalls, before);
    expect(label(), originalLabel);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(minutes: 6));
    expect(h.telemetryCalls, before);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(h.telemetryCalls, before + 1);
    await tester.pump(const Duration(minutes: 5));
    await tester.pumpAndSettle();
    expect(h.telemetryCalls, before + 2);
    await unmount(tester, api);
  });
  testWidgets(
    'returning to a map does not revive an obsolete telemetry retry',
    (tester) async {
      final h = Harness()
        ..gateInfo = true
        ..busyTelemetryReplies = 1;
      final api = await pump(tester, h);
      h.infoGate.complete();
      await tester.pump(const Duration(milliseconds: 1));
      expect(h.telemetryCalls, 1);
      final navigator = Navigator.of(tester.element(find.byType(MapScreen)));
      unawaited(
        navigator.push<void>(
          MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('Covered')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      navigator.pop();
      await tester.pumpAndSettle();
      expect(h.telemetryCalls, 2);
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(h.telemetryCalls, 2);
      expect(find.textContaining('Telemetry:'), findsNothing);
      await unmount(tester, api);
    },
  );
  testWidgets('features completing under a cover start no telemetry work', (
    tester,
  ) async {
    final h = Harness()..gateInfo = true;
    final api = await pump(tester, h);
    final navigator = Navigator.of(tester.element(find.byType(MapScreen)));
    unawaited(
      navigator.push<void>(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('Covered')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    h.infoGate.complete();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(minutes: 11));
    expect(h.telemetryCalls, 0);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(h.telemetryCalls, 1);
    await unmount(tester, api);
  });
  for (final initialState in [
    AppLifecycleState.paused,
    AppLifecycleState.inactive,
  ]) {
    testWidgets(
      'mounting while $initialState does not start telemetry polling',
      (tester) async {
        tester.binding.handleAppLifecycleStateChanged(initialState);
        final h = Harness();
        final api = await pump(tester, h);
        await tester.pump(const Duration(minutes: 11));
        expect(h.telemetryCalls, 0);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(h.telemetryCalls, 1);
        await unmount(tester, api);
      },
    );
  }
}
