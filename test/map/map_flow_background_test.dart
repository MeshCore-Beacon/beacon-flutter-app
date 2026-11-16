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

  testWidgets('late packets cannot restart flow while the app is not resumed', (
    tester,
  ) async {
    final timers = <Timer>[];
    final events = StreamController<Json>();
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
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        expect(timers.single.isActive, isFalse);
        events.add(observation);
        await tester.pump();
        expect(
          timers,
          hasLength(1),
          reason: 'A late packet must not restart background work',
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        events.add(observation);
        await tester.pump();
        expect(timers, hasLength(2));
        expect(timers.last.isActive, isTrue);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump();
        events.add(observation);
        await tester.pump();
        expect(timers, hasLength(2));
        expect(timers.every((timer) => !timer.isActive), isTrue);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(const SizedBox());
        events.add(observation);
        await tester.pump();
        expect(timers, hasLength(2));
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
