import 'package:beacon/core/instance.dart';
import 'package:beacon/core/preferences.dart';
import 'package:beacon/features/telemetry/background.dart';
import 'package:beacon/features/telemetry/background_choice.dart';
import 'package:beacon/features/telemetry/session.dart';
import 'package:beacon/features/telemetry/telemetry_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
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
