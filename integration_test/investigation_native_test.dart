import 'dart:io';

import 'package:beacon/core/api.dart';
import 'package:beacon/core/json.dart';
import 'package:beacon/core/strings.dart';
import 'package:beacon/core/theme.dart';
import 'package:beacon/features/directory/directory.dart';
import 'package:beacon/features/map/map_data.dart';
import 'package:beacon/features/map/packet_path_screen.dart';
import 'package:beacon/features/packets/packet_detail.dart';
import 'package:beacon/features/packets/path_hop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'test_server.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'live analyzer candidate popup observer dashboard and report map',
    (tester) async {
      await Future.wait([BeaconTheme.load(), loadStrings()]);
      final api = ApiClient(Uri.parse(testServer));
      final summaries = rows(
        await api.get('/packets', {'payloadTypes': '4', 'limit': 40}),
      );
      Json? detail, selected;
      for (final packet in summaries) {
        final response = object(
          await api.get('/packets/${packet['packetHash']}'),
        );
        final mapped = packetPaths(response).map((p) => p['key']).toSet();
        final candidate = rows(response['observations'])
            .where(
              (o) =>
                  mapped.contains(o['observerId']) &&
                  rows(o['resolvedPath'])
                      .any((h) => rows(h['nodes']).isNotEmpty),
            )
            .firstOrNull;
        if (candidate != null) {
          detail = response;
          selected = candidate;
          break;
        }
      }
      expect(
        selected,
        isNotNull,
        reason: 'Live fixture must include a resolved path',
      );
      final navigator = GlobalKey<NavigatorState>();
      void open(String kind, String id) {
        navigator.currentState!.push(
          MaterialPageRoute(
            builder: (_) => EntityDetailScreen(
              kind: kind,
              id: id,
              api: api,
              region: const {},
              onOpen: open,
            ),
          ),
        );
      }

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          debugShowCheckedModeBanner: false,
          theme: BeaconTheme.resolve('neutral-blue'),
          home: PacketDetailScreen(
            api: api,
            hash: textOf(detail!['packetHash']),
            initialObservationId: textOf(selected!['id']),
            onOpen: open,
          ),
        ),
      );
      Future<void> wait(int seconds) async {
        for (var i = 0; i < seconds * 2; i++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
      }

      Future<void> reach(Finder finder) async {
        for (
          var i = 0;
          i < 12 && finder.hitTestable().evaluate().isEmpty;
          i++
        ) {
          await tester.ensureVisible(finder);
          await tester.pump(const Duration(milliseconds: 200));
        }
        expect(finder.hitTestable(), findsOneWidget);
      }

      await wait(5);
      if (Platform.isAndroid) {
        await binding.convertFlutterSurfaceToImage();
        await tester.pump();
      }
      await binding.takeScreenshot(
        '${Platform.operatingSystem}-polished-analyzer',
      );
      final hop = find
          .byWidgetPredicate(
            (w) => w is PathHopChip && rows(w.hop['nodes']).isNotEmpty,
          )
          .first;
      await reach(hop);
      await tester.tap(
        find.descendant(of: hop, matching: find.byType(ActionChip)),
      );
      await wait(1);
      expect(find.byType(BottomSheet), findsOneWidget);
      await binding.takeScreenshot(
        '${Platform.operatingSystem}-path-candidate-popup',
      );
      final candidate = find
          .descendant(
            of: find.byType(BottomSheet),
            matching: find.byType(ListTile),
          )
          .first;
      await tester.tap(
        find.descendant(
          of: candidate,
          matching: find.byIcon(Icons.chevron_right),
        ),
      );
      await wait(5);
      expect(find.byType(EntityDetailScreen), findsOneWidget);
      expect(find.byTooltip('Copy public key'), findsOneWidget);
      await tester.tap(find.byTooltip('Copy public key'));
      await tester.pump();
      expect(find.text('Copied'), findsOneWidget);
      await binding.takeScreenshot('${Platform.operatingSystem}-node-viewer');
      await tester.pageBack();
      await wait(1);
      final observer = find.widgetWithText(TextButton, 'Observer').first;
      await reach(observer);
      await tester.tap(observer);
      await wait(6);
      expect(find.byType(EntityDetailScreen), findsOneWidget);
      await binding.takeScreenshot(
        '${Platform.operatingSystem}-observer-dashboard',
      );
      await tester.pageBack();
      await wait(1);
      final paths = find.widgetWithText(TextButton, 'Map').first;
      await reach(paths);
      final button = tester.widget<TextButton>(paths);
      expect(
        button.onPressed,
        isNotNull,
        reason: 'Selected report must have a mapped path',
      );
      await tester.tap(paths);
      await wait(10);
      expect(find.byType(PacketPathScreen), findsOneWidget);
      expect(
        tester
            .widget<PacketPathScreen>(find.byType(PacketPathScreen))
            .initialPathKey,
        selected['observerId'],
      );
      expect(tester.takeException(), isNull);
      await binding.takeScreenshot(
        '${Platform.operatingSystem}-packet-path-popup',
      );
      await tester.pageBack();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      api.close();
    },
  );
}
