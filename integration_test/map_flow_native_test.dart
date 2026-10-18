import 'package:beacon/features/map/map_data.dart';
import 'package:beacon/features/map/map_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('live map keeps idle dots and lights crossed nodes on top', (
    tester,
  ) async {
    final key = GlobalKey();
    final errors = <String>[];
    Map<String, dynamic> node(
      String id,
      String name,
      String type,
      double lat,
      double lng,
    ) => {'id': id, 'name': name, 'nodeTypeName': type, 'lat': lat, 'lng': lng};
    final nodes = [
      node('a', 'Phone 📱', 'companion', 45.400, -75.720),
      node('b', 'Barrhaven South', 'repeater', 45.405, -75.700),
      node('c', 'Rax_Repeat', 'repeater', 45.408, -75.694),
      node('d', 'Back_Talk 💬', 'repeater', 45.410, -75.688),
      node('e', 'Weather', 'sensor', 45.420, -75.660),
      node('f', 'Idle Rpt', 'repeater', 45.390, -75.680),
      node('g', 'Idle Room', 'room_server', 45.395, -75.665),
      node('h', 'Idle Phone', 'companion', 45.415, -75.715),
    ];
    final chain = [
      for (final id in 'abcde'.split(''))
        nodes.firstWhere((n) => n['id'] == id),
    ];
    Widget host(bool live, {String style = 'dark', String? selected}) =>
        MaterialApp(
          home: Scaffold(
            body: NativeMap(
              key: key,
              style: style,
              cluster: true,
              points: nodeFeatures(nodes),
              lines: collection([]),
              borders: collection([]),
              onNode: (_) {},
              liveFlow: live,
              selected: selected,
              fitPoints: true,
              onError: errors.add,
            ),
          ),
        );
    Future<void> wait(int n) async {
      for (var i = 0; i < n * 2; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
    }

    Future<void> frame(int now) async =>
        await (key.currentState as dynamic).flow(
          flowFrame([
            {'nodes': chain, 'start': 0},
          ], now),
        );

    await tester.pumpWidget(host(false));
    await wait(8);
    await binding.takeScreenshot('ios-live-clustered');
    await tester.pumpWidget(host(true));
    await wait(2);
    await binding.takeScreenshot('ios-live-idle');
    // At 1100 ms the dot is between c and d: c bright, b fading, a out.
    await frame(1100);
    await wait(1);
    await binding.takeScreenshot('ios-live-lit');
    await tester.pumpWidget(host(true, selected: 'h'));
    await wait(1);
    await binding.takeScreenshot('ios-live-selected');
    await tester.pumpWidget(host(true, style: 'positron'));
    await wait(8);
    await frame(1100);
    await wait(1);
    await binding.takeScreenshot('ios-live-lit-light');
    await tester.pumpWidget(host(false, style: 'positron'));
    await (key.currentState as dynamic).flow(flowFrame([], 0));
    await wait(1);
    expect(errors, isEmpty);
    expect(tester.takeException(), isNull);
    await binding.takeScreenshot('ios-live-stopped');
    await tester.pumpWidget(const SizedBox());
  });
}
