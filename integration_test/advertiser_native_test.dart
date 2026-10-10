import 'package:beacon/core/theme.dart';
import 'package:beacon/features/analytics/advertiser_list.dart';
import 'package:beacon/features/analytics/charts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('advertiser rows separate identity and metrics and open nodes', (
    tester,
  ) async {
    await BeaconTheme.load();
    String? opened;
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: BeaconTheme.resolve('cyberpunk'),
        home: Scaffold(
          appBar: AppBar(title: const Text('Talkers · 7d')),
          body: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              AnalyticsCard(
                title: 'Top advertisers · 7d',
                child: AdvertiserList(
                  days: 7,
                  nodes: [
                    {
                      'nodeId': 'a',
                      'nodeName': 'YOW Barrhaven South 2D',
                      'nodeTypeName': 'repeater',
                      'iata': 'YOW',
                      'floodAdvertCount': 4,
                      'directAdvertCount': 38,
                    },
                    {
                      'nodeId': 'b',
                      'nodeName': 'YOW Barrhaven Test Ra2',
                      'nodeTypeName': 'repeater',
                      'iata': 'YOW',
                      'floodAdvertCount': 1,
                      'directAdvertCount': 41,
                    },
                    {
                      'nodeId': 'c',
                      'nodeName': 'Shai-Hulud 🐍',
                      'nodeTypeName': 'repeater',
                      'iata': 'YOW',
                      'floodAdvertCount': 14,
                      'directAdvertCount': 27,
                    },
                    {
                      'nodeId': 'd',
                      'nodeName': 'YOW_Gatsby_Observer_Server_With_A_Long_Name',
                      'nodeTypeName': 'room_server',
                      'iata': 'YOW',
                      'floodAdvertCount': 1,
                      'directAdvertCount': 40,
                    },
                  ],
                  onOpen: (kind, id) => opened = '$kind/$id',
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('5.4 / day'), findsOneWidget);
    await binding.takeScreenshot('ios-advertisers-polished');
    await tester.tap(find.text('YOW Barrhaven South 2D'));
    expect(opened, 'node/a');
  });
}
