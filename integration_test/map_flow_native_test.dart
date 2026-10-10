import 'package:beacon/features/map/map_data.dart';
import 'package:beacon/features/map/map_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('live map dims markers and lights reached hops', (tester) async {
    final key = GlobalKey();
    final errors = <String>[];
    final nodes = [
      {
        'id': 'a',
        'name': 'Start',
        'nodeTypeName': 'repeater',
        'lat': 45.40,
        'lng': -75.70,
      },
      {
        'id': 'b',
        'name': 'Next',
        'nodeTypeName': 'repeater',
        'lat': 45.41,
        'lng': -75.68,
      },
      {
        'id': 'c',
        'name': 'Idle',
        'nodeTypeName': 'repeater',
        'lat': 45.40,
        'lng': -75.66,
      },
    ];
    Widget host(bool live) => MaterialApp(
      home: Scaffold(
        body: NativeMap(
          key: key,
          points: nodeFeatures(nodes),
          lines: collection([]),
          borders: collection([]),
          onNode: (_) {},
          liveFlow: live,
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

    await tester.pumpWidget(host(false));
    await wait(8);
    await binding.takeScreenshot('ios-flow-normal');
    await tester.pumpWidget(host(true));
    await wait(2);
    await binding.takeScreenshot('ios-flow-idle');
    await (key.currentState as dynamic).flow(
      flowFrame([
        {'nodes': nodes.take(2).toList(), 'start': 0},
      ], 480),
    );
    await wait(1);
    await binding.takeScreenshot('ios-flow-reached');
    await tester.pumpWidget(host(false));
    await (key.currentState as dynamic).flow(flowFrame([], 0));
    await wait(1);
    expect(errors, isEmpty);
    expect(tester.takeException(), isNull);
    await binding.takeScreenshot('ios-flow-stopped');
    await tester.pumpWidget(const SizedBox());
  });
}
