import 'package:flutter/material.dart';

import '../../core/preferences.dart';
import '../../core/strings.dart';

/// Ask once, at the first selected repeater. Dismissal is not a saved choice.
Future<bool> chooseTelemetryBackground(
  BuildContext context,
  Preferences preferences, {
  required bool supported,
  bool edit = false,
}) async {
  if (!edit && preferences.telemetryBackground != null) return true;
  final choice = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(tr('Collect while Beacon is in the background?')),
      content: Text(
        supported
            ? tr(
                'Beacon can keep polling your selected repeaters while this BLE or Wi-Fi companion stays connected, including with the screen off. This uses more battery and requires an ongoing Android notification. You can stop polling or disconnect from that notification. Your choice is remembered; collection never starts automatically after closing or restarting the app.',
              )
            : tr(
                'Background telemetry collection is currently available on Android only. On this device, keep Beacon in the foreground. Your choice is remembered.',
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(tr('Only while using Beacon')),
        ),
        if (supported)
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('Allow background collection')),
          ),
      ],
    ),
  );
  if (choice == null) return false;
  await preferences.setTelemetryBackground(choice);
  return true;
}
