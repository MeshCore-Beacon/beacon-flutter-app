import 'package:beacon/core/instance.dart';
import 'package:beacon/features/telemetry/telemetry_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'BLE and Wi-Fi require opt-in and leaving foreground stops the session',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: TelemetryPage(
            instance: BeaconInstance.create(
              'Preview',
              'https://example.test/beacon',
            ),
          ),
        ),
      );
      final scan = find.widgetWithText(FilledButton, 'Scan for BLE companions');
      expect(tester.widget<FilledButton>(scan).onPressed, isNull);
      await tester.tap(find.byType(Checkbox).first);
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
      await tester.drag(find.byType(ListView), const Offset(0, -600));
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
