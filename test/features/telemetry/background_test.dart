import 'dart:async';

import 'package:beacon/core/instance.dart';
import 'package:beacon/core/preferences.dart';
import 'package:beacon/features/telemetry/background.dart';
import 'package:beacon/features/telemetry/companion.dart';
import 'package:beacon/features/telemetry/session.dart';
import 'package:beacon/features/telemetry/sharing.dart';
import 'package:beacon/features/telemetry/telemetry_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeBackground extends TelemetryBackground {
  FakeBackground({super.supported = true});
  int starts = 0, stops = 0;
  bool available = true;
  String state = 'active';
  @override
  Future<void> start(Map<String, Object> notice) async {
    starts++;
    if (!available) throw StateError('Notifications unavailable');
  }

  @override
  Future<String> update(Map<String, Object> notice) async => state;
  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> resume() async {
    state = 'active';
  }
}

class FakeSharing extends TelemetrySharing {
  FakeSharing()
    : super(
        BeaconInstance.create('Test', 'https://example.test'),
        Companion.frames(
          StreamController<List<int>>().stream,
          (_) async {},
          () async {},
        ),
        [],
        6,
      );
  bool enabled = false, halted = false;
  int steps = 0, starts = 0;
  @override
  bool get running => enabled;
  @override
  bool get paused => halted;
  @override
  Future<void> start() async {
    starts++;
    enabled = true;
  }

  @override
  Future<void> step() async {
    if (enabled && !halted) steps++;
  }

  @override
  void pause() {
    halted = true;
  }

  @override
  void resume() {
    halted = false;
  }

  @override
  Future<void> stop() async {
    enabled = false;
    // This fake has no I/O to drain. Real socket shutdown is covered in sharing_test.
    unawaited(radio.close());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Preferences preferences;
  late FakeBackground background;
  late TelemetrySession session;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await Preferences.load();
    background = FakeBackground();
    session = TelemetrySession(preferences, background: background);
  });
  tearDown(() async {
    await session.disconnect();
    session.dispose();
    preferences.dispose();
  });

  test(
    'first enrollment choice is unset, then remembered including a refusal',
    () async {
      expect(preferences.telemetryBackground, isNull);
      await preferences.setTelemetryBackground(false);
      await preferences.setTelemetryNotificationStats(false);
      final loaded = await Preferences.load();
      expect(loaded.telemetryBackground, isFalse);
      expect(loaded.telemetryNotificationStats, isFalse);
      await preferences.setTelemetryBackground(true);
      expect((await Preferences.load()).telemetryBackground, isTrue);
    },
  );

  test('Android background opt-in preserves the same collector across app suspension', () async {
    await preferences.setTelemetryBackground(true);
    final sharing = FakeSharing();
    await session.start(sharing, transport: 'BLE');
    session.didChangeAppLifecycleState(AppLifecycleState.paused);
    await session.tick();
    expect(sharing.enabled, isTrue);
    expect(sharing.starts, 1);
    expect(background.starts, 1);
    expect(sharing.steps, greaterThan(0));
    expect(session.backgroundActive, isTrue);
  });

  test(
    'foreground choice closes on background without requesting notifications',
    () async {
      await preferences.setTelemetryBackground(false);
      final sharing = FakeSharing();
      await session.start(sharing, transport: 'Wi-Fi');
      session.didChangeAppLifecycleState(AppLifecycleState.paused);
      await session.disconnect();
      expect(sharing.running, isFalse);
      expect(background.starts, 0);
    },
  );

  test(
    'unsupported platforms cannot inherit Android background permission',
    () async {
      await preferences.setTelemetryBackground(true);
      session.dispose();
      background = FakeBackground(supported: false);
      session = TelemetrySession(preferences, background: background);
      final sharing = FakeSharing();
      await session.start(sharing, transport: 'BLE');
      expect(background.starts, 0);
      session.didChangeAppLifecycleState(AppLifecycleState.paused);
      await session.disconnect();
      expect(sharing.running, isFalse);
    },
  );

  test('notification denial prevents enrollment and polling', () async {
    await preferences.setTelemetryBackground(true);
    background.available = false;
    final sharing = FakeSharing();
    await expectLater(
      session.start(sharing, transport: 'BLE'),
      throwsStateError,
    );
    expect(sharing.starts, 0);
    expect(sharing.steps, 0);
    expect(session.backgroundActive, isFalse);
  });

  test(
    'notification stop pauses polling; disconnect ends collection and service',
    () async {
      await preferences.setTelemetryBackground(true);
      final sharing = FakeSharing();
      await session.start(sharing, transport: 'BLE');
      await background.onAction!('pause');
      final before = sharing.steps;
      await session.tick();
      expect(sharing.steps, before);
      expect(sharing.paused, isTrue);
      expect(sharing.running, isTrue);
      await background.onAction!('disconnect');
      expect(sharing.running, isFalse);
      expect(session.sharing, isNull);
      expect(session.backgroundActive, isFalse);
    },
  );

  test(
    'lost native service fails closed before another polling step',
    () async {
      await preferences.setTelemetryBackground(true);
      final sharing = FakeSharing();
      await session.start(sharing, transport: 'Wi-Fi');
      final before = sharing.steps;
      background.state = 'stopped';
      await session.tick();
      expect(sharing.steps, before);
      expect(sharing.running, isFalse);
    },
  );
  test('a second collector cannot replace the active companion', () async {
    await preferences.setTelemetryBackground(true);
    final first = FakeSharing(), second = FakeSharing();
    await session.start(first, transport: 'BLE');
    await expectLater(
      session.start(second, transport: 'Wi-Fi'),
      throwsStateError,
    );
    expect(second.starts, 0);
    expect(session.sharing, same(first));
    await second.stop();
  });

  testWidgets(
    'leaving and reopening setup retains one background session and its controls',
    (tester) async {
      final sharing = FakeSharing();
      await tester.runAsync(() async {
        await preferences.setTelemetryBackground(true);
        await session.start(sharing, transport: 'BLE');
      });
      await tester.pumpWidget(
        MaterialApp(
          home: TelemetryPage(instance: sharing.instance, session: session),
        ),
      );
      expect(find.text('Background telemetry'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(sharing.running, isTrue);
      expect(sharing.starts, 1);
      await tester.pumpWidget(
        MaterialApp(
          home: TelemetryPage(instance: sharing.instance, session: session),
        ),
      );
      await tester.tap(find.text('Stop polling'));
      await tester.pump();
      expect(sharing.paused, isTrue);
      expect(find.text('Resume polling'), findsOneWidget);
      await tester.tap(find.text('Stop and disconnect'));
      await tester.pumpAndSettle();
      expect(sharing.running, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'physical companion disconnect removes background collection immediately',
    () async {
      await preferences.setTelemetryBackground(true);
      final sharing = FakeSharing();
      await session.start(sharing, transport: 'BLE');
      await sharing.radio.close();
      await Future<void>.delayed(Duration.zero);
      expect(session.sharing, isNull);
      expect(sharing.running, isFalse);
      expect(background.stops, 1);
    },
  );
}
