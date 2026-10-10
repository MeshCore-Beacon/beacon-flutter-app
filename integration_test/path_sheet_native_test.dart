import 'package:beacon/core/theme.dart';
import 'package:beacon/features/packets/path_hop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('resolved node sheets use Beacon hierarchy', (tester) async {
    await BeaconTheme.load();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: BeaconTheme.resolve('cyberpunk'),
        home: Scaffold(
          appBar: AppBar(title: const Text('Packet analyzer')),
          body: Center(
            child: PathHopChip(
              hash: 'F0DF5D',
              hop: {
                'confidence': 'high',
                'nodes': [
                  {
                    'id': 'node',
                    'name': 'OARC_R1',
                    'publicKey': List.filled(8, 'f0df5d34').join(),
                  },
                ],
              },
              onOpen: (_, _) {},
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(ActionChip));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(BottomSheet)).height, lessThan(200));
    await binding.takeScreenshot('ios-node-sheet-compact');
  });
}
