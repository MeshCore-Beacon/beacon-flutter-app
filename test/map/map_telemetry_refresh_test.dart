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
  int get telemetryCalls =>
      requests.where((u) => u.path.endsWith('/nodes/telemetry/latest')).length;

  Future<http.Response> handle(http.Request r) async {
    requests.add(r.url);
    final path = r.url.path;
    if (path.endsWith('/info')) {
      if (gateInfo) await infoGate.future;
      return http.Response(jsonEncode(info), 200);
    }
    if (path.endsWith('/nodes/telemetry/latest') && failTelemetry) {
      return http.Response('boom', 500);
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
}
