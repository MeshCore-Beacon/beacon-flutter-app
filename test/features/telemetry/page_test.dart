import 'package:beacon/core/instance.dart';
import 'package:beacon/core/preferences.dart';
import 'package:beacon/features/telemetry/background.dart';
import 'package:beacon/features/telemetry/background_choice.dart';
import 'package:beacon/features/telemetry/ble_companion.dart';
import 'package:beacon/features/telemetry/companion.dart';
import 'package:beacon/features/telemetry/session.dart';
import 'package:beacon/features/telemetry/telemetry_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PageRadio implements Companion {
  @override
  bool closed = false;
  @override
  String? radioKey = 'ab'.padRight(64, '0');
  @override
  Future<String> identify() async => radioKey!;
  @override
  Future<List<CompanionContact>> contacts() async => [];
  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class PageBle extends BleCompanion {
  PageBle(this.onConnect, {this.onPair});
  final void Function() onConnect;
  final void Function(bool)? onPair;
  bool closed = false;
  @override
  Future<List<BlePeer>> scan() async => [
    (id: 'test-id', name: 'Test companion', rssi: -60),
  ];
  @override
  Future<Companion> connect(String id, {bool pair = false}) async {
    if (closed) throw StateError('Closed transport');
    onConnect();
    onPair?.call(pair);
    return PageRadio();
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

void main() {
  testWidgets('disconnect can reconnect from the retained scan results', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final session = TelemetrySession(
      await Preferences.load(),
      background: TelemetryBackground(supported: false),
    );
    addTearDown(session.dispose);
    var connected = 0;
    final pairing = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: TelemetryPage(
          session: session,
          instance: BeaconInstance.create(
            'Preview',
            'https://example.test/beacon',
          ),
          bleFactory: () => PageBle(() => connected++, onPair: pairing.add),
        ),
      ),
    );
    await tester.tap(find.text('Allow telemetry sharing'));
    await tester.pump();
    await tester.tap(find.text('Scan for BLE companions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();
    expect(connected, 1);
    expect(pairing, [true]);
    await tester.tap(find.byTooltip('Stop and disconnect'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Test companion'));
    await tester.pumpAndSettle();
    expect(connected, 2);
    expect(pairing, [true, false]);
    expect(find.text('Bluetooth · Companion connected'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  testWidgets('bottom action clears Android system navigation', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final session = TelemetrySession(
      await Preferences.load(),
      background: TelemetryBackground(supported: false),
    );
    addTearDown(session.dispose);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 440);
    tester.view.padding = const FakeViewPadding(bottom: 48);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetPadding);
    await tester.pumpWidget(
      MaterialApp(
        home: TelemetryPage(
          session: session,
          instance: BeaconInstance.create(
            'Preview',
            'https://example.test/beacon',
          ),
        ),
      ),
    );
    await tester.drag(find.byType(ListView), const Offset(0, -1500));
    await tester.pumpAndSettle();
    final scan = find.ancestor(
      of: find.text('Scan for BLE companions'),
      matching: find.byType(FilledButton),
    );
    expect(tester.getBottomRight(scan).dy, lessThanOrEqualTo(440 - 48));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('first-node choice remembers refusal and can be changed later', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await Preferences.load();
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                if (await chooseTelemetryBackground(
                  context,
                  preferences,
                  supported: true,
                  edit: calls >= 2,
                )) {
                  calls++;
                }
              },
              child: const Text('Choose'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Choose'));
    await tester.pumpAndSettle();
    expect(
      find.text('Collect while Beacon is in the background?'),
      findsOneWidget,
    );
    await tester.tap(find.text('Only while using Beacon'));
    await tester.pumpAndSettle();
    expect(preferences.telemetryBackground, isFalse);
    await tester.tap(find.text('Choose'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(calls, 2);
    await tester.tap(find.text('Choose'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Allow background collection'));
    await tester.pumpAndSettle();
    expect((await Preferences.load()).telemetryBackground, isTrue);
  });

  testWidgets(
    'BLE and Wi-Fi require opt-in and leaving foreground stops the session',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final session = TelemetrySession(
        await Preferences.load(),
        background: TelemetryBackground(supported: false),
      );
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: TelemetryPage(
            session: session,
            instance: BeaconInstance.create(
              'Preview',
              'https://example.test/beacon',
            ),
          ),
        ),
      );
      final scan = find.ancestor(
        of: find.text('Scan for BLE companions'),
        matching: find.byWidgetPredicate((widget) => widget is FilledButton),
      );
      expect(tester.widget<FilledButton>(scan).onPressed, isNull);
      await tester.tap(find.text('Allow telemetry sharing'));
      await tester.pump();
      expect(tester.widget<FilledButton>(scan).onPressed, isNotNull);
      await tester.tap(find.text('Wi-Fi'));
      await tester.pump();
      expect(find.text('Companion LAN address'), findsOneWidget);
      expect(find.text('5000'), findsOneWidget);
      // An OS permission sheet before a radio is connected is local setup,
      // not a background collection session that should be cancelled.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Sharing stopped; cooldowns and pending reports are retained.',
        ),
        findsNothing,
      );
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, 1500));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Sharing stopped; cooldowns and pending reports are retained.',
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}
