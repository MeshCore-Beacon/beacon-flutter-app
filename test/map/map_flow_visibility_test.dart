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

const observation = {
  'event': 'packetObservation',
  'data': {
    'observation': {
      'resolvedPath': [
        {
          'confidence': 'high',
          'nodes': [
            {'id': 'a', 'latitude': 43, 'longitude': -79},
          ],
        },
        {
          'confidence': 'high',
          'nodes': [
            {'id': 'b', 'latitude': 44, 'longitude': -80},
          ],
        },
      ],
    },
  },
};

void main() {
  setUp(BeaconTheme.load);

  testWidgets('covered maps stop flow without losing the active preference', (
    tester,
  ) async {
    final timers = <Timer>[];
    final events = StreamController<Json>.broadcast();
    SharedPreferences.setMockInitialValues({});
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
    await runZoned(
      () async {
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
        await tester.pumpAndSettle();
        events.add(observation);
        await tester.pump();
        expect(timers.single.isActive, isTrue);
        final navigator = Navigator.of(tester.element(find.byType(MapScreen)));
        unawaited(
          navigator.push<void>(
            MaterialPageRoute(
              builder: (_) => const Scaffold(body: Text('Opaque details')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(timers.every((timer) => !timer.isActive), isTrue);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        events.add(observation);
        await tester.pump();
        expect(timers, hasLength(1));
        navigator.pop();
        await tester.pumpAndSettle();
        expect(find.byTooltip('Stop live map packet flow'), findsOneWidget);
        expect(timers.every((timer) => !timer.isActive), isTrue);
        events.add(observation);
        await tester.pump();
        expect(timers, hasLength(2));
        expect(timers.last.isActive, isTrue);

        unawaited(
          navigator.push<void>(
            MaterialPageRoute(
              builder: (_) => Scaffold(
                body: MapScreen(
                  api: api,
                  region: const {},
                  events: events.stream,
                  onOpen: (_, _) {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(timers.every((timer) => !timer.isActive), isTrue);
        await tester.tap(find.byTooltip('Play live map packet flow'));
        await tester.pump();
        events.add(observation);
        await tester.pump();
        expect(timers, hasLength(3));
        expect(timers.where((timer) => timer.isActive), hasLength(1));
        navigator.pop();
        await tester.pumpAndSettle();
        expect(timers.every((timer) => !timer.isActive), isTrue);
        expect(find.byTooltip('Stop live map packet flow'), findsOneWidget);
        events.add(observation);
        await tester.pump();
        expect(timers, hasLength(4));
        expect(timers.where((timer) => timer.isActive), hasLength(1));
        await tester.pumpWidget(const SizedBox());
        expect(timers.every((timer) => !timer.isActive), isTrue);
        unawaited(events.close());
        await tester.pump();
        api.close();
      },
      zoneSpecification: ZoneSpecification(
        createPeriodicTimer: (self, parent, zone, duration, callback) {
          final timer = parent.createPeriodicTimer(zone, duration, callback);
          if (duration == const Duration(milliseconds: 50)) timers.add(timer);
          return timer;
        },
      ),
    );
  });
}
