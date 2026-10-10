import 'dart:convert';
import 'dart:io';

import 'package:beacon/core/api.dart';
import 'package:beacon/core/json.dart';
import 'package:beacon/core/strings.dart';
import 'package:beacon/core/theme.dart';
import 'package:beacon/features/directory/directory.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'test_server.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('live node observer channel route and trace details', (
    tester,
  ) async {
    await Future.wait([BeaconTheme.load(), loadStrings()]);
    final api = ApiClient(Uri.parse(testServer));
    var converted = false;
    for (final kind in ['node', 'observer', 'channel', 'route', 'trace']) {
      final values = rows(
        await api.get('/${kind}s', {
          'limit': 10,
          if (kind == 'route') 'iata': 'YOW',
          if (kind == 'channel') 'keyKnown': 'true',
        }),
      );
      expect(values, isNotEmpty, reason: '$kind live fixture must exist');
      final value = values.first;
      final id = kind == 'route'
          ? jsonEncode(value)
          : textOf(value[kind == 'trace' ? 'traceTag' : 'id']);
      await tester.pumpWidget(
        MaterialApp(
          theme: BeaconTheme.resolve('neutral-blue'),
          home: EntityDetailScreen(
            key: ValueKey(kind),
            kind: kind,
            id: id,
            api: api,
            region: const {},
            onOpen: (_, _) {},
          ),
        ),
      );
      for (var i = 0; i < 16; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      if (Platform.isAndroid && !converted) {
        await binding.convertFlutterSurfaceToImage();
        await tester.pump();
        converted = true;
      }
      expect(
        tester.takeException(),
        isNull,
        reason: '$kind detail must render',
      );
      expect(
        find.text('Retry'),
        findsNothing,
        reason: '$kind detail must load',
      );
      await binding.takeScreenshot('${Platform.operatingSystem}-detail-$kind');
      final list = find.byType(ListView);
      if (list.evaluate().isNotEmpty) {
        for (var i = 0; i < 3; i++) {
          await tester.drag(list.first, const Offset(0, -600));
          await tester.pump(const Duration(milliseconds: 500));
          expect(
            tester.takeException(),
            isNull,
            reason: '$kind lower details must fit',
          );
        }
      }
    }
    await tester.pumpWidget(const SizedBox());
    api.close();
  });
}
