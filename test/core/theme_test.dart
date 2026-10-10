import 'dart:convert';

import 'package:beacon/core/theme.dart';
import 'package:beacon/features/packets/packet_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await BeaconTheme.load();
    final palettes =
        jsonDecode(await rootBundle.loadString('assets/themes.json')) as List;
    final light =
        palettes.firstWhere((t) => t['id'] == 'meshmapper_light') as Map;
    BeaconTheme.all.add(
      BeaconTheme(
        light['id'] as String,
        light['name'] as String,
        Map<String, dynamic>.from(light['vars'] as Map),
      ),
    );
  });
  test(
    'every web palette maps semantic colors without generated hue drift',
    () async {
      for (final theme in BeaconTheme.all) {
        final data = theme.data;
        final palette = data.extension<BeaconColors>()!;
        expect(
          palette.success,
          theme.color('green', '#22C55E'),
          reason: theme.id,
        );
        expect(
          palette.warning,
          theme.color('warn', '#EAB308'),
          reason: theme.id,
        );
        expect(
          data.colorScheme.onSurfaceVariant,
          theme.color('text-normal', '#A1A1AA'),
          reason: theme.id,
        );
        expect(
          data.colorScheme.outlineVariant,
          theme.color('border-subtle', '#1E1E22'),
          reason: theme.id,
        );
        expect(data.popupMenuTheme.color, palette.surface, reason: theme.id);
        expect(
          data.dialogTheme.backgroundColor,
          palette.surface,
          reason: theme.id,
        );
      }
    },
  );
  testWidgets('packet semantic badges follow selected theme', (tester) async {
    for (final id in ['neutral-blue', 'cyberpunk', 'meshmapper_light']) {
      final theme = BeaconTheme.resolve(id);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: const Scaffold(body: PacketBadge(label: 'ADVERT', type: 4)),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.text('ADVERT')).style!.color,
        theme.extension<BeaconColors>()!.success,
      );
      expect(tester.takeException(), isNull);
    }
  });
}
