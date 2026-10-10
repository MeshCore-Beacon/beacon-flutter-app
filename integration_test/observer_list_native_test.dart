import 'dart:convert';

import 'package:beacon/core/api.dart';
import 'package:beacon/core/theme.dart';
import 'package:beacon/features/directory/directory.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('observer traffic fills match mobile web', (tester) async {
    await BeaconTheme.load();
    final names = [
      'Hull_Hospital',
      'Sunridge_Observer',
      'Queenswood Heights 👀',
      'CBC-FORTUNE-R1',
      'YUL-VerdunBibliotheque',
    ];
    final counts = [42000, 31000, 18000, 5500, 0];
    final api = ApiClient(
      Uri.parse('https://example.test'),
      client: MockClient(
        (r) async => http.Response(
          jsonEncode(
            r.url.path.endsWith('/top-observers')
                ? [
                    for (var i = 0; i < names.length; i++)
                      {'observerId': '$i', 'observationCount': counts[i]},
                  ]
                : r.url.path.endsWith('/observers')
                ? {
                    'items': [
                      for (var i = names.length - 1; i >= 0; i--)
                        {
                          'id': '$i',
                          'name': names[i],
                          'status': i == 4 ? 'offline' : 'online',
                        },
                    ],
                    'hasMore': false,
                  }
                : [],
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: BeaconTheme.resolve('cyberpunk'),
        home: Scaffold(
          appBar: AppBar(title: const Text('Observers')),
          body: DirectoryScreen(
            kind: 'observers',
            api: api,
            region: const {},
            onOpen: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (
      var attempt = 0;
      attempt < 20 && find.text(names.first).evaluate().isEmpty;
      attempt++
    ) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      tester.getTopLeft(find.text(names.first)).dy,
      lessThan(tester.getTopLeft(find.text(names.last)).dy),
    );
    await binding.takeScreenshot('ios-observer-traffic-list');
  });
}
