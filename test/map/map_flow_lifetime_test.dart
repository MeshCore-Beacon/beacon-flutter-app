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

class TestStopwatch extends Stopwatch {
  int milliseconds = 0;
  @override
  int get elapsedMilliseconds => milliseconds;
  @override
  void reset() {
    super.reset();
    milliseconds = 0;
  }
}

void main() {
  setUp(BeaconTheme.load);

  testWidgets('flow lifetime follows elapsed timer time, not wall time', (
    tester,
  ) async {
    final timers = <Timer>[];
    final clock = TestStopwatch();
    Future<void> advance(Duration elapsed) async {
      if (clock.isRunning) clock.milliseconds += elapsed.inMilliseconds;
      await tester.pump(elapsed);
    }

    var delayTicks = false;
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
                flowClock: clock,
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
        // Elapsed time advances while DateTime.now remains unrelated.
        await advance(const Duration(milliseconds: 1450));
        expect(timers.single.isActive, isTrue);
        await advance(const Duration(milliseconds: 100));
        expect(timers.single.isActive, isFalse);
        expect(clock.isRunning, isFalse);

        // A fresh timer has its own origin; an overlapping arrival must not
        // restart that timer or expire at the earlier flow's deadline.
        events.add(observation);
        await tester.pump();
        expect(timers, hasLength(2));
        expect(timers.last.tick, 0);
        await advance(const Duration(seconds: 1));
        events.add(observation);
        await tester.pump();
        expect(timers, hasLength(2));
        await advance(const Duration(milliseconds: 550));
        expect(timers.last.isActive, isTrue);
        await advance(const Duration(seconds: 1));
        expect(timers.last.isActive, isFalse);

        // A packet can arrive before an overdue timer callback. Its timestamp
        // must use current elapsed time, not the timer's previous tick.
        events.add(observation);
        await tester.pump();
        clock.milliseconds = 3000;
        events.add(observation);
        await tester.pump();
        await tester.pump(const Duration(seconds: 3));
        expect(timers.last.isActive, isTrue);
        await advance(const Duration(milliseconds: 1450));
        expect(timers.last.isActive, isTrue);
        await advance(const Duration(milliseconds: 100));
        expect(timers.last.isActive, isFalse);

        // Delayed callbacks still count elapsed durations, not callback count.
        events.add(observation);
        await tester.pump();
        delayTicks = true;
        await advance(const Duration(seconds: 3));
        expect(timers.last.isActive, isTrue);
        delayTicks = false;
        await advance(const Duration(milliseconds: 50));
        expect(timers.last.isActive, isFalse);

        events.add(observation);
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await advance(const Duration(hours: 1));
        expect(timers.every((t) => !t.isActive), isTrue);
        expect(clock.isRunning, isFalse);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        events.add(observation);
        await tester.pump();
        expect(timers.last.tick, 0);
        expect(timers.last.isActive, isTrue);
        await tester.tap(find.byTooltip('Stop live map packet flow'));
        await tester.pump();
        expect(timers.every((t) => !t.isActive), isTrue);
        await tester.tap(find.byTooltip('Play live map packet flow'));
        await tester.pump();
        events.add(observation);
        await tester.pump();
        expect(timers.last.isActive, isTrue);
        await tester.pumpWidget(const SizedBox());
        expect(timers.every((t) => !t.isActive), isTrue);
        expect(clock.isRunning, isFalse);
        unawaited(events.close());
        await tester.pump();
        api.close();
      },
      zoneSpecification: ZoneSpecification(
        createPeriodicTimer: (self, parent, zone, duration, callback) {
          final timer = parent.createPeriodicTimer(zone, duration, (timer) {
            if (!delayTicks) callback(timer);
          });
          if (duration == const Duration(milliseconds: 50)) timers.add(timer);
          return timer;
        },
      ),
    );
  });
}
